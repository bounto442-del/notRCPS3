#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Move a game image from a real console's ISO shelf onto this port, one file at a time.
#
#   tools/iso-transfer.sh list                 what is on the PS3's shelf, with sizes
#   tools/iso-transfer.sh get  <NAME>          PS3 -> local staging
#   tools/iso-transfer.sh put  <NAME>          local staging -> PS5
#   tools/iso-transfer.sh push <NAME>          get + put + verify   (the usual one)
#   tools/iso-transfer.sh verify <NAME> [--full]
#
# <NAME> is the file's name exactly as it appears on the PS3, spaces and all:
#   tools/iso-transfer.sh push "Turok (Europe) (En,Fr,De,Es,It).dec.iso"
#
# Environment:
#   PS3_HOST       required for list/get/push/verify
#   PS5_HOST       required for put/push/verify
#   PS3_PORT=21  PS5_PORT=1337  PS3_USER=anonymous  PS3_PASS=
#   PS3_ISO_DIR=/dev_hdd0/PS3ISO      source shelf on the console
#   PS5_ISO_DIR=/data/rpcs3/games     where the emulator looks for games (games.yml)
#   STAGE=<beside this repo>/ps3-iso-staging
#
# WHY THIS STAGES LOCALLY INSTEAD OF STREAMING PS3 -> PS5 IN ONE PASS
#
# Measured against the two consoles, not assumed. Both servers advertise "REST STREAM" in
# FEAT, and neither one honours it:
#
#   * PS3 webMANftpd: RETR after REST <n> returns the file from byte 0, so a download cannot
#     be continued.
#   * PS5 ftpsrv: the same, and worse for uploads -- STOR after REST <n> opens with O_TRUNC
#     and writes from byte 0. A "resume" there silently deletes everything already sent.
#   * Active mode (PORT) makes no difference; REST is ignored either way.
#   * The PS5's ftpsrv does accept APPE, which its FEAT does not list, and appends correctly:
#     it creates the file if absent, and appending the missing tail to a truncated file
#     reproduces the original byte for byte.
#
# So the download cannot be resumed at all, and the upload can only ever be resumed by
# appending. Staging locally means the PS3 is read exactly once, and the hop that gets
# retried and resumed is the one where resuming actually works.
#
# VERIFICATION. REST does not work for reads either, so no block can be sampled at an
# offset -- an earlier version of this tool "sampled" five positions and was quietly
# comparing byte 0 with byte 0 five times. What is possible is a sequential comparison: read
# the file back from the PS5 from the start and diff it against the staged copy. By default
# that is the first 32 MiB plus an exact size match; --full compares the entire file.
set -euo pipefail

[[ $# -ge 1 ]] || { sed -n '3,20p' "$0" | sed 's/^# \?//'; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cmd=$1; shift
name=${1:-}
mode=${2:-}

# Staging sits beside the repository rather than in $HOME: these files are gigabytes, and
# the checkout is the one place with room. Checked for space before anything is downloaded.
stage=${STAGE:-$(cd -- "$root/.." && pwd)/ps3-iso-staging}

# -u: a run lasts an hour and prints progress every 512 MiB, far less than Python's block
# buffer, so buffered stdout would show nothing at all until the very end.
exec python3 -u -I - "$cmd" "$name" "$mode" "$stage" <<'PY'
import io, os, shutil, sys, time
from ftplib import FTP

cmd, name, mode, STAGE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def env(k, d=None, required=False):
    v = os.environ.get(k, d)
    if required and not v:
        sys.exit("iso-transfer.sh: %s is not set" % k)
    return v

PS3_ISO_DIR = env("PS3_ISO_DIR", "/dev_hdd0/PS3ISO").rstrip("/") + "/"
PS5_ISO_DIR = env("PS5_ISO_DIR", "/data/rpcs3/games").rstrip("/") + "/"
CHUNK = 4 << 20          # transfer chunk
VERIFY_PREFIX = 32 << 20 # how much of the head to diff when not doing --full

def connect(host, port, user, password):
    f = FTP()
    f.connect(host, int(port), timeout=90)
    f.login(user, password)
    f.voidcmd("TYPE I")
    return f

def ps3():
    return connect(env("PS3_HOST", required=True), env("PS3_PORT", "21"),
                   env("PS3_USER", "anonymous"), env("PS3_PASS", ""))

def ps5():
    return connect(env("PS5_HOST", required=True), env("PS5_PORT", "1337"), "anonymous", "")

def human(n):
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return "%.2f %s" % (n, unit)
        n /= 1024.0

def listing(f, path):
    """[(name, size)] of the files directly in path. Raw bytes: PS3 listings are not UTF-8."""
    sock = f.transfercmd("LIST " + path)
    buf = bytearray()
    try:
        while True:
            c = sock.recv(65536)
            if not c:
                break
            buf.extend(c)
    finally:
        sock.close()
        try:
            f.voidresp()
        except Exception:
            pass
    out = []
    for line in bytes(buf).decode("latin-1", "replace").splitlines():
        p = line.split(None, 8)
        if len(p) < 9 or p[8].strip() in (".", "..") or line.startswith("d"):
            continue
        try:
            out.append((p[8].strip(), int(p[4])))
        except ValueError:
            pass
    return out

def size(f, path):
    try:
        return f.size(path)
    except Exception:
        return None

def duration(secs):
    """human() formats bytes; a time-to-finish needs its own reading."""
    secs = int(max(0, secs))
    if secs < 90:
        return "%ds" % secs
    if secs < 5400:
        return "%.0f min" % (secs / 60.0)
    return "%.1f h" % (secs / 3600.0)

def progress(done, total, started, base):
    rate = (done - base) / max(1e-6, time.time() - started)
    print("    %5.1f%%  %s / %s  %s/s  ~%s left"
          % (100.0 * done / total, human(done), human(total), human(rate),
             duration((total - done) / rate) if rate > 0 else "?"))

def do_list():
    f = ps3()
    rows = sorted(listing(f, PS3_ISO_DIR))
    f.close()
    print("PS3 %s%s -- %d images, %s total\n"
          % (env("PS3_HOST"), PS3_ISO_DIR, len(rows), human(sum(s for _, s in rows))))
    for n, s in rows:
        print("  %10s  %s" % (human(s), n))

def staged(nm):
    return os.path.join(STAGE, nm)

def check_space(need, path):
    """Refuse before downloading rather than filling the disk halfway through a 12 GiB file."""
    os.makedirs(path, exist_ok=True)
    free = shutil.disk_usage(path).free
    if free < need:
        sys.exit("iso-transfer.sh: %s has %s free, need %s for staging.\n"
                 "  set STAGE= to a filesystem with room." % (path, human(free), human(need)))

def do_get():
    if not name:
        sys.exit("iso-transfer.sh: get needs a file name")
    dest = staged(name)
    f = ps3()
    src = PS3_ISO_DIR + name
    total = size(f, src)
    if total is None:
        f.close()
        sys.exit("iso-transfer.sh: %s is not on the PS3" % src)
    check_space(total, STAGE)

    have = os.path.getsize(dest) if os.path.exists(dest) else 0
    if have == total:
        f.close()
        print("==> %s already staged (%s)" % (name, human(total)))
        return
    if have:
        # webMAN ignores REST, so a short local copy cannot be continued on the server side:
        # the read starts at byte 0 again. Say so rather than looking like a slow append.
        print("==> %s: local copy is short (%s of %s) and the PS3 cannot resume, "
              "reading it again from the start" % (name, human(have), human(total)))

    tmp = dest + ".part"
    attempts = 0
    while attempts < 4:
        attempts += 1
        try:
            if attempts > 1:
                f.close()
                f = ps3()
            got, started, last = 0, time.time(), 0
            with open(tmp, "wb") as out:
                def cb(chunk):
                    nonlocal got, last
                    out.write(chunk)
                    got += len(chunk)
                    if got - last >= (512 << 20):
                        last = got
                        progress(got, total, started, 0)
                f.retrbinary("RETR " + src, cb, blocksize=CHUNK)
            if got != total:
                raise IOError("read %s of %s" % (human(got), human(total)))
            os.replace(tmp, dest)
            break
        except Exception as e:
            if attempts >= 4:
                raise
            print("    ... %s (attempt %d) -- restarting the read" % (e, attempts))
    f.close()
    print("==> %s: %s staged at %s" % (name, human(os.path.getsize(dest)), dest))

def do_put():
    if not name:
        sys.exit("iso-transfer.sh: put needs a file name")
    local = staged(name)
    if not os.path.exists(local):
        sys.exit("iso-transfer.sh: nothing staged at %s (run 'get %s' first)" % (local, name))
    total = os.path.getsize(local)
    dst = PS5_ISO_DIR + name

    g = ps5()
    attempts, stall, last_size = 0, 0, -1
    while attempts < 8:
        attempts += 1
        have = size(g, dst)
        if have is None:
            have = 0
        if have > total:
            # Bigger than the source: cannot be resumed onto. Start it clean.
            print("==> %s on the PS5 is larger than the source (%s > %s); starting over"
                  % (name, human(have), human(total)))
            g.delete(dst)
            have = 0
        if have == total:
            break
        # Give a transient failure room to recover: only stop once retries stop advancing.
        if have == last_size:
            stall += 1
            if stall >= 3:
                g.close()
                sys.exit("iso-transfer.sh: no progress after %d attempts (%s of %s); stopping"
                         % (attempts, human(have), human(total)))
        else:
            stall = 0
        last_size = have

        if attempts == 1:
            print("==> %s  %s  -> PS5%s" % (name, human(total),
                  "  resuming at %s" % human(have) if have else ""))
        started, last = time.time(), have
        try:
            with open(local, "rb") as fh:
                fh.seek(have)
                while have < total:
                    chunk = fh.read(CHUNK)
                    if not chunk:
                        break
                    # APPE, not STOR: STOR would truncate, and it is what makes this
                    # resumable at all. It creates the file when it is absent.
                    g.storbinary(("APPE " if have else "STOR ") + dst, io.BytesIO(chunk))
                    have += len(chunk)
                    if have - last >= (512 << 20):
                        last = have
                        progress(have, total, started, 0)
        except Exception as e:
            print("    ... %s -- reconnecting and continuing from what landed" % e)
            try: g.close()
            except Exception: pass
            g = ps5()
            continue

    if size(g, dst) != total:
        g.close()
        sys.exit("iso-transfer.sh: %s landed at %s, expected %s"
                 % (dst, human(size(g, dst) or 0), human(total)))
    g.close()
    print("==> %s: %s on the PS5 at %s" % (name, human(total), dst))

def compare(local, total, limit, label):
    """Read the file back from the PS5 from the start and diff it against the staged copy.
    Sequential only, because REST is ignored by both servers -- there is no reading from an
    offset, which is what an earlier version of this got wrong. Both sides are streamed and
    diffed a chunk at a time, so a 12 GiB file is never held in memory."""
    n = total if limit is None else min(limit, total)
    print("==> comparing %s of %s against %s" % (human(n), human(total), label))
    g = ps5()
    sock = g.transfercmd("RETR " + PS5_ISO_DIR + name)
    ok, done, started, last = True, 0, time.time(), 0
    try:
        with open(local, "rb") as fh:
            while done < n:
                want = min(CHUNK, n - done)
                remote = bytearray()
                while len(remote) < want:
                    c = sock.recv(want - len(remote))
                    if not c:
                        break
                    remote.extend(c)
                if not remote:
                    break
                if bytes(remote) != fh.read(len(remote)):
                    print("    differ at %s" % human(done))
                    ok = False
                    break
                done += len(remote)
                if done - last >= (512 << 20):
                    last = done
                    progress(done, n, started, 0)
    finally:
        sock.close()
        try: g.voidresp()
        except Exception: pass
        g.close()
    return ok, done

def do_verify():
    if not name:
        sys.exit("iso-transfer.sh: verify needs a file name")
    local = staged(name)
    if not os.path.exists(local):
        sys.exit("iso-transfer.sh: nothing staged at %s" % local)
    total = os.path.getsize(local)
    g = ps5()
    remote = size(g, PS5_ISO_DIR + name)
    g.close()
    if remote is None:
        sys.exit("iso-transfer.sh: %s is not on the PS5" % (PS5_ISO_DIR + name))
    print("size  staged %s   PS5 %s" % (human(total), human(remote)))
    if remote != total:
        sys.exit("iso-transfer.sh: sizes differ -- run 'put' to continue from what landed")
    limit = None if mode == "--full" else VERIFY_PREFIX
    ok, done = compare(local, total, limit, "the staged copy")
    print("=> %s (%s of %s compared)" % ("verified" if ok else "FAILED", human(done), human(total)))
    if ok and limit is not None:
        print("   only the head was compared; 'verify %s --full' does the whole file" % name)
    sys.exit(0 if ok else 1)

def do_push():
    do_get()
    do_put()
    do_verify()

{"list": do_list, "get": do_get, "put": do_put, "push": do_push, "verify": do_verify}[cmd]()
PY
