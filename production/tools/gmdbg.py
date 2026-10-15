#!/usr/bin/env python3
"""gm debugging helpers: `gm watch`, `gm core`, `gm symbols` (docs/1-USER_GUIDE.md 3.16).

One file, two roles.  Run by python it is the command line; run by gdb
(`gdb -x gmdbg.py`, config in $GMDBG_CFG) it is the gdb-side script.  The report
goes to a private fd so gdb's own chatter never reaches the terminal.
Stdlib only, Python >= 3.6.
"""
import argparse
import collections
import json
import linecache
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time

try:
    import gdb  # type: ignore  # only importable inside gdb
except ImportError:
    gdb = None

STORE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                     "gm", "debug")
SYSTEM_DEBUG = "/usr/lib/debug"
M64 = (1 << 64) - 1
_CFG: dict = {}


def die(msg, code=2):
    print("gm: " + msg, file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- ELF helpers
def _elf_sections(path):
    """-> list of (name, type, offset, size); [] if not ELF."""
    try:
        with open(path, "rb") as f:
            ident = f.read(16)
            if ident[:4] != b"\x7fELF":
                return []
            e = "<" if ident[5] == 1 else ">"
            if ident[4] == 2:
                h = struct.unpack(e + "HHIQQQIHHHHHH", f.read(48))
                shoff, shentsize, shnum, shstrndx = h[5], h[10], h[11], h[12]
                fmt, pick = e + "IIQQQQIIQQ", lambda t: (t[0], t[1], t[4], t[5])
            else:
                h = struct.unpack(e + "HHIIIIIHHHHHH", f.read(36))
                shoff, shentsize, shnum, shstrndx = h[5], h[10], h[11], h[12]
                fmt, pick = e + "IIIIIIIIII", lambda t: (t[0], t[1], t[4], t[5])
            if not shoff or not shnum:
                return []
            f.seek(shoff)
            raw = [pick(struct.unpack(fmt, f.read(shentsize)[:struct.calcsize(fmt)]))
                   for _ in range(shnum)]
            _, _, stroff, strsz = raw[shstrndx]
            f.seek(stroff)
            strtab = f.read(strsz)
            out = []
            for nm, ty, off, sz in raw:
                end = strtab.find(b"\0", nm)
                out.append((strtab[nm:end].decode("latin-1"), ty, off, sz))
            return out
    except (OSError, struct.error, IndexError):
        return []


def build_id(path):
    """GNU build-id of an ELF file (stripped or not), or None."""
    secs = _elf_sections(path)
    for name, ty, off, sz in secs:
        if ty != 7 or name != ".note.gnu.build-id":
            continue
        with open(path, "rb") as f:
            f.seek(off)
            data = f.read(sz)
        e = "<" if open(path, "rb").read(6)[5] == 1 else ">"
        namesz, descsz, ntype = struct.unpack(e + "III", data[:12])
        if ntype == 3:
            desc = data[12 + ((namesz + 3) & ~3):][:descsz]
            return desc.hex()
    return None


def has_debug_info(path):
    return any(n == ".debug_info" and ty != 8 for n, ty, _, _ in _elf_sections(path))


# ------------------------------------------------------------- symbol store
def debug_dirs(extra=()):
    return [d for d in list(extra) + [STORE, SYSTEM_DEBUG]]


def _store_file(bid):
    return os.path.join(STORE, ".build-id", bid[:2], bid[2:] + ".debug")


def _index_path():
    return os.path.join(STORE, "index.json")


def _load_index():
    try:
        with open(_index_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _add_debug_file(path, index, src):
    bid = build_id(path)
    if not bid or not has_debug_info(path):
        return None
    dst = _store_file(bid)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(path, dst)
    index[bid] = {"name": os.path.basename(path), "src": src, "size": os.path.getsize(dst)}
    return bid


def _extract_rpm(rpm, dest):
    if not (shutil.which("rpm2cpio") and shutil.which("cpio")):
        die("rpm2cpio + cpio are needed to unpack %s (or unpack it elsewhere and add the dir)" % rpm)
    p1 = subprocess.Popen(["rpm2cpio", rpm], stdout=subprocess.PIPE)
    p2 = subprocess.run(["cpio", "-idm", "--quiet"], stdin=p1.stdout, cwd=dest,
                        stderr=subprocess.PIPE)
    p1.stdout.close()
    if p1.wait() != 0 or p2.returncode != 0:
        die("cannot unpack %s: %s" % (rpm, p2.stderr.decode(errors="replace").strip()))


def cmd_symbols(a):
    os.makedirs(STORE, exist_ok=True)
    index = _load_index()
    if a.action == "add":
        if not a.items:
            die("symbols add: needs a debuginfo rpm, a directory, or an unstripped ELF/.debug file")
        added = 0
        for item in a.items:
            tmp = None
            root = item
            if os.path.isfile(item) and item.endswith(".rpm"):
                tmp = tempfile.mkdtemp(prefix="gm-symbols-")
                _extract_rpm(item, tmp)
                root = tmp
            files = [root] if os.path.isfile(root) else [
                os.path.join(d, n) for d, _, ns in os.walk(root) for n in ns]
            for fp in files:
                if os.path.islink(fp):
                    continue
                if _add_debug_file(fp, index, os.path.basename(item)):
                    added += 1
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
        with open(_index_path(), "w") as f:
            json.dump(index, f, indent=1, sort_keys=True)
        print("gm symbols: added %d debug file(s); store: %s" % (added, STORE))
        return 0 if added else 1
    if a.action == "list":
        for bid, m in sorted(index.items(), key=lambda kv: kv[1].get("name", "")):
            print("%s  %-32s %9d  %s" % (bid, m.get("name", "?"), m.get("size", 0), m.get("src", "")))
        print("(%d entries in %s)" % (len(index), STORE))
        return 0
    # find
    if not a.items:
        die("symbols find: needs an ELF file or a build-id")
    rc = 0
    for item in a.items:
        bid = item if re.fullmatch(r"[0-9a-f]{8,}", item) else build_id(item)
        if not bid:
            print("%s: no build-id (not ELF, or built without --build-id)" % item)
            rc = 1
            continue
        hits = [p for p in (_store_file(bid),
                            os.path.join(SYSTEM_DEBUG, ".build-id", bid[:2], bid[2:] + ".debug"))
                if os.path.exists(p)]
        own = os.path.isfile(item) and has_debug_info(item)
        state = "has its own debug info" if own else (hits[0] if hits else "MISSING")
        print("%s  %s  %s" % (bid, item, state))
        rc = rc or (1 if state == "MISSING" else 0)
    return rc


# ------------------------------------------------------------ gdb launching
# Variables that can point gdb at a foreign libpython / stdlib (venv, pyenv, setup-python, ...).
_PY_ENV = ("LD_LIBRARY_PATH", "PYTHONHOME", "PYTHONPATH")
_PROBE = "python import struct, json, subprocess, threading, tempfile; print('gm-py-ok')"


def _gdb_python_ok(g, env):
    r = subprocess.run([g, "-nx", "-batch", "-ex", _PROBE], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return b"gm-py-ok" in r.stdout, r.stdout.decode("utf-8", "replace").strip()


def _find_gdb(a):
    """-> (gdb path, env for gdb itself, vars withheld from gdb to hand to the target)."""
    g = getattr(a, "gdb", None) or os.environ.get("GDB") or shutil.which("gdb")
    if not g:
        die("gdb not found (install it, e.g. dnf install gdb), or pass --gdb / GDB=")
    ok, why = _gdb_python_ok(g, None)
    if ok:
        return g, dict(os.environ), {}
    held = {k: os.environ[k] for k in _PY_ENV if k in os.environ}
    if held:
        env = {k: v for k, v in os.environ.items() if k not in held}
        if _gdb_python_ok(g, env)[0]:
            return g, env, held
    die("%s: its embedded Python is unusable%s (gm watch / gm core need a gdb with working Python):\n  %s"
        % (g, " even without %s" % "/".join(held) if held else "", why.replace("\n", "\n  ")), 3)


def _ancestors():
    out, pid = set(), os.getpid()
    while pid > 1:
        out.add(pid)
        try:
            with open("/proc/%d/stat" % pid) as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return out


def _find_pids(pattern):
    rx, skip, out = re.compile(pattern), _ancestors(), []
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) in skip:
            continue
        try:
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            continue
        if cmd and rx.search(cmd):
            out.append((int(d), cmd))
    return out


def _wait_pid(pattern, wait):
    end = time.time() + wait
    while True:
        found = _find_pids(pattern)
        if len(found) == 1:
            return found[0][0]
        if len(found) > 1:
            lines = "\n".join("  %d  %s" % (p, c[:100]) for p, c in found)
            die("--name '%s' matches %d processes; use --pid:\n%s" % (pattern, len(found), lines))
        if time.time() >= end:
            die("no process matches --name '%s'%s" % (pattern, " (waited %ds)" % wait if wait else ""))
        time.sleep(0.5)


def _run_gdb(a, cfg, target_args, timeout=None):
    """Run gdb with this file as its script; -> (exit code, noise lines)."""
    g, gdb_env, held = _find_gdb(a)
    dirs = ":".join(debug_dirs(a.symdir or []))
    cmd = [g, "-nx", "-q", "-batch",
           "-iex", "set pagination off", "-iex", "set confirm off",
           "-iex", "set width 0", "-iex", "set height 0",
           "-iex", "set debug-file-directory " + dirs]
    if getattr(a, "sysroot", None):
        cmd += ["-iex", "set sysroot " + a.sysroot]
    if getattr(a, "src", None):  # debug info records paths relative to the checkout root
        cmd += ["-iex", "set substitute-path . " + a.src]
    cmd += ["-x", os.path.abspath(__file__)] + target_args
    out_fd = os.dup(1)
    cfg = dict(cfg, out_fd=out_fd, target_env=held)
    env = dict(gdb_env, GMDBG_CFG=json.dumps(cfg))
    proc = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, pass_fds=(out_fd,))
    noise = collections.deque(maxlen=60)
    def drain():
        for raw in proc.stdout:
            noise.append(raw.decode("utf-8", "replace").rstrip())

    t = threading.Thread(target=drain, daemon=True)
    t.start()
    timer = None
    if timeout:
        timer = threading.Timer(timeout, lambda: proc.poll() is None and proc.send_signal(signal.SIGINT))
        timer.start()
    interrupted = 0
    while True:
        try:
            proc.wait()
            break
        except KeyboardInterrupt:
            interrupted += 1
            if interrupted > 2:
                proc.kill()
    if timer:
        timer.cancel()
    t.join(2)
    os.close(out_fd)
    if getattr(a, "verbose", False) or proc.returncode not in (0, 2, 3):
        for line in noise:
            print("gdb: " + line, file=sys.stderr)
    return proc.returncode


def _parse_int(s):
    try:
        return int(s, 0)
    except ValueError:
        raise argparse.ArgumentTypeError("not a number: %r" % s)


def cmd_watch(a):
    if sum(x is not None for x in (a.sym, a.addr, a.expr)) != 1:
        die("watch: give exactly one of --sym / --addr / --expr")
    if a.length is not None and a.length not in (1, 2, 4, 8, 16, 24, 32):
        die("watch: --len must be 1, 2, 4, 8 or a multiple of 8 up to 32 (4 debug registers)")
    cfg = {"mode": "watch", "sym": a.sym, "addr": a.addr, "expr": a.expr, "length": a.length,
           "cond": a.cond, "kernel": a.kernel, "deref": a.deref, "off": a.off, "max_hits": a.max_hits, "bt": a.bt,
           "launch": bool(a.command), "at": a.at}
    if a.command:
        return _run_gdb(a, cfg, ["--args"] + a.command, a.timeout)
    if a.pid is None and not a.name:
        die("watch: give --pid, --name, or a command after --")
    while True:
        pid = a.pid if a.pid is not None else _wait_pid(a.name, a.wait)
        rc = _run_gdb(a, cfg, ["-p", str(pid)], a.timeout)
        if rc == 3 and a.repeat and a.name:  # target exited: wait for the next instance
            print("[gm] target exited; waiting for the next .%s." % a.name, flush=True)
            time.sleep(1)
            continue
        return 0 if rc == 3 else rc


def cmd_core(a):
    if not os.path.isfile(a.core):
        die("core: no such file: " + a.core)
    cfg = {"mode": "core", "core": os.path.abspath(a.core), "exe": a.exe and os.path.abspath(a.exe),
           "frames": a.frames, "full": a.full, "threads": a.threads}
    return _run_gdb(a, cfg, [])


# -------------------------------------------------------------- gdb side
def _out(s=""):
    data = (s + "\n").encode("utf-8", "replace")
    fd = _CFG.get("out_fd")
    if fd is None:
        sys.stdout.write(s + "\n")
        sys.stdout.flush()
    else:
        os.write(fd, data)


def _ulong(v):
    return int(v.cast(gdb.lookup_type("unsigned long"))) & M64


def _run(cmd):
    return gdb.execute(cmd, to_string=True)


def _q(path):
    return path.replace("\\", "\\\\").replace(" ", "\\ ")


def _read_b(addr, n):
    return bytes(gdb.selected_inferior().read_memory(addr, n))


def _read_u(addr, n):
    return int.from_bytes(_read_b(addr, n), "little")


def _hex(v, n=8):
    return "0x%0*x" % (n * 2, v)


def _val(raw):
    """Little-endian bytes as the integer a debugger would show (hex digits)."""
    return raw[::-1].hex() if len(raw) <= 8 else raw.hex()


def _chunks(addr, length):
    """Split [addr, addr+length) into naturally aligned 8/4/2/1 byte pieces."""
    out = []
    while length > 0:
        for s in (8, 4, 2, 1):
            if addr % s == 0 and s <= length:
                out.append((addr, s))
                addr, length = addr + s, length - s
                break
    return out


# x86-64 syscalls that store into a user buffer: nr -> (name, kind, args)
_KSYS = {0: ("read", "buf", ("rsi", "rdx")), 17: ("pread64", "buf", ("rsi", "rdx")),
         45: ("recvfrom", "buf", ("rsi", "rdx")), 89: ("readlink", "buf", ("rsi", "rdx")),
         217: ("getdents64", "buf", ("rsi", "rdx")), 318: ("getrandom", "buf", ("rdi", "rsi")),
         19: ("readv", "iov", ("rsi", "rdx")), 295: ("preadv", "iov", ("rsi", "rdx")),
         47: ("recvmsg", "msg", ("rsi",)), 232: ("epoll_wait", "epoll", ("rsi", "rdx")),
         281: ("epoll_pwait", "epoll", ("rsi", "rdx"))}


class _Watch(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.hits = 0
        self.done = False
        self.exited = False
        self.sig = None
        self.bps = []
        self.lo = self.hi = 0
        self.last = b""

    # -- resolution / arming
    def resolve(self):
        c = self.cfg
        if c["addr"] is not None:
            return int(c["addr"]), c["length"] or 8
        if c["sym"]:
            for expr in ("&'%s'" % c["sym"], "&%s" % c["sym"]):
                try:
                    return _ulong(gdb.parse_and_eval(expr)), c["length"] or 8
                except gdb.error:
                    continue
            raise RuntimeError("symbol '%s' not found.  Stripped binary?  Add its debuginfo "
                               "(gm symbols add <debuginfo rpm|dir>) or use --addr." % c["sym"])
        try:
            v = gdb.parse_and_eval(c["expr"])
            return _ulong(v.address), c["length"] or int(v.type.sizeof)
        except gdb.error as e:
            raise RuntimeError("cannot evaluate '%s' as an lvalue: %s\n    stripped binary? gm symbols add "
                               "<debuginfo rpm|dir>, or use --sym [--deref]" % (c["expr"], e))

    def arm(self):
        addr, length = self.resolve()
        if self.cfg["deref"]:
            ptr = addr
            addr = _read_u(ptr, 8)
            if not addr:
                raise RuntimeError("the pointer at %s is NULL; attach after it is set" % _hex(ptr))
            _out("[gm] pointer at %s holds %s" % (_hex(ptr), _hex(addr)))
        addr += self.cfg["off"]
        pieces = _chunks(addr, length)
        if len(pieces) > 4:
            raise RuntimeError("%d bytes at %s need %d debug registers (max 4); narrow --len"
                               % (length, _hex(addr), len(pieces)))
        self.lo, self.hi = addr, addr + length
        self.last = _read_b(addr, length)
        watch = self

        class W(gdb.Breakpoint):
            def stop(self):  # noqa: N805
                return watch.on_write()

        ctype = {8: "unsigned long", 4: "unsigned int", 2: "unsigned short", 1: "unsigned char"}
        for a, s in pieces:
            bp = W("*(%s *)0x%x" % (ctype[s], a), gdb.BP_WATCHPOINT, gdb.WP_WRITE)
            if bp.type != gdb.BP_HARDWARE_WATCHPOINT:
                raise RuntimeError("no hardware watchpoint available (gdb fell back to software, "
                                   "which would stall the process); refusing")
            self.bps.append(bp)
        mod = gdb.solib_name(addr)
        _out("[gm] watching %s..%s (%d bytes) with %d hardware watchpoint(s)%s"
             % (_hex(addr), _hex(addr + length), length, len(pieces),
                "  in %s" % mod if mod else ""))
        _out("[gm] initial value: 0x%s" % _val(self.last))
        if self.cfg["kernel"]:
            self.arm_kernel()
        _out("[gm] max hits: %s.  Ctrl-C detaches cleanly." % (self.cfg["max_hits"] or "unlimited"))

    def arm_kernel(self):
        if not gdb.newest_frame().architecture().name().startswith("i386:x86-64"):
            raise RuntimeError("--kernel supports x86-64 only")
        watch = self

        class KW(gdb.Function):
            def __init__(self):
                super(KW, self).__init__("_gm_kw")

            def invoke(self):  # noqa: N805
                try:
                    return 1 if watch.on_syscall() else 0
                except Exception as e:  # stop visibly rather than loop on errors
                    _out("[gm] --kernel check failed: %s" % e)
                    watch.done = True
                    return 1
        KW()
        _run("catch syscall " + " ".join(str(n) for n in sorted(_KSYS)))
        n = int(gdb.parse_and_eval("$bpnum"))
        _run("condition %d $_gm_kw()" % n)
        _out("[gm] --kernel: also checking read/recv/... writes into the range "
             "(2 ptrace stops per syscall; expect a slow target)")

    # -- hits
    def _frames(self):
        return _run("bt %d" % self.cfg["bt"]).rstrip()

    def _tid(self):
        t = gdb.selected_thread()
        return "tid %s" % (t.ptid[1] or t.ptid[0]) if t else "tid ?"

    def _finish_hit(self):
        self.hits += 1
        if self.cfg["max_hits"] and self.hits >= self.cfg["max_hits"]:
            self.done = True
        return self.done

    def on_write(self):
        new = _read_b(self.lo, self.hi - self.lo)
        c = self.cfg["cond"]
        if c:
            try:
                if not gdb.parse_and_eval(c):
                    self.last = new
                    return False
            except gdb.error as e:
                _out("[gm] --if error: %s" % e)
        _out("=== write #%d  %s  %s ===" % (self.hits + 1, time.strftime("%F %T"), self._tid()))
        _out("%s: 0x%s -> 0x%s   (stopped just after the storing instruction)"
             % (_hex(self.lo), _val(self.last), _val(new)))
        _out(self._frames())
        _out()
        self.last = new
        return self._finish_hit()

    def _arg(self, name):
        return int(gdb.parse_and_eval("$" + name)) & M64

    def on_syscall(self):
        ret = self._arg("rax")
        if ret == (-38) & M64:  # syscall entry; the buffer is filled on exit
            return False
        nr = self._arg("orig_rax")
        spec = _KSYS.get(nr)
        if not spec or ret >= (1 << 63):
            return False
        name, kind, regs = spec
        args = [self._arg(r) for r in regs]
        spans = []
        if kind == "buf":
            spans = [(args[0], ret)]
        elif kind == "epoll":
            spans = [(args[0], ret * 12)]
        else:
            if kind == "msg":
                iov, cnt = _read_u(args[0] + 16, 8), _read_u(args[0] + 24, 8)
            else:
                iov, cnt = args
            left = ret
            for i in range(min(cnt, 1024)):
                base, ln = _read_u(iov + 16 * i, 8), _read_u(iov + 16 * i + 8, 8)
                spans.append((base, min(ln, left)))
                left -= min(ln, left)
        hit = [(b, n) for b, n in spans if n and b < self.hi and b + n > self.lo]
        if not hit:
            return False
        b, n = hit[0]
        _out("=== kernel write #%d  %s  %s ===" % (self.hits + 1, time.strftime("%F %T"), self._tid()))
        _out("%s() stored %d byte(s) at %s, overlapping %s..%s"
             % (name, n, _hex(b), _hex(self.lo), _hex(self.hi)))
        _out(self._frames())
        _out()
        return self._finish_hit()

    # -- run loop
    def on_stop(self, ev):
        self.sig = getattr(ev, "stop_signal", None)

    def run(self):
        gdb.events.stop.connect(self.on_stop)
        gdb.events.exited.connect(lambda ev: setattr(self, "exited", True))
        _run("handle all nostop noprint pass")
        _run("handle SIGSEGV SIGABRT SIGBUS SIGFPE SIGILL stop print pass")
        while True:
            self.sig = None
            try:
                _run("continue")
            except (gdb.error, KeyboardInterrupt) as e:
                if self.exited or "not being run" in str(e):
                    self.exited = True
                    break
                if "insert hardware" in str(e) or "hardware breakpoints" in str(e):
                    raise RuntimeError("this CPU / VM refuses hardware watchpoints (no debug "
                                       "registers).  Try a bare-metal host, or ASan.")
                if isinstance(e, KeyboardInterrupt) or "Quit" in str(e):
                    break
                raise
            if self.exited or self.done or self.sig in (None, "SIGINT"):
                break
            _out("=== target received %s ===" % self.sig)
            _out(self._frames())
            _out()
        if self.exited:
            _out("[gm] target exited after %d hit(s)" % self.hits)
            gdb.execute("quit 3")
        for bp in self.bps:
            bp.delete()
        try:
            _run("detach")
        except gdb.error:
            pass
        _out("[gm] detached after %d hit(s)" % self.hits)


def _watch_main(cfg):
    try:
        _watch_launch_and_run(cfg)
    except RuntimeError as e:
        _out("gm: " + str(e))
        gdb.execute("quit 2")


def _watch_launch_and_run(cfg):
    if cfg["launch"]:
        n = len(gdb.breakpoints() or ())
        for k, v in cfg["target_env"].items():
            _run("set environment %s %s" % (k, v))
        _run("tbreak %s" % (cfg["at"] or "main"))
        if len(gdb.breakpoints() or ()) == n:
            raise RuntimeError("--at '%s': no such location" % cfg["at"])
        _run("run")
        if gdb.selected_thread() is None:
            raise RuntimeError("the program ended before reaching --at '%s'" % (cfg["at"] or "main"))
    elif gdb.selected_thread() is None:
        raise RuntimeError("cannot attach: the process is gone, or ptrace is refused (run as its "
                           "owner with kernel.yama.ptrace_scope=0, or as root / CAP_SYS_PTRACE)")
    w = _Watch(cfg)
    w.arm()
    w.run()


# -- core analysis
_SI = {0: "SI_USER (kill)", -6: "SI_TKILL (tgkill / abort)", -1: "SI_QUEUE", 128: "SI_KERNEL (raised by the kernel)"}
_SEGV = {1: "SEGV_MAPERR (address not mapped)", 2: "SEGV_ACCERR (permission)"}
_BUS = {1: "BUS_ADRALN (misaligned)", 2: "BUS_ADRERR (no such physical address)"}
_FPE = {1: "FPE_INTDIV (integer divide by zero)", 2: "FPE_INTOVF", 3: "FPE_FLTDIV", 4: "FPE_FLTOVF"}
_FILL = {0xcd: "tcmalloc_debug 'freed' fill: the object was freed (use after free)",
         0xdd: "freed-memory fill (use after free)", 0xfe: "freed-memory fill (use after free)",
         0x5a: "MALLOC_PERTURB_ fill", 0xa5: "MALLOC_PERTURB_ fill", 0xab: "uninitialised-memory fill"}
_ALLOC = ("malloc_printerr", "_int_free", "_int_malloc", "malloc_consolidate", "unlink_chunk",
          "_int_realloc", "__libc_malloc", "__libc_free", "__libc_calloc", "free", "malloc",
          "calloc", "realloc", "cfree", "tc_free", "tc_malloc", "tc_new", "tc_delete")
_MEM_X86 = re.compile(r"(-?0x[0-9a-f]+)?\(%(\w+)(?:,%\w+(?:,\d)?)?\)")
_IND_X86 = re.compile(r"\b(?:call|jmp)\w*\s+\*%(\w+)")
_MEM_A64 = re.compile(r"\[(x\d+|sp)(?:, #(-?\d+|-?0x[0-9a-f]+))?\]")


def _describe_value(v):
    """Human reading of a bad pointer value."""
    if v == 0:
        return "NULL"
    if v < 0x10000:
        return "small integer %s (NULL + offset)" % hex(v)
    raw = v.to_bytes(8, "little")
    if all(0x20 <= b < 0x7f for b in raw):
        return "ASCII text '%s' (a char buffer overran into this pointer)" % raw.decode()
    if len(set(raw)) == 1 and raw[0] in _FILL:
        return _FILL[raw[0]]
    if len(set(raw[:4])) == 1 and raw[0] in _FILL and v >> 32 == v & 0xffffffff:
        return _FILL[raw[0]]
    if (v >> 47) not in (0, 0x1ffff):
        return "non-canonical address (corrupted pointer)"
    return None


def _readable(addr):
    try:
        gdb.selected_inferior().read_memory(addr, 1)
        return True
    except gdb.MemoryError:
        return False


def _classify(sig, code, addr, names, insn, regs, pc_ok, near_sp):
    """-> list of (headline, [hint, ...])"""
    out = []
    has = lambda *ns: next((n for n in names if n in ns), None)  # noqa: E731
    if sig == "SIGABRT":
        if has("__assert_fail", "__GI___assert_fail", "__assert_perror_fail"):
            out.append(("assertion failed (assert)", ["The frame above __assert_fail has the "
                                                      "condition; `frame N` + `info locals`."]))
        elif has("__stack_chk_fail"):
            out.append(("stack smashing detected", [
                "A stack buffer in the caller of __stack_chk_fail was overrun by an earlier write.",
                "Rebuild with SANITIZE=address on a dev box; or gm watch the canary slot."]))
        elif has("__fortify_fail", "__chk_fail", "__GI___chk_fail", "__fortify_fail_abort"):
            out.append(("_FORTIFY_SOURCE check failed", [
                "The frame that called the *_chk function wrote past its destination buffer."]))
        elif has("malloc_printerr", "__libc_message", "malloc_consolidate"):
            out.append(("glibc detected heap corruption (free/malloc checks)", [
                "The bad write happened EARLIER; this stack is only where it was noticed.",
                "Field fallback without a rebuild: LD_PRELOAD=libtcmalloc_debug.so (see docs 3.13);",
                "if a known object is being corrupted: gm watch --pid <pid> --sym/--addr ..."]))
        elif has("__cxa_throw", "std::terminate", "_ZSt9terminatev", "__gnu_cxx::__verbose_terminate_handler"):
            out.append(("uncaught C++ exception -> std::terminate", [
                "No handler existed, so nothing unwound: the frame below __cxa_throw is the throw site."]))
        else:
            out.append(("abort() called", ["The frame that called abort / raise is the one to read."]))
    elif sig in ("SIGSEGV", "SIGBUS"):
        if code == 0x80:
            out.append(("general-protection fault (kernel-raised SIGSEGV)", [
                "Usually a non-canonical address or a misaligned SSE access (movaps).  "
                "si_addr is 0 by design; use the instruction's registers below."]))
        elif near_sp:
            out.append(("stack overflow (fault address %s is next to sp)" % hex(addr), [
                "Unbounded recursion (the repeating frames show which) or a huge stack array."
                + ("  %d frames deep." % len(names) if len(names) > 500 else "")]))
        elif addr is not None and addr < 0x10000:
            out.append(("NULL pointer dereference (field offset %s)" % hex(addr),
                        ["The object pointer was NULL: find who should have set it."]))
        elif addr is not None:
            why = _describe_value(addr)
            out.append(("invalid access at %s%s" % (hex(addr), " -> " + why if why else ""), []))
        if insn and not near_sp:
            m = _MEM_X86.search(insn) or _MEM_A64.search(insn) or _IND_X86.search(insn)
            if m:
                reg = m.group(2) if m.re is _MEM_X86 else m.group(1)
                val = regs.get(reg)
                if val is not None:
                    why = _describe_value(val)
                    verb = "jumps through" if m.re is _IND_X86 else "dereferences"
                    out.append(("faulting instruction %s %s = %s%s" % (
                        verb, reg, hex(val), " -> " + why if why else ""), []))
        if not pc_ok:
            out.append(("jump to an invalid address (pc not mapped)", [
                "Corrupted function pointer, vtable or return address: `x/16gx $sp` and look for "
                "values that are not code addresses (often ASCII text or a fill pattern)."]))
        if has(*_ALLOC):
            out.append(("crash inside the allocator", [
                "Allocator metadata was corrupted by an earlier overrun / double free.",
                "The faulting frame is only the victim; use gm watch or libtcmalloc_debug (docs 3.13)."]))
    elif sig == "SIGFPE":
        m = re.search(r"\bi?div\w*\s+%(\w+)", insn or "")
        reg = m and ("r" + m.group(1)[1:] if m.group(1)[0] == "e" else m.group(1))
        zero = reg in regs and regs[reg] & (0xffffffff if m.group(1)[0] == "e" else M64) == 0
        out.append(("integer divide by zero" if zero else "arithmetic fault", [
            "The divisor register of `%s` is 0: find where it was computed." % insn] if zero else []))
    elif sig == "SIGILL":
        out.append(("illegal instruction", [
            "Either control flow jumped into data (see 'jump to invalid address'), or the binary "
            "uses a CPU feature this host lacks (-march)."]))
    elif sig in ("SIGTERM", "SIGKILL", "SIGINT", "SIGHUP", "SIGXCPU", "SIGQUIT"):
        out.append(("terminated by %s" % sig, ["An external sender (or a resource limit): the stack "
                                               "is just where the thread was."]))
    return out


def _core_main(cfg):
    core, exe = cfg["core"], cfg["exe"]
    if exe:
        _run("file " + _q(exe))
    head = _run("core-file " + _q(core))
    if not exe:
        m = re.search(r"Core was generated by `([^'\s]+)", head)
        if m and os.path.isfile(m.group(1)):
            exe = m.group(1)
            _run("file " + _q(exe))
            head = _run("core-file " + _q(core))
        else:
            _out("gm: cannot find the executable (%s); pass --exe" % (m.group(1) if m else "?"))
    sigline = re.search(r"Program terminated with signal (\w+), ([^.]+)", head)
    sig = sigline.group(1) if sigline else "?"
    _out("core:   %s" % core)
    _out("exe:    %s" % (exe or "?"))
    _out("signal: %s" % ("%s, %s" % sigline.groups() if sigline else "?"))

    code = addr = None
    try:
        si = gdb.parse_and_eval("$_siginfo")
        code = int(si["si_code"])
        addr = int(si["_sifields"]["_sigfault"]["si_addr"]) & M64
        tbl = {"SIGSEGV": _SEGV, "SIGBUS": _BUS, "SIGFPE": _FPE}.get(sig, {})
        _out("code:   %s" % tbl.get(code, _SI.get(code, "si_code=%d" % code)))
        if sig in ("SIGSEGV", "SIGBUS"):
            _out("fault address: %s" % hex(addr))
    except (gdb.error, RuntimeError):
        pass

    # frames of the crashing thread
    names, mods, f = [], {}, gdb.newest_frame()
    n = 0
    culprit = None
    while f is not None and n < 10000:
        names.append(f.name() or "??")
        sal = f.find_sal()
        if sal.symtab is None:
            so = gdb.solib_name(f.pc())
            mods.setdefault(so or exe or "?", names[-1])
        elif culprit is None:
            culprit = (n, f.name(), sal.symtab.filename, sal.line, sal.symtab.fullname())
        f = f.older()
        n += 1
    _out()
    _out("--- backtrace (crashing thread) ---")
    _out(_run("bt %s%s" % ("full " if cfg["full"] else "", cfg["frames"] or "")).rstrip())

    insn, regs = None, {}
    try:
        if sig not in ("SIGSEGV", "SIGBUS", "SIGFPE", "SIGILL"):
            raise gdb.error("no hardware fault")
        insn = _run("x/i $pc").split("\t", 1)[-1].strip()
        arch = gdb.newest_frame().architecture().name()
        for r in (("rax rbx rcx rdx rsi rdi rbp r8 r9 r10 r11 r12 r13 r14 r15".split())
                  if "x86" in arch else ["x%d" % i for i in range(31)]):
            regs[r] = int(gdb.parse_and_eval("$" + r)) & M64
        _out()
        _out("--- faulting instruction ---")
        _out("pc=%s  %s" % (hex(int(gdb.parse_and_eval("$pc")) & M64), insn))
    except gdb.error:
        pass
    pc_ok = _readable(int(gdb.parse_and_eval("$pc")) & M64)
    sp = int(gdb.parse_and_eval("$sp")) & M64
    near_sp = sig == "SIGSEGV" and addr is not None and code in (1, 2) and abs(addr - sp) < 0x100000

    findings = _classify(sig, code, addr, names, insn, regs, pc_ok, near_sp)
    _out()
    _out("--- analysis ---")
    if culprit:
        src = linecache.getline(culprit[4], culprit[3]).strip()[:90]
        _out("first frame with source: #%d %s at %s:%d%s" % (
            culprit[0], culprit[1], culprit[2], culprit[3], "   | " + src if src else ""))
    if not findings:
        _out("no known pattern matched; read the backtrace above.")
    for head_, hints in findings:
        _out("* " + head_)
        for h in hints:
            _out("    " + h)

    if cfg["threads"]:
        _out()
        _out("--- all threads ---")
        _out(_run("thread apply all bt 12").rstrip())
    else:
        _out()
        _out("--- threads ---")
        cur = gdb.selected_thread()
        for t in gdb.selected_inferior().threads():
            t.switch()
            fr = gdb.newest_frame()
            _out("%s thread %d (LWP %s): %s" % ("*" if t.num == cur.num else " ", t.num,
                                              t.ptid[1], fr.name() or "??"))
        cur.switch()
        _out("(--threads for full stacks)")

    missing = []
    mod_real = set(os.path.realpath(m) for m in mods if os.path.exists(m))
    for o in gdb.objfiles():
        if not o.is_valid() or not o.filename or not os.path.exists(o.filename):
            continue
        if os.path.realpath(o.filename) in mod_real:
            sep = any(x.owner is o for x in gdb.objfiles() if x.is_valid())
            if not sep and not has_debug_info(o.filename):
                missing.append((o.filename, o.build_id or build_id(o.filename)))
    if missing:
        _out()
        _out("--- missing debug info (frames above are bare addresses / no line numbers) ---")
        for fn, bid in missing:
            _out("%s  build-id %s" % (fn, bid or "?"))
        _out("fix: gm symbols add <the matching *-debuginfo-*.rpm | dir>   (no root needed), then re-run")


def _gdb_entry():
    global _CFG
    _CFG = json.loads(os.environ["GMDBG_CFG"])
    try:
        {"watch": _watch_main, "core": _core_main}[_CFG["mode"]](_CFG)
    except gdb.error as e:
        _out("gm: gdb error: %s" % e)
        gdb.execute("quit 2")


# ------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(prog="gm", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    def common(p):
        p.add_argument("--symdir", action="append", metavar="DIR",
                       help="extra debug-file directory (build-id layout); repeatable")
        p.add_argument("--sysroot", metavar="DIR", help="root holding the target's shared libs")
        p.add_argument("--src", metavar="DIR",
                       help="checkout the binary was built from (debug info paths are relative to it)")
        p.add_argument("--gdb", metavar="PATH")
        p.add_argument("-v", "--verbose", action="store_true", help="show gdb's own output")

    w = sub.add_parser("watch", help="find who writes to an address (hardware watchpoint)")
    tgt = w.add_mutually_exclusive_group()
    tgt.add_argument("--pid", type=int)
    tgt.add_argument("--name", metavar="REGEX", help="match the full command line")
    w.add_argument("--wait", type=int, default=0, metavar="SEC", help="wait for --name to appear")
    w.add_argument("--repeat", action="store_true", help="re-attach when the --name target restarts")
    w.add_argument("--sym", help="symbol, mangled or demangled (its address, or see --deref)")
    w.add_argument("--addr", type=_parse_int, help="absolute address")
    w.add_argument("--expr", help="gdb lvalue expression, resolved once")
    w.add_argument("--deref", action="store_true",
                   help="--sym/--addr holds a pointer: watch what it points to")
    w.add_argument("--off", type=_parse_int, default=0, help="byte offset added to the final address")
    w.add_argument("--len", dest="length", type=int, help="bytes (default 8 / sizeof)")
    w.add_argument("--if", dest="cond", metavar="EXPR", help="report only when this gdb expr is true")
    w.add_argument("--kernel", action="store_true", help="also catch read/recv/... into the range")
    w.add_argument("-n", "--max-hits", type=int, default=10, help="then detach (0 = unlimited)")
    w.add_argument("--at", metavar="LOC", help="launch mode: run to this location (default main) before arming")
    w.add_argument("--bt", type=int, default=12, help="frames per hit")
    w.add_argument("--timeout", type=int, metavar="SEC")
    common(w)
    w.add_argument("command", nargs="*", help="-- CMD ARGS: launch under gdb instead of attaching")
    w.set_defaults(fn=cmd_watch)

    c = sub.add_parser("core", help="analyse a core file offline")
    c.add_argument("core")
    c.add_argument("--exe")
    c.add_argument("-n", "--frames", type=int, default=0, help="backtrace depth (0 = all)")
    c.add_argument("--full", action="store_true", help="include locals")
    c.add_argument("--threads", action="store_true", help="stacks of all threads")
    common(c)
    c.set_defaults(fn=cmd_core)

    s = sub.add_parser("symbols", help="root-free debuginfo store")
    s.add_argument("action", choices=("add", "list", "find"))
    s.add_argument("items", nargs="*")
    s.set_defaults(fn=cmd_symbols)

    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    if gdb is not None:
        _gdb_entry()
    else:
        sys.exit(main())
