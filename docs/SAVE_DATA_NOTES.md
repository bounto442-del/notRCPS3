# Save data: moving it between a PS3 and this port

Companion to `PS5_MEMORY_NOTES.md` and `CHEATS_AND_PACKAGE_NOTES.md`. This one is short,
because the mechanism is a folder copy — but there are three ways to get it wrong, and two of
them look like "the game ignores my save".

Everything below was read out of this fork or observed on hardware. Line references are to
`src/rpcs3/` at the time of writing.

---

## Part 1 — Where the saves live on each side

**PS3.** `/dev_hdd0/home/<user>/savedata/<dirname>/`, where `<user>` is the console's own
home directory (`00000001`, `00000002`, …). The user's PS3 has `00000002` and `00000003`.

**This port.** Three facts, all from the source:

```cpp
rpcs3/Emu/vfs_config.h:13    cfg::string dev_hdd0{ this, "/dev_hdd0/", "$(EmulatorDir)dev_hdd0/" };
rpcs3/Emu/System.cpp:634     const std::string save_path = dev_hdd0 + "home/" + m_usr + "/savedata/";
rpcs3/Emu/System.h:108       std::string m_usr{"00000001"};
```

`$(EmulatorDir)` is the emulator's config directory — `/data/rpcs3/` on the console. So the
destination is:

```
/data/rpcs3/dev_hdd0/home/00000001/savedata/<dirname>/
```

`m_usr` **defaults** to `00000001` and is only changed by `System.cpp:839` if something sets
it. RPCS3 creates the directory at boot (`System.cpp:660`), so on a console that has run a
game there is already a `home/00000001/` to drop saves into. Check rather than assume:

```bash
LIST /data/rpcs3/dev_hdd0/home/
```

---

## Part 2 — The part that decides whether it works

**RPCS3 keys save data by the game's own directory name, not by the title ID.**

That is why the folder is `BCUS98119_INFAMOUS_0` and not `BCUS98119` — inFAMOUS calls its
save slots `BCUS98119_INFAMOUS_0` and `_1`, and that name is what both the PS3 and RPCS3 file
it under. Copy it under a different name and the game will not see it: no error, no warning,
the load menu is simply empty.

So the rule for a transfer is: **same directory name, both sides, character for character.**
There is no lookup table and nothing to remap — the name is the key.

A save folder holds a small, fixed set of files:

| File | What |
| --- | --- |
| `PARAM.SFO` | The save's metadata — `TITLE`, `TITLE_ID`, `DETAIL`, timestamps. This is what `save-transfer.sh list` parses to name the game. |
| `PARAM.PFD` | A signature file. RPCS3 does not check it; copy it anyway rather than pruning. |
| `ICON0.PNG` | The thumbnail the PS3's XMB shows. |
| `STATE`, or game-specific names | The actual save. Some games add subdirectories. |

`PARAM.SFO` is a simple container: magic `\0PSF`, then offsets to a key table and a data
table, then 16-byte entries of `key_offset / format / length / max_length / data_offset`.
Roughly 30 lines of Python to read, which is what the tool does — there is no need to guess
at a title from a folder name.

---

## Part 3 — Getting saves off the PS3

**Route A — XMB, works on stock firmware.**

XMB → Game → Saved Data Utility (PS3) → highlight → Triangle → Copy → USB device. The stick
gets `PS3/SAVEDATA/<dirname>/`, unencrypted. Copy that to the console by FTP.

The catch: **copy-protected saves cannot be exported this way.** Many games — most
first-party ones — mark their save data copy-protected, and the PS3 refuses with no
workaround. There is nothing to configure; the option is simply not offered.

**Route B — FTP, needs a modded console, and is strictly better.**

With an FTP server running on the PS3 (webMAN/multiMAN/HEN), `/dev_hdd0` is reachable and the
saves are read straight off the HDD. **Copy protection is not consulted at all**, because
nothing is asking the PS3 to copy anything — it is being read as files. `PARAM.PFD` and the
rest come along unmodified.

This is the route `tools/save-transfer.sh` uses. The user's PS3 answers on port 21 as
`anonymous`, which is what made the inFAMOUS transfer possible.

---

## Part 4 — The three traps

1. **The directory name.** Covered in Part 2. This is the common one.
2. **The wrong user directory.** The saves are under `00000002` on the PS3 and must go under
   `00000001` on the emulator, because that is the emulator's user. The *name* of the save
   folder is what matters, not which user owned it on the PS3 — but the destination path is
   not the same as the source path, and copying `00000002` across wholesale does nothing.
3. **Region.** A `BLES` save will never be seen by a `BLUS` disc — different title, different
   save directory. Nothing can be done about this; it is not a bug.

One more, rarer: a handful of games bind saves to a PSN account ID. RPCS3 does not emulate
PSN, so those reject the save regardless of how it was copied.

---

## Part 5 — The tool

`tools/save-transfer.sh` does the whole round trip, with a backup and a hash check on every
file:

```bash
# What is on the console?
PS3_HOST=192.168.4.19 tools/save-transfer.sh list

# PS3 -> PS5, verified by readback
PS3_HOST=192.168.4.19 PS5_HOST=192.168.4.180 tools/save-transfer.sh move BCUS98119_INFAMOUS_0

# Emulator progress back onto the real console
PS3_HOST=192.168.4.19 PS5_HOST=192.168.4.180 tools/save-transfer.sh back BCUS98119_INFAMOUS_0
```

Defaults are the ones this project uses (`PS3_USER_ID=00000002`, `PS5_USER_ID=00000001`,
`PS5_PORT=1337`, staging in `~/ps3-saves`); override by environment variable.

Two behaviours worth knowing, because both are deliberate:

- **`put` never overwrites.** If the emulator already has a save under that name, it is moved
  aside to `/data/rpcs3/saves-backup/<dirname>.bak-<epoch>/` before anything is written. Losing
  emulator progress to a transfer that was supposed to *add* a save would be the worst possible
  failure here.
- **The backup goes outside `savedata/`, and that is not cosmetic.** The first version of this
  tool left it beside the save, as `<dirname>.bak-<epoch>`. That name still begins with the
  game's own directory-name prefix, so the game's save-list enumeration can pick it up as a
  second, unreadable entry in the load menu. It lives in `/data/rpcs3/saves-backup/` now, where
  nothing enumerates. (RPCS3's own overlay dialog does scan `.../savedata/` —
  `cellSaveData.cpp:312` — which is what makes this worth avoiding rather than tolerating.)
- **Every file is hashed twice** — once locally, once by reading it back off the console —
  and the run aborts on a mismatch. Save files are small enough that this costs nothing.

---

## Part 6 — Status, and what is not done

**Verified:** the destination path and user id are read from this fork's source (Part 1); the
name-keying behaviour is confirmed by the shape of the PS3's own save tree, where the game's
directory names are the keys (Part 2); `list` and `get` were run against the live PS3, and
the tool's `PARAM.SFO` parser correctly named all 51 saves; the inFAMOUS save pair was pulled
off the console over FTP — 8 files, 237,556 bytes — which is only possible because the
console's FTP server ignores copy protection.

**Also verified:** both inFAMOUS slots were pushed to the console — `BCUS98119_INFAMOUS_0` and
`_1`, 8 files, every one hash-checked by readback. The emulator already had a save in *each*
slot, so in both cases the tool moved the existing progress to `/data/rpcs3/saves-backup/`
rather than overwriting it; nothing was destroyed by the transfer.

**Not verified:** a save actually loading in a game on the console. The files are in place and
byte-identical, but the load menu has not been looked at. Until that happens, this document
describes a mechanism that is sound and a transfer path whose *destination* is confirmed and
whose *effect* is not.

**Not started:** bulk transfer of a whole save library, and any handling of the PS3's
encrypted save formats (`.PSV` exports from the XMB's "Copy" on the *PSP/PSV* side, or
save-resigning between console IDs). Neither is needed for the FTP route.

*No copyrighted material belongs in this repository: no BIOS files, no game images, no disc
keys. Save data belongs to whoever played the game — it is not committed here, and staging
lives outside the tree.*
