#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Move PS3 save data between a real console and this port's RPCS3.
#
#   tools/save-transfer.sh list                list the PS3's saves, with game titles
#   tools/save-transfer.sh move <FOLDER>       PS3 -> PS5, then verify   (the usual one)
#   tools/save-transfer.sh get  <FOLDER>       PS3 -> local staging
#   tools/save-transfer.sh put  <FOLDER>       local staging -> PS5
#   tools/save-transfer.sh back <FOLDER>       PS5 -> PS3 (emulator progress onto the console)
#
# <FOLDER> is the save's directory name exactly as it appears on the PS3, e.g.
# BCUS98119_INFAMOUS_0 -- the game's own name for the save, not the title ID.
#
# Environment:
#   PS3_HOST       required for get/list/move/back
#   PS5_HOST       required for put/move/back
#   PS3_PORT=21  PS3_USER=anonymous  PS3_PASS=
#   PS5_PORT=1337
#   PS3_USER_ID=00000002   the console's home directory on the PS3
#   PS5_USER_ID=00000001   RPCS3's user (rpcs3/Emu/System.h:108)
#   STAGE=~/ps3-saves      where saves are kept between the two consoles
#
# Why this beats the XMB route: on a console with an FTP server, saves are read straight
# off the HDD, so copy-protected save data -- which the PS3 refuses to copy to USB, with no
# workaround -- transfers like anything else.
set -euo pipefail

[[ $# -ge 1 ]] || { sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 2; }
cmd=$1; shift
folder=${1:-}

exec python3 -I - "$cmd" "$folder" <<'PY'
import hashlib, io, os, pathlib, posixpath, struct, sys, time
from ftplib import FTP

cmd, folder = sys.argv[1], sys.argv[2]
stage = pathlib.Path(os.environ.get("STAGE") or pathlib.Path.home() / "ps3-saves")

def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit("save-transfer.sh: %s is not set" % name)
    return v

PS3_USER_ID = env("PS3_USER_ID", "00000002")
PS5_USER_ID = env("PS5_USER_ID", "00000001")
PS3_SAVES = "/dev_hdd0/home/%s/savedata/" % PS3_USER_ID
PS5_SAVES = "/data/rpcs3/dev_hdd0/home/%s/savedata/" % PS5_USER_ID

def connect(host, port, user, password):
    f = FTP()
    f.connect(host, int(port), timeout=30)
    f.login(user, password)
    f.voidcmd("TYPE I")
    return f

def ps3():
    return connect(env("PS3_HOST", required=True), env("PS3_PORT", "21"),
                   env("PS3_USER", "anonymous"), env("PS3_PASS", ""))

def ps5():
    return connect(env("PS5_HOST", required=True), env("PS5_PORT", "1337"), "anonymous", "")

def listing(f, path):
    """[(name, is_dir, size)]. Read as raw bytes: PS3 filenames are not always UTF-8 and
    ftplib's line decoder raises on them."""
    try:
        sock = f.transfercmd("LIST " + path)
        buf = bytearray()
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf.extend(chunk)
        sock.close()
        try:
            f.voidresp()
        except Exception:
            pass
    except Exception as e:
        sys.exit("save-transfer.sh: cannot list %s: %s" % (path, e))
    out = []
    for line in bytes(buf).decode("latin-1").splitlines():
        p = line.split(None, 8)
        if len(p) < 9 or p[8].strip() in (".", ".."):
            continue
        out.append((p[8].strip(), line.startswith("d"), int(p[4])))
    return out

def sfo_title(blob):
    if blob[:4] != b"\x00PSF":
        return {}
    key_table, data_table, count = struct.unpack_from("<III", blob, 8)
    found = {}
    for i in range(count):
        key_off, _, data_len, _, data_off = struct.unpack_from("<HHIII", blob, 20 + i * 16)
        end = blob.index(b"\x00", key_table + key_off)
        key = blob[key_table + key_off:end].decode("latin-1")
        if key in ("TITLE", "TITLE_ID", "DETAIL"):
            found[key] = blob[data_table + data_off:data_table + data_off + data_len] \
                .rstrip(b"\x00").decode("utf-8", "replace")
    return found

def tree(f, root):
    """Every file under root, as (path relative to root, size)."""
    files, stack = [], [""]
    while stack:
        rel = stack.pop()
        for name, is_dir, size in listing(f, root + rel):
            if is_dir:
                stack.append(rel + name + "/")
            else:
                files.append((rel + name, size))
    return sorted(files)

def fetch(f, remote, local):
    local.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    with open(local, "wb") as fh:
        def cb(chunk):
            fh.write(chunk)
            digest.update(chunk)
        f.retrbinary("RETR " + remote, cb)
    return digest.hexdigest()

def upload(f, local, remote):
    with open(local, "rb") as fh:
        f.storbinary("STOR " + remote, fh)
    return hashlib.sha256(local.read_bytes()).hexdigest()

def download(f, remote):
    buf = bytearray()
    f.retrbinary("RETR " + remote, lambda c: buf.extend(c))
    return bytes(buf)

def ensure(f, path):
    cur = ""
    for part in path.strip("/").split("/"):
        cur += "/" + part
        try:
            f.mkd(cur)
        except Exception:
            pass

def remote_hash(f, path):
    return hashlib.sha256(download(f, path)).hexdigest()

def do_list():
    f = ps3()
    rows = []
    for name, is_dir, _ in listing(f, PS3_SAVES):
        if not is_dir:
            continue
        try:
            meta = sfo_title(download(f, PS3_SAVES + name + "/PARAM.SFO"))
        except Exception:
            meta = {}
        rows.append((meta.get("TITLE", "?"), name))
    f.close()
    print("PS3 %s -- %d saves\n" % (env("PS3_HOST"), len(rows)))
    print("%-36s %s" % ("SAVE FOLDER", "GAME"))
    for title, name in sorted(rows, key=lambda r: r[1]):
        print("%-36s %s" % (name[:36], title[:44]))

def do_get():
    if not folder:
        sys.exit("save-transfer.sh: get needs a save folder name")
    f = ps3()
    files = tree(f, PS3_SAVES + folder + "/")
    total = 0
    for rel, size in files:
        digest = fetch(f, PS3_SAVES + folder + "/" + rel, stage / folder / rel)
        total += size
        print("  got %-40s %8d B  %s" % (rel, size, digest[:16]))
    f.close()
    print("==> %s: %d files, %d B -> %s" % (folder, len(files), total, stage / folder))

def do_put():
    if not folder:
        sys.exit("save-transfer.sh: put needs a save folder name")
    src = stage / folder
    if not src.is_dir():
        sys.exit("save-transfer.sh: nothing staged at %s (run 'get %s' first)" % (src, folder))
    f = ps5()
    ensure(f, PS5_SAVES + folder)

    # Never clobber save data the emulator already wrote: move it aside first.
    existing = [n for n, is_dir, _ in listing(f, PS5_SAVES + folder) if not is_dir]
    if existing:
        backup = "%s.bak-%d" % (folder, int(time.time()))
        ensure(f, PS5_SAVES + backup)
        for name in existing:
            f.rename(PS5_SAVES + folder + "/" + name, PS5_SAVES + backup + "/" + name)
        print("==> existing save set aside as %s" % backup)

    sent = 0
    for path in sorted(src.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(src))
        local = hashlib.sha256(path.read_bytes()).hexdigest()
        upload(f, path, PS5_SAVES + folder + "/" + rel)
        sent += 1
        remote = remote_hash(f, PS5_SAVES + folder + "/" + rel)
        print("  put %-40s %8d B  %s %s" % (rel, path.stat().st_size, local[:16],
                                           "ok" if remote == local else "MISMATCH"))
        if remote != local:
            f.close()
            sys.exit("save-transfer.sh: %s did not survive the round trip" % rel)
    f.close()
    print("==> %s: %d files -> %s%s" % (folder, sent, env("PS5_HOST"), PS5_SAVES + folder))

def do_back():
    if not folder:
        sys.exit("save-transfer.sh: back needs a save folder name")
    f, g = ps5(), ps3()
    files = tree(f, PS5_SAVES + folder + "/")
    ensure(g, PS3_SAVES + folder)
    for rel, size in files:
        blob = download(f, PS5_SAVES + folder + "/" + rel)
        parts = posixpath.dirname(rel)
        if parts:
            ensure(g, PS3_SAVES + folder + "/" + parts)
        g.storbinary("STOR " + PS3_SAVES + folder + "/" + rel, io.BytesIO(blob))
        print("  back %-40s %8d B" % (rel, len(blob)))
    f.close(); g.close()
    print("==> %s: %d files -> PS3 %s" % (folder, len(files), env("PS3_HOST")))

def do_move():
    do_get()
    do_put()

{"list": do_list, "get": do_get, "put": do_put, "move": do_move, "back": do_back}[cmd]()
PY
