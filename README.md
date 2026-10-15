
# gm — auto-dependence-deduced build framework

Zero-configuration, raw-GNU-make build system for polyglot repos.  Drop a
`<name>.mk` file next to your source; gm classifies it, builds it, and
folds it into a whole-tree dep graph — no central registry, no DSL, no
subdir bookkeeping.  Builds are **reproducible** (byte-identical in any
directory), hardened, and debuggable in the field.

**Documentation map**

| doc | scope |
|-----|-------|
| this file (`README.md`) | landing page: install + hard constraints + repo shape |
| [`docs/1-USER_GUIDE.md`](docs/1-USER_GUIDE.md) | everything you actually *do* with gm — start here |
| [`docs/2-NAMING.md`](docs/2-NAMING.md) | why `.mk` basenames must be globally unique |
| [`docs/3-DRY_RUN.md`](docs/3-DRY_RUN.md) | how `depend.mk` regenerates (3-generation make dance) |
| [`docs/4-DEBUGGING.md`](docs/4-DEBUGGING.md) | profiling a slow / silent `make` (strace recipes) |
| [`docs/5-CM_DESIGN.md`](docs/5-CM_DESIGN.md) | where gm sits in the 4-layer product stack |
| [`docs/6-TODO.md`](docs/6-TODO.md) | outstanding design gaps (P1–P3) |
| [`AGENTS.md`](AGENTS.md) | design internals, invariants, contributor notes |
| [`container/README.md`](container/README.md) | the standalone container-image tool (not gm) |


## Features

- **Reproducible compilation — verified, on by default.**  The same sources give
  *byte-identical* libraries, executables, jars, Go binaries and RPMs (the `-debuginfo` ones
  too) in **any directory**, and on any host once `BUILD_HOST` is fixed.  Checked on Rocky 8,
  Rocky 9 and Ubuntu 24.04: two trees under different paths and hostnames hash identically,
  artefact by artefact; `make precheck` and CI re-prove it on every push.  Nothing to remember:
  `SOURCE_DATE_EPOCH` (default: last commit time), `-ffile-prefix-map`, deterministic
  `ar` / jar / rpm and Go `-trimpath -buildid=` are the defaults
  ([USER_GUIDE §3.15](docs/1-USER_GUIDE.md#315-reproducible-builds))
- **Zero configuration** — drop a `<name>.mk` next to your source; C/C++, Go, Java and RPM
  in one tree, classified by filename convention.  No registry, no DSL
- **Automatic build order** — lib-level deps derived from what you link (`depend.mk`,
  parallel-safe via per-target fragments: `-jN deps` needs no coordination); file-level DAG
  (`.dep.json`) behind `make changes ... / refresh SINCE=...`
- **Exact incremental builds** — CFLAGS / CCFLAGS / LDFLAGS / ARFLAGS are hashed into stamp
  files, so changing a flag rebuilds only the affected objects, no `make clean`; the framework
  files themselves are tracked, touch `flags.mk` and downstream targets rebuild
- **Hardened by default** — stack protector, FORTIFY, PIE, relro/now, `$ORIGIN` RPATH, and a
  strict warning set with `-Werror` (`WARN_LEVEL=warn|lax` to relax it)
- **Instrumentation as build axes** — `SANITIZE=address,undefined,thread` and `COVERAGE=1`
  each get their own output tree next to `BUILD_MODE=debug|release`, so variants never
  overwrite each other; `make coverage` writes a gcovr / lcov report
- **Field debugging without redeploying** — a split `-debuginfo` RPM for every package, plus
  `gm core` (crash report with cause hints), `gm watch` (who writes this address: hardware
  watchpoint, also catches `read()`-into-buffer) and `gm symbols` (root-free debuginfo store)
- **YAML-driven RPM packages** — schema-validated, spec generated for you (scriptlets,
  provides / conflicts, `%config`, `%dir`, `%ghost`), per-pkg `component.h` + versionstamp
  macros wired into consumers
- **Project-wide flags in your own top-level Makefile** — `PROJECT_CPPFLAGS / _CFLAGS /
  _CCFLAGS / _LDFLAGS`, `WARN_LEVEL`, `HARDEN`, `CXX_STD`; the framework carries no product
  flags of its own
- **Vendored, or next to your repo** — copy `production/` into the project, or keep gm as its
  own checkout beside it (`SINGLE_REPO=N`); either way the tree layout stays yours
- **Tolerant of what is missing** — no `go`, `javac`/`jar`, `rpmbuild` or `jq`: a `SKIP` line
  names what was left out and the rest still builds
- Vendored / prebuilt artefacts via `.import.mk` (multi-artefact: a mix of `.so` / `.a` / exe)
- Header generation (`*.h.in`), gtest test targets (`make test`)
- `compile_commands.json` auto-refreshed on every `make` (clangd / VS Code / vim / Zed pick
  it up with no extra config)
- `make precheck` runs every CI static check locally with one command


## Requirements

- **GNU make ≥ 4.2** (tested on 4.2.1 and 4.3), bash, coreutils, findutils (`find` lists the
  `.mk` files; minimal Rocky 8 images do not ship it)
- **gcc/g++** (Rocky 8 ships 8.5; use `gcc-toolset-N` for newer C++ —
  see [Toolchain](#toolchain))
- **Python ≥ 3.12** with PyYAML + jsonschema (`make prereq`).  A tree with YAML pkg targets
  (gm's `example/` has two) needs them for the dependency scan: without them `make` stops and
  says so.  Rocky's own `python3` is older (3.6 on Rocky 8, 3.9 on Rocky 9): use `python3.12`.
- Optional, per language: `rpmbuild` (pkg targets), `javac`/`jar`
  (java), `go` (go), `jq` (`compile_commands.json`, `DEP_TREE=yes`), `gcovr` or `lcov`
  (coverage), `libasan` / `libubsan` / `libtsan` (`SANITIZE=`).  An absent tool leaves only the
  targets that need it out of `make` (a `SKIP` line names them); the rest still builds.

### A new machine, step by step

Checked from the bare `ubuntu:24.04`, `rockylinux:9` and `rockylinux:8.10` images: each step
below was the next thing missing, and after the last one `make`, `make test`,
`make SANITIZE=address test TESTS=test-asan`, `make coverage` and `make precheck` pass.

**1. Compiler, make, git, Python 3.12** -- enough to build and test every C/C++ target:

```bash
# Ubuntu 24.04
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential git ca-certificates python3 python3-venv

# Rocky 9 / Rocky 8
sudo dnf install -y gcc gcc-c++ make git findutils python3.12
```

**2. gm's Python packages**, in a virtual environment ([`production/requirements.txt`](production/requirements.txt):
PyYAML, jsonschema, gcovr, diff-cover, ruff, mypy, types-PyYAML):

```bash
python3 -m venv .venv          # Rocky: python3.12 -m venv .venv
source .venv/bin/activate      # again in every new shell, before make
make prereq
```

`make prereq` scans nothing first (it runs before PyYAML is there); it picks `--user` outside a
venv, no `--user` inside, and is idempotent.

**3. Build:**

```bash
make -j"$(nproc)"
make -j"$(nproc)" test
```

Without the optional tools this already passes; the `SKIP` lines name what was left out (go,
java, the rpms, `compile_commands.json`).

**4. Optional tools** -- each one brings back the targets or checks that need it:

```bash
# Ubuntu 24.04
sudo apt-get install -y --no-install-recommends jq ccache rpm golang-go default-jdk-headless shellcheck gdb

# Rocky 9 / Rocky 8 (jq, ccache and ShellCheck come from EPEL)
sudo dnf install -y epel-release
sudo dnf install -y jq ccache ShellCheck rpm-build golang java-11-openjdk-devel gdb libasan libubsan
```

| tool | gives |
|------|-------|
| `jq` | `compile_commands.json`, `DEP_TREE=yes` |
| `ccache` | cached recompiles |
| `rpm` / `rpm-build` | the pkg targets' rpms |
| `golang`, a JDK | the go and java targets |
| `libasan`, `libubsan` (RHEL; Ubuntu's gcc has them) | `SANITIZE=address,undefined` (`libtsan` for `thread`) |
| `shellcheck`, `gdb` | `make precheck` (it skips what is missing) |

`make coverage` uses gcovr from step 2.  `make coverage-lcov` also needs lcov (Ubuntu: `lcov`;
RHEL: `lcov perl-DateTime perl-JSON` from `powertools` / `crb`).  CI provisions the same tools
in [`.github/actions/setup-gm-env/action.yml`](.github/actions/setup-gm-env/action.yml).


## Quickstart

On a machine set up as in [A new machine, step by step](#a-new-machine-step-by-step):

```bash
source .venv/bin/activate
make          # build every discovered target
make test     # build + run every test-*
```

Everything else — adding a target, dependency queries, vendoring,
integrating gm into an outer build — lives in
[`docs/1-USER_GUIDE.md`](docs/1-USER_GUIDE.md).


## Usage (essentials)

The full command table lives in [USER_GUIDE §4](docs/1-USER_GUIDE.md#4-everyday-commands).
The gm-specific entry points:

| command                              | meaning                                          |
|--------------------------------------|--------------------------------------------------|
| `make prereq`                        | one-shot Python deps install                     |
| `make`                               | build every discovered target                    |
| `make <target>`                      | build one target                                 |
| `make <target> SUB_TARGET=clean`     | clean one target's output                        |
| `make distclean`                     | wipe `$(GM_OUT)`                                 |
| `make deps`                          | force-regenerate `depend.mk` from scratch        |
| `make list`                          | what gm discovered                               |
| `make show`, `make show-<type\|t>`   | what gm derived: types, deps, users, build order, per-type facts |
| `make DEP_TREE=yes`                  | build + emit `.dep.json` sidecars                |
| `make changes CHANGES="a.cc b.h"`    | which targets do these files affect?             |
| `make refresh SINCE=<git-ref>`       | rebuild only what git-diff changed since         |
| `make deps-snap`                     | project-relative dep cache under `build/deps/`   |
| `make coverage`                      | gcovr report: rebuild with `COVERAGE=1`, run exes + unit tests |
| `make SANITIZE=address [test]`       | AddressSanitizer on any mode (opt-in; own `<mode>-asan/` tree) |
| `make -jN test`                      | parallel build + parallel run of every `test-*`  |
| `make precheck`                      | every local static check (CI parity)             |
| `gm core <core>`                     | crash report: signal, fault, cause hints, missing symbols |
| `gm watch --pid P --sym S --deref`   | who writes this memory? (`--kernel`: also read()/recv()) |
| `gm symbols add <debuginfo.rpm>`     | root-free debuginfo store for `gm core` / `gm watch` |
| `make run-<name> RUN_ARGS='...'`     | build + execute any exe/test/go target           |


## Hard constraints

Enforced at parse time; see [USER_GUIDE §10](docs/1-USER_GUIDE.md#10-troubleshooting)
for what the error messages look like, [AGENTS.md](AGENTS.md) for why
each rule exists.

- **`.mk` basename is the universal identifier.**  It is the dispatch
  key, the artefact filename, the `-l<name>` reference, the
  `PKG_HEADERS` reference, and the `depend.mk` edge label.  Two `.mk`
  files with the same basename anywhere in the tree is a hard error
  (gm lists every colliding path).  Fix by `git mv old.mk new.mk`.
  There is no rename knob — `AR_NAME` / `LIB_NAME` / `BIN_NAME` are
  gone; setting one is a `$(error)`.
- **No nested `gm`.**  gm cannot invoke another gm tree from inside a
  build — the two trees' tree-scoped exports (`PROJ_TOP`, `ADMIN_DIR`,
  `GM_OUT`, every `GM_*_DIR`, ...) would collide.  Guard: env.mk sets
  `export GM_TREE := 1`, and the top-level Makefile refuses to start
  if `GM_TREE` is already set on entry.  What is **fine**: invoking
  non-gm sub-makes from a recipe (they don't include gm's env.mk) or
  spawning an inner gm tree with the marker cleared —
  `GM_TREE= $(MAKE) -C other-gm-tree all`.  Full walkthrough in
  [USER_GUIDE §8](docs/1-USER_GUIDE.md#8-integrating-gm-into-another-build-system).
- **Published artefacts are flat by type; intermediates are
  per-target.**  Only the final products live in flat per-type
  directories (`.a`/`.so` → `$(GM_LIB_DIR)`, exe/test/go →
  `$(GM_EXEC_DIR)`, `.jar` → `$(GM_JAVA_DIR)`, `.rpm` →
  `$(GM_PKG_DIR)`).  All intermediates (`.o`, `.d`, per-obj
  `.dep.json`, flag stamps, generated headers) stay in per-target
  `$(BUILD_DIR) = $(GM_OUT)/<relpath>/<arch>/<mode>/`.  The **published**
  tier is deliberately flat so plain `-lname` link-time resolution
  works without a per-target `-L`; the intermediates tier is deliberately
  per-target so nothing collides.
- **Type is decided by filename and sibling files — never by content.**
  The classifier runs top-to-bottom over each `.mk`, first match wins:
    1. `.java.mk` suffix → java;  `.import.mk` suffix → `import-lib` (if
       the file's basename starts with `lib`) or `import-exe`
    2. filename starts with `test-` → test
    3. filename starts with `lib`   → lib
    4. a sibling `go.mod` exists    → go
    5. filename starts with `pkg-`  → pkg
    6. otherwise                    → exe

  Nothing inside the `.mk` (comments, strings, variable assignments)
  can flip the classification.  This kept a subtle bug alive in
  earlier revisions where a docstring saying "no AR_NAME needed here"
  silently flipped a shared lib to static.
- **`.mk` files are pure declarations; you cannot `make -f libfoo.mk`
  directly.**  The rules live in `target.<type>.mk` and only the
  dispatcher composes them.  If you want less typing from a
  sub-directory, use `make -C $(PROJ_TOP) libfoo`.


## Repo layout

```
<repo>/
├── Makefile                  # top-level dispatcher
├── production/               # the build system itself
│   ├── make/                 #   env.mk, project.mk, flags.mk,
│   │                         #   target.{c,go,java,pkg,import}.mk, ...
│   │   ├── scripts/          #   pkg-build.py, dep_query.py, pkgdeps.py, ...
│   │   └── schemas/          #   pkg.schema.yaml
│   └── tools/                #   pydep/, dep-hooks.sh, gtest-1.14.0/, ...
├── example/                  # the example product (example/README.md)
├── third_party/              # its third-party libraries: compiled by gm, or vendor-built
├── container/                # sibling image-build tool (NOT gm)
└── build/                    # $(GM_OUT), gitignored
```

Two paths steer the whole build:

- `PROJ_TOP` — repo root (where user source lives)
- `ADMIN_DIR` — `$(PROJ_TOP)/production` (where the framework lives)
- `SINGLE_REPO` — `Y` (default): gm is vendored in the project.  `N`: gm is a checkout
  next to the project repo(s); run `make` in the gm checkout, `PROJ_TOP` is its parent

Either way, put `production/tools/gm` on `PATH` (symlink it) and `gm <target>` works from any
directory: inside a vendored project it uses that tree, elsewhere with `SINGLE_REPO=N`
exported it uses the gm checkout it belongs to.

They are decoupled so `production/` can be a `git subtree`, submodule,
or shared checkout without touching any user `.mk`.  Vendoring
recipe is [USER_GUIDE §7](docs/1-USER_GUIDE.md#7-shipping-a-sub-project-on-its-own-vendoring);
the sibling layout is §7.5.


## Toolchain

gm picks its compilers the way CMake / autoconf do: **`CC`** (C) and
**`CXX`** (C++, also the link driver) from the environment or the command
line (an absolute path, or a name on `PATH`), else the first `gcc` / `g++` on
`PATH` (ccache masquerade dirs such as `/usr/lib64/ccache` are skipped).  That
is all: a toolchain that ships its own compilers (a vendored gcc, a
`gcc-toolset`) provides an `enable` script that prepends `PATH`, exactly like
`source /opt/rh/gcc-toolset-13/enable`.

gm only ever *reads* `CC` / `CXX`: its own command lines are `GM_CC` /
`GM_CXX` / `GM_LD` (ccache-wrapped), so vendor builds (`CC ?= gcc` in
`third_party/*/vendor`) see exactly what you chose.

| var       | default                          | purpose                |
|-----------|----------------------------------|------------------------|
| `CXX_STD` | `c++17`                          | C++ language standard  |

### Newer gcc on Rocky 8 (gcc-toolset)

Rocky 8's stock gcc 8.5 has partial C++17 and no C++20.  Install
`gcc-toolset-13` (a good 2026 baseline) and use it either way (the third line is for
Debian / Ubuntu, where versioned names exist; RHEL toolsets ship plain `gcc` / `g++`):

```bash
source /opt/rh/gcc-toolset-13/enable        # only prepends PATH -- gm follows PATH
make -jN CXX_STD=c++20

CC=/opt/rh/gcc-toolset-13/root/usr/bin/gcc \
CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++ make -jN CXX_STD=c++20   # explicit

make -jN CC=gcc-13 CXX=g++-13               # Debian / Ubuntu: versioned names on PATH
```

The compile-flag stamp includes the compiler path, so switching compilers in
an existing tree rebuilds what is affected.  Keep the C and C++ compilers from the
same toolchain (set both `CC` and `CXX`, or neither).  Not every toolset is a full
C++ toolchain: gcc-toolset-9 here ships `gcc` only, no `g++`.

### ccache

Enabled automatically when a `ccache` binary is on `PATH` — cuts a
cold rebuild of `example/` from ~20 s to ~1 s.

| var             | default | meaning                                        |
|-----------------|---------|------------------------------------------------|
| `CCACHE_ENABLE` | `auto`  | `auto` = use if present, silently skip if not; `yes`/`1` insists; `no`/`0` disables |
| `CCACHE_PATH`   | auto    | absolute path; unset → search `$(ADMIN_DIR)/tools/ccache-*/ccache` then `$PATH` |


## Examples

`example/` is one small product, `tm` -- a telemetry daemon in C++ on C libraries, with a Go
exporter, a Java dashboard, two third-party libraries and three rpms -- written to exercise
what gm does.  [`example/README.md`](example/README.md) maps every directory to the feature it
shows and walks through the commands (`make show`, `make changes`, reproducibility, sanitizers,
`gm core`).

| dir | targets | shows |
|-----|---------|-------|
| `example/core`, `example/stats` | `libtmcore` (static C), `libtmstats` (shared C++), their tests | header generation, edges from `LDLIBS`, `PKG_HEADERS := yes` |
| `example/daemon` | `tmd`, `libtmalarms`, `pkg-tmd` | four kinds of library in one link, alarms and an rpm from `pkg.yaml` |
| `example/cli`, `example/tmtools` | `tmctl`, `pkg-tm-tools` | a C exe, an rpm from a hand-written `.spec` |
| `example/sdk` | `pkg-tm-devel` | a library in two packages, custom filegroups |
| `example/exporter`, `example/cgo` | `tmexport`, `tmcrc` | Go, cgo on an in-tree C library |
| `example/dashboard` | `tmapi`, `tmview` | a library jar and an executable jar |
| `third_party/` | `libini`, `libminijson`, `loadgen` | vendored sources gm compiles; vendor Makefiles behind `.import.mk` |

End-to-end smoke: `./do_build.sh`.
