# Debugging slow / silent `make`

When `make` does nothing visible for several seconds, the cost is
almost always in a **child process** (a `$(shell ...)` call, a
dispatched sub-make, or a recipe body).  This page walks through the
tools I actually reach for, in the order I reach for them, with the
real numbers from the pydep 1.5 s import case as a worked example.
§9 is a second, complete walk-through: an idle `make` going from
0.95 s to 0.13 s (Oct 2026).


## 0. Confirm the problem is real

```bash
time make >/dev/null 2>&1    # cold run
time make >/dev/null 2>&1    # idle run (repeat 3x, look at 2nd+)
```

The steady-state idle number is what matters.  Fresh-tree numbers are
dominated by real compile work.  If idle is > 500 ms on a small tree,
something is calling out to a child process on every invocation.

Also compare `-j` values:

```bash
for j in 1 2 4 8 ; do
    t=$(TIMEFORMAT=%R ; { time make -j$j >/dev/null 2>&1 ; } 2>&1)
    printf "  -j%s : %ss\n" "$j" "$t"
done
```

A big `-j1` vs `-j4` gap tells you the bottleneck is parallelisable
work (many independent sub-processes), not a single serial thing.


## 1. Count the sub-processes

`strace -c` counts syscalls per category; `-f` follows child forks:

```bash
strace -f -c -e trace=execve,fork,vfork,clone,wait4 make 2>&1 >/dev/null | tail -10
```

Sample (pre-fix pydep case):

```
% time     seconds  usecs/call     calls    errors syscall
 99.16    2.261626        6370       355       112 wait4
  0.39    0.008936          56       159           clone
  0.34    0.007794          35       222           execve
```

`wait4` at 99 % is the smoking gun — the parent make spends its time
**waiting on children**.  The `usecs/call` column tells you how long
each wait was on average.  Multiply by the call count for total.


## 2. Which children?

```bash
strace -f -e trace=execve -o /tmp/gm.log make >/dev/null 2>&1
awk -F'"' '/execve/ && !/ENOENT/ { print $2 }' /tmp/gm.log \
    | sort | uniq -c | sort -rn | head -15
```

For an idle gm build, expect something like `bash > find > make >
python3`.  A surprise entry (or a large count of something
"obvious") is your lead.  In the pydep case, `python3` appeared 3
times per idle build — one per `pkg-*` dispatch — which turned out
to be the culprit.


## 3. Which target is the slow one?

Wrap the dispatcher recipe in `Makefile` with a timer so each phony
prints its own dispatch cost.  Temporary edit:

```makefile
$(TARGET_ALL):
	@/tmp/dispatch-timer.sh $@ \
	    $(MAKE) -C $(SOURCE_DIR) ...
```

`/tmp/dispatch-timer.sh`:

```bash
#!/bin/bash
target="$1" ; shift
t0=$(date +%s%N)
"$@"
rc=$?
printf "  DISPATCH %-25s %5s ms\n" "$target" $(( ($(date +%s%N) - t0) / 1000000 )) >&2
exit $rc
```

Then `make 2>&1 | grep DISPATCH | sort -k3 -n -r` shows the top
consumers.  From the pydep case (measured on the earlier example tree, whose pkg-p2 / pkg-p3
were YAML pkgs and j1 / j2 java targets):

```
  DISPATCH pkg-p2                     3341 ms
  DISPATCH pkg-p3                     3172 ms
  DISPATCH libp2alarms                1626 ms
  DISPATCH j1                          549 ms
  DISPATCH j2                          526 ms
```

Three targets each burning multiple seconds — pkg-related.  This
narrows the hunt.


## 4. What is that ONE sub-make doing?

Reproduce the exact dispatcher command line for one slow target:

```bash
make -n pkg-tmd | head -20
```

That gives you the literal `make -C <dir> -f <env.mk> -f <user.mk>
-f <target.pkg.mk> BUILD_DIR=... OUT_DIR=... ...`.  Run it directly
with a per-syscall trace:

```bash
strace -f -T -tt -e trace=execve,wait4 \
    make -C /path/to/example -f env.mk -f user.mk -f target.pkg.mk \
    BUILD_DIR=... OUT_DIR=... SOURCE_DIR=... REL_DIR=... TYPE=pkg \
    2>&1 >/dev/null | head -50
```

Flags:

| flag | meaning |
|------|---------|
| `-f` | follow child forks (make is inside a bash, which is inside make) |
| `-T` | show wall-clock time each syscall took, in `<0.001234>` at end of line |
| `-tt` | timestamp each line to microsecond precision |
| `-e trace=execve,wait4` | filter to just process starts and process waits |
| `-o FILE` | write trace to file instead of stderr (huge output; use this) |


## 5. Reading the trace: find the long `<...>` or long gap

Two ways a syscall shows up as slow:

1. **`<N.NNNNNN>` at end** — the syscall itself took `N.NNNNNN`
   seconds.  `wait4` values are the time we spent waiting on that
   child.  Anything > 100 ms is worth investigating.
2. **Big gap between adjacent `-tt` timestamps** — the child
   process took that long even though the parent didn't call any
   syscall itself.

For the pydep case, the trace showed:

```
20:51:20.563872: execve("/usr/bin/python3", ["python3", "-c",
                        "import yaml, jsonschema"], ...) = 0
20:51:22.205316: wait4(-1, [...]) = 3552206  <1.641610>
```

**1.64 seconds** spent inside one `python3 -c 'import yaml,
jsonschema'` call.  Multiplied by 3 pkg targets, that's ~5 s of the
6.5 s idle-build time.  Fix: stamp-file cache the check (later
simplified — see the [pydep discussion in
env.mk](../production/make/env.mk)).


## 6. gm-specific hot spots to check

Common offenders that have caused pain before (the first five are fixed; check them again
when an idle build slows down -- they come back with innocent-looking edits):

| where | test | now |
|-------|------|-----|
| `target.pkg.mk` pydeps check | `python3 -c 'import yaml, jsonschema'` -- heavy C-ext imports, ~20 ms warm, ~1.5 s cold | only when the YAML cache is rebuilt |
| `target.pkg.mk` `_YAML_INTREE` | `python3 pkg-build.py --print-intree-targets` per pkg AND per `<pkg>-header` sub-goal (~95 ms each) | `_CACHE` in BUILD_DIR |
| `target.go.mk` `_GO_SRCS` | `go list -deps` per go target (~50 ms warm, more cold; runs `git status` unless `-buildvcs=false`) | `_CACHE` in BUILD_DIR |
| host probes (`command -v go/jq/ccache/...`, `uname -m`, `rpm --eval`) | one shell each, per sub-make | one shell in the top-level make, exported; rpm's dist cached |
| recursive variables with `$(shell)` | `X ?= $(shell ...)` re-runs at every reference; exported, at every recipe line (`SOURCE_DATE_EPOCH` ran `git log` 24 times) | computed once with `:=` |
| `depend.mk` regen | fires whenever any `.mk` is newer OR `_DEP_DIGEST` mismatches -- one DRY_RUN sub-make per target | by design; only for a goal that builds targets (`list`, `help`, `clean`, ... never scan: `_GM_GOALS_ALONE`, graph.mk) |
| CDB aggregator | `find build/ -name '*.cc.json'` -- should short-circuit via mtime check | does |

If your build is slow AFTER `make distclean`, that's real work
(compiles).  If it's slow when idle, it's one of these.


## 7. Sanity check: reproduce in isolation

Once you've picked a suspect, isolate it outside gm entirely:

```bash
time python3 -c 'import yaml, jsonschema'
time bash -c 'command -v ccache'
time go list -deps -f '{{.Dir}}' ./...
```

If the isolated timing matches (or exceeds) what strace saw, the
tool itself is slow and needs caching / avoidance.  If the isolated
timing is much faster, the cost is contextual — env vars,
`MAKEFLAGS`, jobserver token starvation, filesystem cache state.


## 8. Cleanup

If you added an instrumentation `sed`, remember to `git checkout` the
Makefile after — several past incidents (this session included) had
stray timers or `--no-print-directory` toggles committed by mistake.
`git diff Makefile` before every commit involving the top-level file.


## 9. Worked example: idle `make` 0.95 s -> 0.13 s (Oct 2026)

The example tree of the time (21 targets: C/C++, Go, Java, two YAML pkgs, one spec pkg,
imports; the target names below are from that tree -- the example/ of today is a different
one) took ~1 s for a `make` with nothing to do.  The whole hunt, with the commands that found each step.

### 9.1 Measure without strace

strace multiplies the cost of every fork, so absolute numbers come from plain timing: best of
five, after one warm-up run, per goal.

```bash
cat > /tmp/gmtime.sh <<'EOF'
#!/bin/bash
make -s "$@" >/dev/null 2>&1                       # warm-up
best=99999
for _ in 1 2 3 4 5; do
    s=$(date +%s%N); make -s "$@" >/dev/null 2>&1; e=$(date +%s%N)
    v=$(( (e - s) / 1000000 )); [ "$v" -lt "$best" ] && best=$v
done
echo "$best ms  make $*"
EOF
bash /tmp/gmtime.sh                                   # 943 ms
bash /tmp/gmtime.sh list                              #  60 ms: top-level parse alone
for t in libt1 g1 pkg-p1 libp2alarms pkg-p2; do bash /tmp/gmtime.sh $t; done
```

```
  74 ms  make libt1          # = 60 ms top level + ~15 ms sub-make
 126 ms  make g1             # go: ~65 ms of its own
 143 ms  make pkg-p1
 223 ms  make libp2alarms    # a C lib -- but it needs pkg-p2's component.h
 286 ms  make pkg-p2
```

A goal's time includes the goals it depends on; subtract them.  `libp2alarms` costing more than
a whole pkg was the first lead: its `pkg-p2-header` sub-goal runs a full pkg sub-make.

### 9.2 Count and group the children

```bash
strace -f -qq -e trace=execve -e signal=none -o /tmp/st.txt make -s >/dev/null 2>&1
grep -v ENOENT /tmp/st.txt | grep execve | sed -E 's/^[0-9]+ +//; s/execve\("[^"]*", \[//; s/\], 0x.*//' \
    | sed 's/"//g' | cut -c1-110 | sort | uniq -c | sort -rn | head -30
```

333 processes for a no-op.  Grouped by argv (not just by binary -- `bash -c` hides everything):

```
 24 git -C <top> log -1 --format=%ct          # SOURCE_DATE_EPOCH
 24 bash -c sig='...' ; [ "$sig" = "$(cat ...)" ]   # flag stamps (+ 24 cat)
 23 bash -c command -v jq / 23 command -v ccache    # one probe per sub-make
 19 find <dir> -name '*.h.in'                 # generated headers, per C target
  8 find <dir> -name '*.java' -print -quit    # target classification, top level
  8 uname -m / 4 rpm --eval %{?dist} / 4 command -v rpmbuild
  3 python3 -c 'import importlib.util ...'    # pydeps check
  2 python3 pkg-build.py --print-intree-targets
  2 go list -deps ...                         # each also runs git status + git log
```

Twenty-four `git log` calls for one variable is the tell-tale of a **recursive** variable:
`SOURCE_DATE_EPOCH ?= $(shell git ...)` re-runs the shell at every reference, and because it is
exported, make expands it again for every recipe line it starts.

### 9.3 Timeline of one goal

Counts say what runs; a timeline says what costs.  exec -> exit per process, from one trace:

```bash
strace -f -ttt -qq -e trace=execve,exit_group -e signal=none -o /tmp/st.txt make -s pkg-p2 >/dev/null 2>&1
python3 - <<'EOF'
import re
start, argv, end = {}, {}, {}
for line in open('/tmp/st.txt'):
    m = re.match(r'(\d+)\s+([\d.]+)\s+(.*)', line)
    if not m: continue
    pid, t, rest = int(m[1]), float(m[2]), m[3]
    if rest.startswith('execve(') and '= 0' in rest:
        a = re.search(r'\[(.*?)\]', rest); start.setdefault(pid, t); argv[pid] = (a[1] if a else '')[:120]
    elif rest.startswith('exit_group') or '+++ exited' in rest:
        end[pid] = t
t0 = min(start.values())
for pid in sorted(start, key=start.get):
    print(f"{(start[pid]-t0)*1000:7.1f} +{(end.get(pid, start[pid])-start[pid])*1000:6.1f}ms  {argv[pid]}")
EOF
```

```
  335.3 +  25.1ms  rpm --eval %{?dist}
  402.6 +  24.6ms  python3 -c import importlib.util ...
  428.2 + 117.2ms  python3 pkg-build.py --pkg .../pkg.yaml ... --print-intree-targets ...
  550.1 +  24.3ms  rpm --eval %{?dist}
```

(strace times; isolated, `pkg-build.py --print-intree-targets` is ~95 ms, the pydeps check and
`rpm --eval` ~18 ms each -- §7.)  For `g1` the same view showed `go list` spending most of its
time in `git status --porcelain` and `git log`: VCS stamping, which `-buildvcs=false` turns off.

### 9.4 What was changed

| cost | fix | where |
|------|-----|-------|
| pkg.yaml artefact list: python per pkg and per `<pkg>-header`, ~95 ms each | `_CACHE`: a makefile in BUILD_DIR, rebuilt when pkg.yaml / pkg-build.py is newer or the arguments differ; the pydeps check moved into its recipe | `target.pkg.mk` |
| `go list` per go target | `_CACHE`, rebuilt when a listed source, a directory holding one (files added / removed), go.mod / go.sum or the go env file changes; `-buildvcs=false`; deleted sources get empty rules (cf. `-MP`) | `target.go.mk` |
| `rpm --eval '%{?dist}'` per pkg sub-make | asked once per tree and cached in GM_OUT (rebuilt when rpm's macro files change) | `project.mk` |
| host probes per sub-make (`go javac jar jq ccache rpmbuild`, `uname -m`, hostname, `git log`) | ONE shell in the top-level make (`GM_TREE` still empty), exported; sub-makes inherit | `env.mk` |
| recursive `$(shell)` variables (`SOURCE_DATE_EPOCH`, `JAVASOURCE`, `GO`, `RPM_TARGET_ARCH`) | `:=`, computed once | `env.mk`, `target.java.mk`, `target.pkg.mk` |
| flag stamps: bash + cat per stamp | `_FLAG_STAMP`: `$(file <stamp)` compared at parse time; a rule (writing with `$(file >)`, not under `-n`) only when the flags changed | `env.mk` |
| `*.h.in` find per C target | first one find for all C targets in the top-level make; then no find at all: the .mk lists its templates (`HEADER_GEN`), so a stray `.h.in` is not generated either | `target.c.mk` |
| `.java` find per candidate target, `sort \| uniq -d` for duplicates | first one find (`-printf '%H'`); then none: java targets are `<name>.java.mk` with a declared `JAVASOURCE`; duplicates in pure make | `project.mk`, `target.java.mk` |

Result, no-op `make` on the example tree (Rocky 8 host; Ubuntu 24.04 and Rocky 9 containers
~0.1 s):

| | before | after |
|---|---|---|
| processes started | 333 | 87 |
| `make` | 943 ms | 126 ms |
| `make -j8` | -- | 59 ms |
| top-level parse (`make list`) | 60 ms | 34 ms |

What is left is structural: one sub-make per target (~4 ms each -- make starting and parsing
env.mk / flags.mk / target.*.mk), and the top-level parse (the `*.mk` scan, the probe shell,
`md5sum` of the .mk list).

### 9.5 Pitfalls met on the way

- **A cache that writes a broken makefile bricks every build**: `-include` parses it before
  anything can rebuild it.  The first version wrote python's multi-line output verbatim
  (`missing separator`).  Write single lines, through a `.tmp` + `mv`.
- **A cache keyed on its own value needs a restart guard.**  `_CACHE` forces a rebuild when the
  stored key differs; after the rebuild make re-reads its makefiles (`MAKE_RESTARTS`), and the
  force is only applied when `MAKE_RESTARTS` is empty, so a key that never matches cannot loop.
- **An empty result is not a value**: `go list` prints nothing when offline.  Caching that would
  keep the target silently stale; an empty value is not keyed, so the next make retries.
- **Prerequisites read from a cache can disappear** (a deleted `.go`): without an empty rule per
  file the build stops at "No rule to make target".
- **`$(file >)` runs at expansion time**, even under `make -n`; the stamp write checks for `n`
  in `MAKEFLAGS` (`_GM_MAKE_N`, env.mk) so a dry run cannot record flags that were never
  compiled with.
- **Under `make -n` nothing another sub-make builds reaches the disk**: on a variant never built,
  a link stopped at "No rule to make target '-lgtest'".  Only under `-n`, the in-tree `-lX`,
  `component.h`, `JAR_DEPS` jars and packaged artefacts get an empty rule; make still looks for
  the file first, so a built variant previews exactly what would rerun (precheck 17 leg U).
- **Never export a probe under a tool's own name**: `CCACHE_PATH` is read by ccache itself (the
  compiler search path), so the probe is `_GM_CCACHE`.
- **Measure the pieces in isolation** before caching (§7): `go list` looked like ~500 ms under
  strace and is ~50 ms on its own.

### 9.6 Keeping it fast

`precheck` check 17 leg L builds `tmd`, then runs the same no-op build with
`python3` and `rpm` replaced by logging shims on PATH: any call fails the check.  The rules
behind it are in AGENTS.md ("No-op cost").


## Summary

Order of tools, cheapest to most expensive:

1. `time make` (three runs, look at steady-state; best-of-N per goal, §9.1)
2. `strace -c -e trace=wait4,execve,fork,clone,vfork` (counts, ~10 s)
3. `strace -f -e execve -o /tmp/g.log ; awk | sort | uniq -c` (top offenders, ~10 s)
4. Dispatch-timer wrapper on `Makefile` (per-target ms, ~30 s)
5. `strace -f -T -tt -e execve,wait4` on the ONE slow sub-make, or the exec -> exit timeline
   (§9.3) (line-level, few minutes)
6. Isolated reproduction of the suspect tool

Escalate only as much as you need — if step 2 already points at one
process type dominating, you might not need steps 3-5.
