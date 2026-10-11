# Cheats, and the package identity: notes for the PS5 port

Companion to `PS5_MEMORY_NOTES.md`. Where that one is about the memory model, this one is about
two smaller things that turned out to have more sharp edges than expected:

1. **Cheats** — there is no cheat UI on this target, so cheats are files plus one hand-written
   overlay page. Both halves have rules that fail *silently* if you get them wrong.
2. **The package identity** — which field names the tile on the home screen, and which fields must
   stay frozen once the console has an install.

Everything below was read out of this fork, not out of upstream docs. File and line references
are to `src/rpcs3/` at the time of writing (`Utilities/bin_patch.cpp`,
`Utilities/bin_patch.h`, `rpcs3/Emu/RSX/Overlays/HomeMenu/`).

---

## Part 1 — How cheats work, and the four ways they fail silently

RPCS3 calls them **patches**. "Cheat" is the UI word; everything on disk says patch.

### 1.1 Where the files live

`Utilities/bin_patch.cpp:128-148`:

```cpp
std::string patch_engine::get_patch_config_path()
{
    const std::string config_dir = fs::get_config_dir(true);   // :130 — note the `true`
    const std::string patch_path = config_dir + "patch_config.yml";
    ...
}

std::string patch_engine::get_patches_path()
{
    return fs::get_config_dir() + "patches/";                  // :143
}
```

`fs::get_config_dir()` is the emulator's config directory — on the console that is
**`/data/rpcs3/`**, so:

| Purpose | Path |
| --- | --- |
| Global patch file | `/data/rpcs3/patches/patch.yml` |
| Per-title patch file | `/data/rpcs3/patches/<TITLEID>_patch.yml` |
| Imported patches (Qt-side bookkeeping) | `/data/rpcs3/patches/imported_patch.yml` |
| **Which patches are switched on** | `/data/rpcs3/patch_config.yml` |

Both patch files are loaded unconditionally at startup (`bin_patch.cpp:894`,
`bin_patch.cpp:908` — the second is `fmt::format("%s%s_patch.yml", get_patches_path(), title_id)`).
There is no registration step, no index, no manifest. **Dropping the file in is the whole install
procedure.**

The `true` argument at `:130` matters: `get_patch_config_path()` uses the *config* variant of the
config dir, the patches dir does not. They resolve to the same place here, but the two are not
the same call.

### 1.2 Trap 1 — patches are inert by default

`bin_patch.h:119-123`:

```cpp
struct patch_config_values
{
    bool enabled{};                                   // :121 — value-initialised to false
    std::map<std::string, patch_config_value> config_values;
};
```

A patch that is merely *loaded* does nothing. It becomes live only when its enable flag is read
back as true, in `patch_engine::apply()`, `bin_patch.cpp:1524-1526`:

```cpp
// Check if this patch is enabled
if (config_values.enabled)
```

So installing a patch file and seeing it in the log proves nothing about whether a cheat is
active. This is the single most common way to be confused by this system.

### 1.3 Trap 2 — the top-level key of a patch file *is* the hash

`bin_patch.cpp:247-248`:

```cpp
patch_container& container = patches_map[main_key];
container.hash    = main_key;
```

The YAML key at the root of the file is not a label; it is the key the whole entry is filed under,
and it is the same key `patch_config.yml` must use. A per-title file for one game therefore repeats
the same ugly key on every patch:

```yaml
PPU-412a9bf323b4743de21658a286f71dbe82cad807:
  "Invincibility":
    Games:
      "inFamous (Artemis)":
        BCUS98119:
          "01.00":
            Patch:
              - [ be32, 0x00ABCDEF, 0x60000000 ]
```

The `Anchors:` block is skipped explicitly (`bin_patch.cpp:240-243`), which is why a file can
define reusable anchors at the root without them being mistaken for a patch.

The hash is the PPU executable hash RPCS3 prints on load:
`ppu_loader: PPU executable hash: PPU-412a9bf323b4743de21658a286f71dbe82cad807`. Take it from the
log for the game in front of you rather than trusting a filename.

### 1.4 Trap 3 — a root-level `Version:` is mandatory, and a comment does not count

`bin_patch.cpp:199-215`. The version node is looked up at the root of the document. If it is
missing:

```cpp
append_log_message(log_messages, fmt::format("Error: No '%s' entry found. Patch engine
    version = %s (file: %s)", patch_key::version, patch_engine_version, path), &patch_log.error);
```

…and then `load()` **returns false and the entire file is ignored**. Not one patch from it, not a
warning per patch — the whole file. If instead the value is present but wrong (`:204-206`), same
outcome.

It must equal `patch_engine_version`, `bin_patch.h:31`:

```cpp
inline static const std::string patch_engine_version = "1.2";
```

**This bites in practice.** Community collections (Artemis et al.) are written for other tools and
often carry the version only as a header *comment*:

```yaml
# Version: APP_VER=01.00 VERSION=02.00
```

That comment is invisible to the loader. A file downloaded in that state is silently discarded. The
fix is one line prepended to the file:

```yaml
Version: 1.2
```

(Note the `Version: APP_VER=…` line is a *different* thing — it is what the community collection
uses to record which game version the cheats were dumped from. It is not the patch engine version
and yaml-cpp will happily parse it as a string that then fails the `!= patch_engine_version` test.)

### 1.5 Trap 4 — the config file's nesting is deeper than the comment claims

`bin_patch.cpp:371` is the lookup, and it is the shape that `patch_config.yml` must match:

```cpp
const patch_config_values& config_values =
    patch_config[main_key].patch_info_map[description].titles[title][serial][app_version];
```

That is **five levels**: hash → description → **game title** → serial → app version → `Enabled`.

`bin_patch.h:127` labels this type wrongly:

```cpp
using patch_titles = std::unordered_map<std::string /*serial*/, patch_serials>;
```

The key is the *game title*, not the serial — usage at `:371`, `:383` and `:1684` all confirm it.
(Corrected in this fork; noted here because the upstream comment is misleading and will be met
again on any rebase.)

Note also `description` — the patch's name string, exactly as written in the patch file, quotes
included. `"Invincibility"` in the patch file must be `"Invincibility"` in the config.

### 1.6 What actually matches a running game

At apply time, `bin_patch.cpp:1465-1523`:

```cpp
const patch_container& container = ::at32(m_map, name);   // name = the PPU hash
const std::string& serial = Emu.GetTitleID();             // :1470
const std::string& app_version = Emu.GetAppVersion();
```

Then, per patch, serial is matched exactly or via the `"All"` wildcard (`:1488-1501`), and app
version likewise (`:1503-1517`).

**The game *title* is never matched.** It selects the container only indirectly (through the hash)
and otherwise is a grouping label for the config file and for UI. That is why the same title string
must be used consistently between the patch file and `patch_config.yml`: it is not checked against
anything at runtime, so a typo does not error — it just means the `Enabled: true` sits on a branch
nothing reads, and the patch stays off.

Serial must be exactly 9 alphanumeric characters; `"All"` as a serial is only legal when the title
is also `"All"` (`bin_patch.cpp:320-331`). App version must match `^([0-9]{2}\.[0-9]{2})$` or be
`"All"` (`:353-360`). Duplicates are rejected (`:362-366`).

### 1.7 The log tells you the truth about all of this

A patch that is loaded **and enabled** produces, at `bin_patch.cpp:1606`:

```
·S Applied patch (hash='PPU-412a9bf323b4743de21658a286f71dbe82cad807',
     description='Invincibility', author='…', patch_version='…', file_version='…') (<- 1)
```

`·S` is the notice/success marker (`!` is notice; see the severity-marker note in the memory
notes). Grep the console log for `Applied patch (` and you have your answer, per cheat.

The failure modes each have their own line, and they are worth memorising because all three look
like "nothing happened" from the couch:

| Line in `RPCS3.log` | Meaning |
| --- | --- |
| `No 'Version' entry found` | whole file ignored — Trap 3 |
| `File version … does not match patch engine target version` | whole file ignored — Trap 3 |
| `Skipping invalid app version` / `Skipping duplicate app version` | one entry dropped — §1.6 |
| `Loading patch config file /data/rpcs3/patch_config.yml` | config was found and read |
| `Applied patch (…` | it is live |

### 1.8 How the enable flags are written back

`save_config()` (`bin_patch.cpp:1644-1705`) writes an entry only when it is enabled *or* was
modified this session (`:1665`, `:1695`):

```cpp
if (config_values.enabled || config_values_dirty)
```

`load_config()` (`:1981-2060`) reads `Enabled:` under `pair.second[patch_key::enabled]` (`:2041`),
with a legacy bare-boolean form for old files (`:2056-2058`).

The practical consequence: **switching a cheat off does not leave `Enabled: false` in the file —
the entry disappears from `patch_config.yml` on the next write.** That is the intended default
(absent = off, §1.2), but it means a hand-edited file will get smaller over time, and a diff of it
is not a useful history.

---

## Part 2 — The Cheats page in the home menu

### 2.1 Why it had to be written by hand

RPCS3's cheat UI is `rpcs3qt/cheat_manager.cpp`, and it is not built for this target:

- `src/rpcs3/rpcs3/CMakeLists.txt:26` and `:37` fence the Qt stack behind `NOT ANDROID AND NOT PS5`;
  `:42` builds `add_subdirectory(ps5)` instead.
- `cheat_manager.cpp` appears only in `src/rpcs3/rpcs3/rpcs3qt/CMakeLists.txt:12`, alongside
  `patch_creator_dialog.cpp` (`:77`) and `patch_manager_dialog.cpp` (`:78`).

There is no keyboard on the console either — `ps5/main_ps5.cpp` installs a null keyboard handler —
so the Qt keycode table is irrelevant here too. What *does* run on this target is the non-Qt overlay
system, `rpcs3/Emu/RSX/Overlays/`, which is compiled unconditionally.

The home menu is opened with **Options + Touchpad** (the PS button belongs to the system;
`ps5/ps5_pad_handler.cpp` binds the pair, and `Input/pad_thread.cpp` watches for `CELL_PAD_CTRL_PS`
and calls `open_home_menu()`).

### 2.2 What was added

| File | Change |
| --- | --- |
| `rpcs3/Emu/RSX/Overlays/HomeMenu/overlay_home_menu_cheats.h` | new — `home_menu_cheat_row`, `home_menu_cheats` |
| `rpcs3/Emu/RSX/Overlays/HomeMenu/overlay_home_menu_cheats.cpp` | new — the page |
| `rpcs3/Emu/RSX/Overlays/HomeMenu/overlay_home_menu_main_menu.cpp` | `add_page(settings_sliders, …)` after Settings |
| `rpcs3/Emu/CMakeLists.txt` | one source line, in the explicit overlay list |
| `Utilities/bin_patch.h` | read-only accessor `get_loaded_patches()`; the `patch_titles` comment fix |

The page lists every patch the engine loaded for the running title, one row each: description on
the left, a switch on the right. Nothing is hard-coded per game — the rows *are*
`patch_engine::m_map` filtered by serial and app version, so a new `<TITLEID>_patch.yml` shows up
with no further wiring.

### 2.3 Controls

| Button | Action |
| --- | --- |
| Cross, d-pad left/right, left-stick left/right | toggle the highlighted cheat |
| Select | force it off (the default for every patch) |
| Circle | back |

### 2.4 The honest limitation, stated on-screen

A toggle is written to `patch_config.yml` **immediately**, but it cannot change the running session:
PPU patches are applied once, when the executable is loaded (`patch_engine::apply` is called from
the loader). So the page's first row reads *"Saved as you toggle. Takes effect after Restart."*, and
the Home Menu's own Restart entry is directly above it.

Persisting-then-restarting was chosen over trying to fake live toggling because live toggling is not
possible: the patch data has already been written into guest memory and, for `jump`/`branch`-style
patches, the original bytes are gone from the emulated image the patches were built against.

Each toggle logs `Cheats: '<description>' enabled|disabled`, so a session's cheat state is
recoverable from the log afterwards.

### 2.5 Why `persist()` merges instead of saving what it holds

`patch_engine::m_map` holds only the patches this title (and the global `patch.yml`) contributed.
Writing it straight out through `save_config()` would drop the enable flags of every other title.
So `home_menu_cheats::persist()` reads the file back with `load_config()`, overlays its own rows,
and saves that. The cost is a file read per toggle, which is nothing next to the risk of silently
switching off someone's other game.

The accessor added to `bin_patch.h` is deliberately const and returns a reference — the page never
mutates engine state, so there is no lifetime or ownership question between the overlay and the
emulator.

---

## Part 3 — Package identity: from RPCS3 to notRCPS3

### 3.1 The three fields that look similar and are not

`title/sce_sys/param.json` (copied to `sce_sys/param.json` inside the deployed app):

| Field | Value | What it actually does |
| --- | --- | --- |
| `localizedParameters.en-US.titleName` | `notRCPS3` | **The text on the home-screen tile.** Purely cosmetic. |
| `titleId` | `PPSA99300` | The console's identity for the app: install path, save data, `sce_sys` lookups. |
| `contentId` | `UP9000-PPSA99300_00-RPCS3PS5EMULATOR` | The package identity used by the installer/manifest. |

`titleName` is what a person reads on the tile. `titleId` and `contentId` are what the console uses
to find the app. They are independent, and only the first is safe to change on a console that
already has an install.

### 3.2 What was changed, and what was deliberately not

**Changed:** `titleName` `"RPCS3"` → `"notRCPS3"`.

**Left alone:** `titleId: PPSA99300` and `contentId: UP9000-PPSA99300_00-RPCS3PS5EMULATOR`.

The reasoning: the console holds `/data/homebrew/PPSA99300/`. Changing `titleId` would orphan that
directory — the new id would look like a never-installed app, and the existing install, its save
data and its `game_configs/` entry would all be pointing at the old one. Changing `contentId` is
worse, because it is the field an installer treats as "is this the same product". A display name
costs nothing to change; the other two cost a reinstall and a save-data migration.

`contentId` therefore still contains the string `RPCS3PS5EMULATOR` even though the tile no longer
says RPCS3. That is intentional and should not be "tidied up" later without doing the migration
properly.

### 3.3 How the file gets to the console

`tools/link-title.sh` reads `titleId` out of `title/sce_sys/param.json`, names the output
`dist/<TITLE_ID>/`, and copies `param.json` (plus `icon0.png`, and `pic0.dds` / `pic1.dds` /
`snd0.at9` when present) into `$app/sce_sys/`.

On this console the live copy is:

```
/data/homebrew/PPSA99300/sce_sys/param.json      # 844 bytes after the rename
/data/homebrew/PPSA99300/sce_sys/icon0.png       # 55492 bytes
```

The rename was pushed by FTP with a timestamped backup of the previous file
(`param.json.bak-<epoch>`) and verified by re-downloading and comparing hashes, because a param
file that arrives truncated is not obviously broken until the tile fails to launch.

**The shell may keep showing the old name** until its database is refreshed — the tile text is read
and cached by the system, not by the app. Relaunching from the tile or rebuilding the home-screen
database refreshes it. The file being correct is the thing under our control.

### 3.4 Release checklist

Before calling a build "notRCPS3" and shipping it:

1. `title/sce_sys/param.json` — `titleName` reads `notRCPS3`; `titleId` and `contentId` are
   unchanged from the working install. Verify both, every time; an accidental `titleId` edit is the
   expensive mistake.
2. The built ELF is deployed to `/data/homebrew/PPSA99300/eboot.bin`, and the **pre-sign** ELF hash
   is what you compare — the console loads the ELF the title was linked as, not the SELF wrapper
   `ps5-native-tool` writes around it.
3. The patch files and `patch_config.yml` are on the console at `/data/rpcs3/…` if the build is
   meant to carry cheats (§1.1). They are data, not part of the ELF; a rebuilt binary does not
   ship them.
4. Cheats verified from the log the honest way: `Applied patch (` lines present for the ones that
   should be on, absent for the ones that should be off.
5. Nothing copyrighted committed alongside: no BIOS, no game images, no disc keys. Patch files
   containing community cheat data stay out of the tree or are clearly attributed.

---

## Part 4 — Recipes

### Install a cheat set for a title

```bash
# 1. Find the hash and version from the log for the game in front of you:
#    ppu_loader: PPU executable hash: PPU-<hash>
#    Serial: <TITLEID>   /   Version: APP_VER=01.00 VERSION=02.00

# 2. Build the patch file. Root-level Version: 1.2 is MANDATORY (Trap 3).
printf 'Version: 1.2\n' > /tmp/<TITLEID>_patch.yml
cat downloaded_collection.yml >> /tmp/<TITLEID>_patch.yml

# 3. Enable the entries you want, mirroring bin_patch.cpp:371 exactly —
#    hash -> description -> game title -> serial -> app version -> Enabled: true

# 4. Upload:
#    /tmp/<TITLEID>_patch.yml  ->  /data/rpcs3/patches/<TITLEID>_patch.yml
#    config                    ->  /data/rpcs3/patch_config.yml

# 5. Verify by structure, not by eye: parse both files and replay the loader's own
#    checks (root Version == 1.2, 9-char serials, ^[0-9]{2}\.[0-9]{2}$ versions,
#    every config entry resolving to a real patch). Then relaunch and grep the log
#    for `Applied patch (`.
```

Step 5 is not ceremony. Every failure in §1.4–§1.6 is silent, and the only two things that are not
silent are the loader's own error lines and a real `Applied patch` line.

### Toggle cheats from the couch

Options + Touchpad → **Cheats** → highlight a row → Cross to toggle → Circle → **Restart**.

### Check what the console actually thinks is installed

```bash
# FTP: port 1337, anonymous/root; the server is latin-1 and dislikes NOOP.
# `nlst` 550s on directories — use raw `LIST <path>` instead.
LIST /data/homebrew/PPSA99300/sce_sys
RETR /data/homebrew/PPSA99300/sce_sys/param.json
```

---

## Part 5 — Status, and what is not done

**Verified:** the loader's rules are reproduced from this fork's own source (§1); the overlay page's
use of `patch_engine::m_map` matches the apply-time lookup; the two Artemis files were checked
structurally against those rules before being uploaded; the renamed `param.json` was pushed with a
backup and a readback hash check.

**Not verified:** the Cheats page rendering on the console — it needs a build, a deploy and a look
at the actual screen. The layout is assembled from the same primitives and the same constants the
settings pages use (`menu_entry_height`, `menu_checkbox_size`, `menu_entry_margin`), but a `switchbox`
inside a `horizontal_layout` with `auto_resize = false` is the one arrangement here that has no
direct precedent in the existing pages, so it is the first thing to look at if a row comes out
misaligned.

**Not started:** importing cheat collections automatically, and any per-game cheat browsing from the
host side. Both are Qt features upstream and stay Qt features.

*No copyrighted material belongs in this repository: no BIOS files, no game images, no disc keys.
Community cheat collections are third-party data with their own provenance and are not committed
here.*
