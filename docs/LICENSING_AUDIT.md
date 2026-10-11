# Licensing audit

What this project is licensed under, what the build actually links, and what that means for
handing anyone a built title. Written because the honest answer is "the source is fine to
share, the built binary is not", and that deserves evidence rather than a warning label.

**Every claim below was read out of this workspace.** The commands and their results are in
the text. Where something is *not* verified, it says so.

> This is a description of what the licenses say and what the build does with them. It is not
> legal advice, and nothing here should be read as one.

---

## 1. This repository

| | |
| --- | --- |
| `LICENSE` | GPL-3.0 (`GNU GENERAL PUBLIC LICENSE / Version 3, 29 June 2007`) |
| `README.md` → `## License` | "The scripts in this repository are GPL-3.0-or-later" |

Our own work — the scripts in `tools/`, the CMake toolchain, `title/sce_sys/` — is
GPL-3.0-or-later, and it is ours to license. Forking and redistributing GPL code is the
permission the GPL exists to grant; nothing in this section needs anyone's approval.

**One inconsistency, fixed alongside this document:** the scripts carried no `SPDX-License-
Identifier` headers at all, so the "or later" half of the claim rested on a README sentence
alone. Each script now carries `SPDX-License-Identifier: GPL-3.0-or-later` at the top.

---

## 2. What `eboot.bin` is actually made of

The link recipe is `tools/link-title.sh`, which sources `radv-link.sh` from PS5_Vulkan
(`tools/link-title.sh:61-62`) and links four kinds of thing. Verified with `grep`/`ls` over
`deps/`:

| Linked into the title | Size | License | Evidence |
| --- | --- | --- | --- |
| RPCS3's own objects | — | **GPL-2.0-only** | `src/rpcs3/README.md:48`: "Most files are licensed under the terms of GNU GPL-2.0-only License"; `src/rpcs3/LICENSE:2` = "Version 2, June 1991" |
| `libvulkan_radeon.ps5.a` — RADV + Mesa runtime | 273,413,058 B | **MIT** | 213 × `SPDX-License-Identifier: MIT` and 0 × GPL under `deps/PS5_Mesa/src/amd/vulkan` |
| `libps5platform.a` — the SDK's platform layer | 528,592 B | **GPL-3.0-or-later** | 16 × `SPDX-License-Identifier: GPL-3.0-or-later` under `deps/sdk-rpcs3/target/include/ps5platform/`; corroborated by `deps/PS5_Vulkan/NOTICE.md`: the fork's headers and platform layer are "both GPL-3.0-or-later like the SDK" |
| `libc++.a`, `libunwind.a`, `libclang_rt.builtins` | — | **Apache-2.0 WITH LLVM-exception** | `deps/PS5_LLVM/LICENSE.TXT`; SPDX headers in `deps/sdk-rpcs3/target/include` |

Two components ship in `dist/PPSA99300/` but are **not** linked into the ELF:

| Shipped alongside | License | Note |
| --- | --- | --- |
| `sce_module/libc.prx` | GPL-3.0-or-later | A separate module (PS5_Vulkan's `runtime/libc.prx`, hash-checked at `tools/link-title.sh:110`), not part of the ELF |
| `game_configs/`, `Icons/ui/` | GPL-2.0-only | RPCS3's own data and assets, copied by `tools/link-title.sh:115-116` |

---

## 3. The conflict, stated precisely

**GPL-2.0-only and GPL-3.0-or-later cannot be combined in one work.** GPLv2 says the combined
work may be distributed under version 2 only; GPLv3 requires the whole to be under version 3.
Neither permission can be satisfied, so a binary containing both is outside both licenses and
distributing it infringes both.

That is what `eboot.bin` is: RPCS3's GPL-2.0-only objects, statically linked with the SDK
platform layer's GPL-3.0-or-later `libps5platform.a`, in one ELF.

This is confirmed from both sides, not inferred from a file header:

- RPCS3 states it in its own words — `GPL-2.0-only`, not "or later". The 1599 files in the
  tree matching the classic "any later version" GPL boilerplate are vendored third-party code
  (curl, zlib); RPCS3's own sources carry no license headers at all, so the README statement
  is the operative one.
- PS5_Vulkan states it in `NOTICE.md`, and the platform layer's own headers agree.

**What the conflict is *not*.** It is not the graphics stack. RADV and Mesa — the 273 MB that
is most of the linked archive — are **MIT**, which is permissive and compatible with
everything here. The entire incompatible surface is a **528 KB platform shim**: the handful
of `ps5_*` functions (`ps5_malloc`, `ps5_open`, the heap and `open_memstream` replacements)
that stand in for libc on this console.

That asymmetry matters. It is the difference between "this can never be distributed" and
"one small component's license is the only obstacle", and it decides what section 5 can
realistically ask for.

---

## 4. Safe, and not

**Safe to publish, no exposure:**

- The source repository, its history, and the `src/rpcs3` submodule pointer. This is the
  ordinary exercise of a GPL.
- Our own scripts, `title/sce_sys/param.json`, and the README.
- `game_configs/` and `Icons/ui/` redistributed *on their own* — RPCS3's GPL-2.0-only covers
  them, and an unmodified copy carries RPCS3's own notices.
- `sce_module/libc.prx` redistributed on its own — GPL-3.0-or-later is a fine license to
  redistribute under; it is the *combination* that fails.
- A built title handed directly to another person. Personal use between two people is not
  distribution in any sense either license or a rights holder cares about.

**Not licensed, therefore not publishable:**

- **`eboot.bin`** — or the `PPSA99300` folder containing it, or a zip of that folder. There is
  no license this binary can be released under, because of section 3. This is the whole point.
- Putting it in a GitHub Release does not change this. A release asset is still a copy
  distributed to the public; it merely keeps it out of git history.

**Never, and this is where takedowns come from:**

- Sony material: `PS3UPDAT.PUP`, `dev_flash`, `.rap`, `.dkey`, game images. This is the one
  category that attracts DMCA notices, and none of it is in this repository.
- An exploit, HEN payload or bootstrapper. Distributing circumvention tooling is a separate
  and worse exposure than a license breach. This project ships none, and requires the user to
  already have their own setup.

`tools/make-release-zip.sh` enforces the last list mechanically: it refuses to produce an
archive containing any of it, and re-checks the archive rather than the directory it came from.

---

## 5. The three ways a distributable build becomes possible

Ranked by cost. None require this project to change anything it owns.

1. **Relicense the platform layer.** Ask the PS5_PayloadSDK fork's maintainer — and, if the
   file predates the fork, `ps5-payload-dev` upstream — whether `libps5platform.a`'s sources
   can be GPL-2.0-or-later. It is ~16 small files, it is the *only* incompatible component,
   and GPL-2.0-or-later is still a copyleft license, so the ask is small and the intent of
   the original is preserved. This is the one path that resolves the conflict outright.
2. **Relicense RPCS3.** Not realistic: RPCS3 is GPL-2.0-only by long-standing upstream
   statement and has hundreds of contributors. Listed for completeness and then dropped.
3. **Keep it source-only.** Publish the scripts, publish `make-release-zip.sh`, and let each
   user build their own copy for their own console. Their build is their own artifact; it is
   not distributed, so no license is engaged. This is what the repository does today, and it
   works — the zip is one command away for anyone who has the source.

Option 1 is worth an email. Option 3 is the safe default in the meantime.

---

## 6. What the blank-slate zip guarantees

`tools/make-release-zip.sh` produces `dist/notRCPS3-PPSA99300.zip`, containing the title
folder and nothing else. It refuses to build if the folder holds a PUP, a game image, a
`.rap`, a disc key, a log, a per-user `config.yml`, a `boot.txt`, a `.sfo`, or a leftover
runtime directory (`cache`, `dev_flash`, `savestates`, `screenshots`).

Those checks make the blank-slate property a behaviour of the script rather than a belief
about the tree. Note what they do **not** do: they cannot make the archive distributable.
Every check above can pass and the archive still contains `eboot.bin`, which section 3 rules
out. The script produces a correct archive; whether it may be published is a separate
question with a separate answer.

---

*Written with AI assistance, like the rest of this repository. No copyrighted material
belongs here: no BIOS files, no game images, no disc keys, no firmware.*
