
# gm — auto-dependence-deduced build framework

Zero-configuration, raw-GNU-make build system for polyglot repos.  Drop a
`<name>.mk` file next to your source; gm classifies it, builds it, and
folds it into a whole-tree dep graph — no central registry, no DSL, no
subdir bookkeeping.

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

- C/C++, Go, Java, RPM in one tree — classified by filename convention
- Auto lib-level build-order derivation (`depend.mk`, parallel-safe via
  per-target fragments — `-jN deps` needs no coordination)
- File-level DAG (`.dep.json`) for `make changes ... / refresh SINCE=...`
- Framework files themselves tracked in every `.dep.json` — touch
  `flags.mk`, downstream targets rebuild
- **Compile / link flag change detection** — CFLAGS / CCFLAGS / LDFLAGS /
  ARFLAGS are hashed into stamp files; changing any flag rebuilds only
  the affected objects, without a `make clean`
- Header generation (`*.h.in`), gtest test targets, gcovr / lcov coverage
- YAML-driven RPM packages (schema-validated, auto-generated spec,
  per-pkg `component.h` + versionstamp macros wired into consumers)
- Vendored / prebuilt artefacts via `.import.mk` (multi-artefact
  supported — one file can declare a mix of `.so` / `.a` / exe)
- `compile_commands.json` auto-refreshed on every `make` (clangd /
  VS Code / vim / Zed pick it up with no extra config)
- `make precheck` runs every CI static check locally with one command


## Requirements

- **GNU make ≥ 4.3**, bash, coreutils
- **gcc/g++** (Rocky 8 ships 8.5; use `gcc-toolset-N` for newer C++ —
  see [Toolchain](#toolchain))
- **Python ≥ 3.12** (enforced by `production/ruff/ruff.toml`,
  `production/mypy/mypy.ini`, and CI)
- Optional, per language: `rpmbuild` (pkg targets), `javac`/`jar`
  (java), `go` (go), `gcovr` or `lcov` (coverage).  Absent tools
  disable only the targets that need them; the rest still builds.

### System packages for the `example/` targets

The complete set gm's own `example/` tree exercises (C/C++, Go, Java,
RPM, coverage):

```bash
# Debian / Ubuntu
sudo apt install -y --no-install-recommends \
    build-essential ccache jq rpm shellcheck git \
    python3 python3-pip python3-yaml \
    golang-go default-jdk-headless \
    lcov gcovr

# Rocky / RHEL / Fedora
sudo dnf install -y --setopt=install_weak_deps=False \
    gcc gcc-c++ make binutils ccache jq shellcheck git \
    python3 python3-pip python3-pyyaml \
    rpm-build rpmdevtools \
    golang java-11-openjdk-devel
# coverage (RHEL): gcovr via pip, lcov + perl deps via dnf --enablerepo=powertools
python3 -m pip install --user gcovr
sudo dnf install -y --enablerepo=powertools \
    lcov perl-DateTime perl-JSON perl-App-cpanminus
```

This matches CI's provisioning
([`.github/actions/setup-gm-env/action.yml`](.github/actions/setup-gm-env/action.yml));
that action stays the ground truth.

### Python packages

Pinned in [`production/requirements.txt`](production/requirements.txt) —
`PyYAML` + `jsonschema` (required for pkg YAML mode) plus optional
`gcovr` / `diff-cover` / `ruff` / `mypy`.

```bash
python3 -m venv .venv && source .venv/bin/activate   # optional but recommended
make prereq                                          # one-shot pip install
```

`make prereq` picks `--user` outside a venv, no `--user` inside; it is
idempotent.  If Python deps are missing, `pkg-build.py` refuses to run
with an actionable install hint tailored to your Python.


## Quickstart

```bash
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
| `make list-targets`                  | what gm discovered                               |
| `make DEP_TREE=yes`                  | build + emit `.dep.json` sidecars                |
| `make changes CHANGES="a.cc b.h"`    | which targets do these files affect?             |
| `make refresh SINCE=<git-ref>`       | rebuild only what git-diff changed since         |
| `make deps-snap`                     | project-relative dep cache under `build/deps/`   |
| `make coverage`                      | gcovr HTML + JSON + txt summary                  |
| `make -jN test`                      | parallel build + parallel run of every `test-*`  |
| `make precheck`                      | every local static check (CI parity)             |
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
    1. `.import.mk` suffix → `import-lib` (if the file's basename starts
       with `lib`) or `import-exe`
    2. filename starts with `test-` → test
    3. filename starts with `lib`   → lib
    4. a sibling `go.mod` exists    → go
    5. a sibling `*.java` file exists → java
    6. filename starts with `pkg-`  → pkg
    7. otherwise                    → exe

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
├── example/                  # user source (t1, t2, t3, g1, j1, j2, p1, p2)
├── third_party/              # black-box vendor imports (.import.mk demos)
├── container/                # sibling image-build tool (NOT gm)
└── build/                    # $(GM_OUT), gitignored
```

Two paths steer the whole build:

- `PROJ_TOP` — repo root (where user source lives)
- `ADMIN_DIR` — `$(PROJ_TOP)/production` (where the framework lives)

They are decoupled so `production/` can be a `git subtree`, submodule,
or shared checkout without touching any user `.mk`.  Vendoring
recipe is [USER_GUIDE §7](docs/1-USER_GUIDE.md#7-shipping-a-sub-project-on-its-own-vendoring).


## Toolchain

Default: whatever the system's `/usr/bin/gcc` points at.  Four knobs
swap it without touching any `.mk`:

| var       | default                                                                 | purpose                |
|-----------|-------------------------------------------------------------------------|------------------------|
| `C_PATH`  | `$(ADMIN_DIR)/tools/rhlinux/gcc/bin/gcc` if present, else `/usr/bin/gcc`| C compiler             |
| `CC_PATH` | same idea, `g++`                                                        | C++ compiler           |
| `LD_PATH` | same idea, `g++`                                                        | linker driver          |
| `CXX_STD` | `c++17`                                                                 | C++ language standard  |

### Newer gcc on Rocky 8 (gcc-toolset)

Rocky 8's stock gcc 8.5 has partial C++17 and no C++20.  Install
`gcc-toolset-13` (a good 2026 baseline), then either source its
enable script:

```bash
source /opt/rh/gcc-toolset-13/enable   # updates PATH + LD_LIBRARY_PATH
make -jN
```

or point the paths at it directly (better for CI):

```bash
make -jN CXX_STD=c++20 \
     C_PATH=/opt/rh/gcc-toolset-13/root/usr/bin/gcc \
     CC_PATH=/opt/rh/gcc-toolset-13/root/usr/bin/g++ \
     LD_PATH=/opt/rh/gcc-toolset-13/root/usr/bin/g++
```

### ccache

Enabled automatically when a `ccache` binary is on `PATH` — cuts a
cold rebuild of `example/` from ~20 s to ~1 s.

| var             | default | meaning                                        |
|-----------------|---------|------------------------------------------------|
| `CCACHE_ENABLE` | `auto`  | `auto` = use if present, silently skip if not; `yes`/`1` insists; `no`/`0` disables |
| `CCACHE_PATH`   | auto    | absolute path; unset → search `$(ADMIN_DIR)/tools/ccache-*/ccache` then `$PATH` |


## Examples

| dir              | type | what it shows                                                           |
|------------------|------|-------------------------------------------------------------------------|
| `example/t1`     | lib  | static + shared library; `.h.in` header generation                      |
| `example/t1/test`| test | gtest suite (deliberately shows a `-Wunused-variable` warning in-terminal) |
| `example/t2`     | lib  | shared library consumed by t3 and pkg-p2                                |
| `example/t3`     | exe  | binary linking both libs                                                |
| `example/g1`     | go   | go binary using `GO_PROJ_ROOT` / `GO_PROJ_SUBPKG`                       |
| `example/j1,j2`  | java | jar targets (`JAR_DEPS`, `MAIN_CLASS`, imports resolved via depjava.py) |
| `example/p1`     | pkg  | rpm with hand-written `.spec` (mode A: hook-based dep capture)          |
| `example/p2`     | pkg  | rpm from `deployment/pkg.yaml` (mode B: YAML-driven, auto-generated spec) |
| `third_party/vlib` | import | black-box vendor build with multi-artefact `.import.mk` (so + a + exe) |

End-to-end smoke: `./do_build.sh`.
