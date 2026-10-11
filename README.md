# notRCPS3

[![Follow @_roberth_ on X](https://img.shields.io/badge/follow-%40__roberth__-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/_roberth_)

> [!CAUTION]
> **EXPERIMENTAL. EXPECT CRASHES, FREEZES AND BROKEN GAMES.**
>
> This is an early, unofficial port, tested on a single console with a handful of games.
> It is **not** supported by the RPCS3 team: do not report problems with it to them.
>
> - Most games are untested; many will crash back to the PS5 home screen or freeze.
> - It runs as an unsigned homebrew title, which is only possible on a console you own that
>   is already set up to run homebrew. That setup is not part of this project, and this
>   project provides no means of modifying a console — it is a build chain for an emulator
>   title, nothing more. Unsigned titles carry their own risks; you use all of this
>   **at your own risk**.
> - Back up anything on `/data/rpcs3/` (saves, settings) that you care about.

> [!WARNING]
> **Build scripts only, for your own console.** Nothing built from this may be
> redistributed: RPCS3 is GPL-2.0-only, and PS5_Vulkan and PS5_PayloadSDK are GPL-3.0, so
> the combined title cannot be shared under either license. No firmware, keys or games are
> included here, and none should ever be — each user supplies their own.

Build scripts for running [RPCS3](https://rpcs3.net) (the PlayStation 3 emulator) as a
native title on a PS5 that already runs homebrew. RPCS3 renders through Vulkan on
[PS5_Vulkan](https://github.com/mihawk-99/PS5_Vulkan)'s RADV port, plays audio through
SceAudioOut and reads DualSense controllers through ScePad. The frontend is RPCS3's own
Big Picture Mode.

**Source only.** This repository holds no binaries, firmware, keys or games, and builds
from it must not be redistributed. RPCS3 is GPL-2.0-only, and PS5_Vulkan and
PS5_PayloadSDK are GPL-3.0: the combined title cannot be shared under either license.
Build it yourself, for your own console.

Nothing from Sony is here and nothing from Sony is needed from anyone else: no Sony code, no
firmware, no disc keys, no game data. Each user brings their own console, their own firmware
and their own games, exactly as they do with RPCS3. This project is not affiliated with,
endorsed by or connected to Sony Interactive Entertainment; "PlayStation", "PS3" and "PS5"
are trademarks of Sony Interactive Entertainment, and RPCS3 belongs to the RPCS3 team.

Tested upstream on a PS5 Pro, firmware 13.60, with an existing homebrew setup (etaHEN, ftpsrv
and ShadowMount+). Need for Speed Carbon (BLUS30016) is fully playable there.

This fork is developed and tested on a standard PS5 on **firmware 7.00** — older than the
13.60 above — with ftpsrv and ShadowMount+. inFAMOUS (BCUS98119) and Jak and Daxter both play
there, with the caveats in **Known issues**. Nothing else has been tried on it.

## Screenshots

Captured over Remote Play on a PS5 Pro (Need for Speed Carbon, BLUS30016).

| | |
| --- | --- |
| ![The RPCS3 title on the PS5 home screen](media/ps5-home-screen.jpg) | ![RPCS3 compiling Carbon's PPU and SPU code on first launch](media/carbon-compiling.jpg) |
| ![Carbon's main menu](media/carbon-main-menu.jpg) | ![Carbon gameplay at 60 fps with the performance overlay](media/carbon-gameplay.jpg) |

## What you need

- An Arch/CachyOS host (others work if you install the equivalents):

  ```bash
  sudo pacman -S --needed base-devel clang llvm lld make python python-pip git curl \
    unzip tar pkgconf cmake ninja nasm glslang \
    spirv-llvm-translator libclc spirv-headers python-ply
  ```

- About 20 GB of disk space. A first build takes about 10 minutes on a 16-core
  desktop (LLVM and RADV are the slow parts); expect longer on smaller machines.
- On the console: an FTP server on port 2121 (ftpsrv) and ShadowMount+ to register the
  title.
- Your own PS3 firmware (`PS3UPDAT.PUP` from playstation.com) and your own game dumps.

## Building

```bash
git clone https://github.com/lavavex/rpcs3-PS5.git
cd rpcs3-PS5
tools/bootstrap.sh
```

`bootstrap.sh` runs these steps in order; each one skips work it has already done, so
re-run it after fixing a failure:

| Step | Script | Output |
| --- | --- | --- |
| Pinned sources | `tools/fetch-deps.sh` | `deps/PS5_*`, RPCS3's submodules |
| PS5 payload SDK fork | `tools/install-sdk.sh` | `deps/sdk-rpcs3` |
| RADV driver, ps5-native-tool, libc.prx | `tools/build-driver-chain.sh` | `deps/PS5_Vulkan/.deps/native/radv-release` |
| LLVM for the recompilers | `tools/build-llvm.sh` | `deps/llvm-ps5` |
| zlib, libiconv, FFmpeg | `tools/build-{zlib,libiconv,ffmpeg}.sh` | `deps/*-ps5` |
| Per-game settings database | `tools/update-config-database.sh` | `deps/config_database.json` |
| RPCS3 | `tools/build-rpcs3.sh` | `dist/PPSA99300` |

After changing RPCS3's code, rebuild with `ninja -C build/rpcs3-ps5 rpcs3_ps5`.

## Installing

Close RPCS3 on the console first (a running title's files cannot be replaced), then:

```bash
PS5_HOST=192.168.x.x tools/deploy.sh
```

That copies `dist/PPSA99300` into `/data/homebrew/`, and ShadowMount+ adds it to the home
screen within about 15 seconds.

**The folder is the whole install.** `deploy.sh` only does over FTP what you can do by hand:
drag the `dist/PPSA99300` folder you just built into `/data/homebrew/`. There is no `.pkg`
and no PUP to make — this is a homebrew folder, not a system package, and nothing in it
installs to system storage.

To hand that folder to someone as one file, `tools/make-release-zip.sh` packages it into
`dist/notRCPS3-PPSA99300.zip` — unzip it and the folder is ready to drag. The script refuses
to produce an archive that would carry firmware, a game, a save, a log or a key: the folder
is a blank slate by construction, and the script checks rather than assumes.

It is also a blank slate. The title ships with no firmware, no games and no per-user data,
so every user brings their own; see **First run** below.

## First run

Put these in `/data/rpcs3/` on the console over FTP:

- `PS3UPDAT.PUP`: installed on the next launch, then you can delete it.
- Games: copy disc game folders (each holding `PS3_GAME/`) to `/data/rpcs3/games/`, or to
  a `games/` folder on an exFAT USB drive.

RPCS3 opens in Big Picture Mode with your games listed. Players 1–4 are the DualSenses of
the signed-in users. Options + touchpad acts as the PS button.

For a custom home-screen background, convert a 16:9 image with
`deps/PS5_Vulkan/tools/prepare-assets.sh --background <image> --output-directory title/sce_sys`
and rebuild; `pic0.dds`/`pic1.dds` stay out of git.

Settings, logs and caches live in `/data/rpcs3/` (log: `/data/rpcs3/cache/RPCS3.log`).
To boot one game straight away, write its path (or a `.pkg` to install) into
`/data/rpcs3/boot.txt`.

## Known issues

- **Few games tested.** Need for Speed Carbon (BLUS30016) plays at 60 fps. inFAMOUS (BCUS98119)
  plays, but stutters and runs below full speed in places. Nothing else has been tried yet.
- **Audio output is s16 stereo, and the setting that says so is ignored.** The SceAudioOut port
  is always opened as s16 stereo, which is the format this console plays; `Audio: Convert to
  16 bit` makes no difference. A float stereo port opens with a valid handle and a clean log and
  then produces no sound, so the format is not something to experiment with.
- **The first launch of a game is slow.** RPCS3 compiles the game's PPU and SPU code and its
  shaders, and stutters while it does. The caches in `/data/rpcs3/cache` make later launches
  faster.
- **No video previews.** A game's details page in Big Picture Mode shows its icon, not its
  preview video.
- **The CPU usage in RPCS3's log is wrong** (a constant 6.3%): the PS5 does not report process
  CPU time. The performance overlay's PPU/SPU/RSX figures are correct.
- **A crash or freeze closes the title** without a message. The reason is in
  `/data/rpcs3/cache/RPCS3.log` (copy it off before relaunching: each launch replaces it).

## Layout

| Path | What |
| --- | --- |
| `src/rpcs3` | Submodule: [lavavex/rpcs3](https://github.com/lavavex/rpcs3), branch `ps5` (upstream RPCS3 plus the PS5 port; the frontend is `rpcs3/ps5/`) |
| `cmake/ps5-rpcs3.cmake` | CMake toolchain for the title |
| `tools/link-title.sh` | Links the title with RADV and signs `eboot.bin` |
| `tools/make-release-zip.sh` | Packages the built folder as a blank-slate zip, and checks it is one |
| `title/sce_sys` | Title metadata (`PPSA99300`) and icon |
| `docs/` | Notes on the PS5 memory model, and on cheats and the package identity |
| `PINS.md` | Pinned revisions of every dependency, and how to update them (`tools/sync-forks.sh`) |

## Provenance

This is a fork, and the history is kept rather than squashed, so the original work stays
attributable commit by commit.

It continues two repositories by [lavavex](https://github.com/lavavex):

- **[lavavex/rpcs3-PS5](https://github.com/lavavex/rpcs3-PS5)** — the port scaffolding, the
  build chain and the title metadata. This repository descends from it; the commits before
  the fork point are lavavex's.
- **[lavavex/rpcs3](https://github.com/lavavex/rpcs3)**, branch `ps5` — upstream RPCS3 plus
  the PS5 port in `rpcs3/ps5/`. The `src/rpcs3` submodule points at a fork of it, and the
  work done on top sits on the tip of lavavex's `ps5` branch (`5e0e0e613`) rather than
  rewriting it.

Both descend from GPL-licensed work, and the licenses are not the same one: this
repository's scripts and the `src/rpcs3` submodule keep their own terms, and RPCS3 is
GPL-2.0-only while PS5_Vulkan and PS5_PayloadSDK are GPL-3.0. That combination is why
nothing built from here is redistributed — see the warning at the top.

Upstream RPCS3's credits are in `src/rpcs3` and in **Credits** below.

Parts of this repository were written with AI assistance, and the commits say so.

## Credits

- [RPCS3](https://github.com/RPCS3/rpcs3) and its contributors.
- mihawk-99 for PS5_Vulkan, PS5_Mesa, PS5_PayloadSDK and PS5_LLVM, and the earlier RPCS3
  port notes this one follows.
- Swordpdf's [PS5SX2](https://github.com/Swordpdf/PS5SX2) for the memory model.
- [ps5-payload-dev](https://github.com/ps5-payload-dev) for the SDK.
- blackbearreloaded's [ps5-opengl](https://github.com/blackbearreloaded/ps5-opengl) for
  the shader compiler.

## License

The scripts in this repository are GPL-3.0-or-later (`LICENSE`). RPCS3 and the other
dependencies keep their own licenses.
