# Debugging slow / silent `make`

When `make` does nothing visible for several seconds, the cost is
almost always in a **child process** (a `$(shell ...)` call, a
dispatched sub-make, or a recipe body).  This page walks through the
tools I actually reach for, in the order I reach for them, with the
real numbers from the pydep 1.5 s import case as a worked example.


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
consumers.  From the pydep case:

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
make -n pkg-p2 | head -20
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

Common offenders that have caused pain before:

| where | test |
|-------|------|
| `env.mk` `_pydep-pkg` / stamp | `pytohn3 -c 'import yaml, jsonschema'` — heavy C-ext imports, ~1.5 s cold |
| `flags.mk` ccache probe | `command -v ccache` per sub-make (~5 ms × N) |
| `target.pkg.mk` DRY_RUN | `python3 pkg-build.py --print-intree-targets` per pkg (~200-500 ms each) |
| `target.go.mk` `_GO_SRCS` | `go list -deps` per go target (~200 ms warm, ~500 ms cold) |
| `depend.mk` regen | fires whenever any `.mk` is newer OR `_DEP_DIGEST` mismatches — 15 DRY_RUN sub-makes at once |
| CDB aggregator | `find build/ -name '*.cc.json'` — should short-circuit via mtime check |

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


## Summary

Order of tools, cheapest to most expensive:

1. `time make` (three runs, look at steady-state)
2. `strace -c -e trace=wait4,execve,fork,clone,vfork` (counts, ~10 s)
3. `strace -f -e execve -o /tmp/g.log ; awk | sort | uniq -c` (top offenders, ~10 s)
4. Dispatch-timer wrapper on `Makefile` (per-target ms, ~30 s)
5. `strace -f -T -tt -e execve,wait4` on the ONE slow sub-make (line-level, few minutes)
6. Isolated reproduction of the suspect tool

Escalate only as much as you need — if step 2 already points at one
process type dominating, you might not need steps 3-5.
