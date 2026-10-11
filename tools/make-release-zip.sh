#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Zip the built title folder (dist/<TITLE_ID>) into a blank-slate archive that a user can
# unzip and drag into /data/homebrew/ in one move.
#
#   dist/notRCPS3-<TITLE_ID>.zip
#     └── <TITLE_ID>/
#         ├── eboot.bin
#         ├── sce_module/libc.prx
#         ├── sce_sys/{param.json,icon0.png}
#         ├── game_configs/       (RPCS3's per-game settings database)
#         ├── Icons/ui/           (RPCS3's own overlay icons)
#         └── patches/            (empty)
#
# "Blank slate" is enforced, not assumed: the checks below fail the run if the archive would
# carry firmware, a game, a save, a log, a per-user config or a disc key. None of those live
# in the title folder -- they live in /data/rpcs3/ -- but this is the file that gets handed
# to other people, so the invariant is asserted here rather than trusted.
#
#   out=<path> to write somewhere other than dist/
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
title_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["titleId"])' "$root/title/sce_sys/param.json")
app="$root/dist/$title_id"
out=${out:-$root/dist/notRCPS3-$title_id.zip}

[[ -f $app/eboot.bin ]] || { echo "make-release-zip.sh: no $app/eboot.bin; build rpcs3_ps5 first" >&2; exit 2; }

for f in sce_sys/param.json sce_sys/icon0.png sce_module/libc.prx; do
    [[ -e $app/$f ]] || { echo "make-release-zip.sh: missing $title_id/$f" >&2; exit 2; }
done

# Anything a user is expected to bring themselves. A hit here means the archive would be
# redistributing someone's firmware, someone's game or someone's key.
leaks=$(find "$app" \
    \( -iname '*.pup' -o -iname '*.iso' -o -iname '*.rap' -o -iname '*.dkey' \
       -o -iname 'config.yml' -o -iname 'boot.txt' -o -iname '*.log' \
       -o -iname '*.sfo' -o -iname '*.self' -o -iname '*.bk' \) -print)
if [[ -n $leaks ]]; then
    echo "make-release-zip.sh: refusing to zip -- these do not belong in a release:" >&2
    sed 's/^/  /' <<<"$leaks" >&2
    exit 3
fi

# Caches and saves arrive in /data/rpcs3/, not here; if a run ever leaves them behind, catch it.
strays=$(find "$app" -type d \( -name cache -o -name dev_flash -o -name savestates -o -name screenshots \) -print)
if [[ -n $strays ]]; then
    echo "make-release-zip.sh: refusing to zip -- runtime state left in the title folder:" >&2
    sed 's/^/  /' <<<"$strays" >&2
    exit 3
fi

python3 - "$app/sce_sys/param.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
name = p.get("localizedParameters", {}).get("en-US", {}).get("titleName", "?")
print("==> titleName: %s  titleId: %s" % (name, p.get("titleId", "?")))
print("    (titleId and contentId must stay as built; only titleName is cosmetic)")
PY

rm -f "$out"
mkdir -p "$(dirname -- "$out")"
(cd "$root/dist" && zip -q -r -6 -X "$out" "$title_id")

# Verify the archive rather than the directory: this is what the user receives.
if unzip -Z1 "$out" | grep -Eiq '(\.pup|\.iso|\.rap|\.dkey|config\.yml|boot\.txt|\.log|\.self)$'; then
    echo "make-release-zip.sh: archive contains forbidden entries; not releasing it" >&2
    rm -f "$out"
    exit 3
fi

echo "==> $out"
du -h "$out" | cut -f1 | sed 's/^/    size: /'
echo "    files: $(unzip -Z1 "$out" | grep -vc '/$')"
echo "    sha256: $(sha256sum "$out" | cut -d' ' -f1)"
cat <<'TXT'

Give the user the archive and these three steps:

  1. Unzip it and drag the PPSA99300 folder into /data/homebrew/.
  2. Put their own PS3UPDAT.PUP and their game folders in /data/rpcs3/
     (games in /data/rpcs3/games/, each holding PS3_GAME/).
  3. Launch the tile. The first launch installs the firmware and compiles
     the game's PPU/SPU code and shaders -- that slow first run is the build.

Nothing else is needed: no .pkg, no PUP to prepare, nothing installs to system storage.
TXT
