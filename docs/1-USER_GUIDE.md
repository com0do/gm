# gm — User Guide

How to *use* gm.  For how gm *works* internally (and why), read
[`AGENTS.md`](../AGENTS.md) instead — that one is the design map.

- [1. Quickstart (5 minutes)](#1-quickstart-5-minutes)
- [2. Core model](#2-core-model)
    - [2.4 Naming discipline (globally-unique `.mk` basenames)](#24-naming-discipline-globally-unique-mk-basenames)
- [3. Adding a target](#3-adding-a-target)
    - [3.10 Vendored / prebuilt artefacts (`.import.mk`)](#310-vendored--prebuilt-artefacts-importmk)
    - [3.11 Compile flags — strict defaults and how to relax them](#311-compile-flags--strict-defaults-and-how-to-relax-them)
    - [3.12 Sanitizers and coverage (`SANITIZE=`, `COVERAGE=1`)](#312-sanitizers-and-coverage-sanitize-coverage1)
    - [3.13 Debuginfo, and diagnosing a field crash](#313-debuginfo-and-diagnosing-a-field-crash)
    - [3.14 Optimization, hardening and link flags](#314-optimization-hardening-and-link-flags)
    - [3.15 Reproducible builds](#315-reproducible-builds)
    - [3.16 Field debugging: `gm core`, `gm watch`, `gm symbols`](#316-field-debugging-gm-core-gm-watch-gm-symbols)
- [4. Everyday commands](#4-everyday-commands)
- [5. Dependency queries & incremental builds](#5-dependency-queries--incremental-builds)
- [6. Container images](#6-container-images)
- [7. Shipping a sub-project on its own (vendoring)](#7-shipping-a-sub-project-on-its-own-vendoring)
- [8. Integrating gm into another build system](#8-integrating-gm-into-another-build-system)
- [9. Before you push: `make precheck`](#9-before-you-push-make-precheck)
- [10. Troubleshooting](#10-troubleshooting)

---

## 1. Quickstart (5 minutes)

```bash
git clone <repo> && cd gm
make                 # build every discovered target
make test            # build + run every test-*
./build/exec/rhlinux/debug/t3
```

Add your own library — **one file, no registration anywhere**:

```bash
mkdir -p mylib/src mylib/include

cat > mylib/libmylib.mk <<'EOF'
CXXSOURCE += mylib.cxx
EOF

cat > mylib/src/mylib.cxx <<'EOF'
int mylib_answer() { return 42; }
EOF

make libmylib        # -> build/lib/rhlinux/debug/libmylib.so
```

That's the whole contract: **the `.mk` filename is the target name**,
its directory is the source root, and gm figures out the rest.

---

## 2. Core model

### 2.1 Targets come from filenames

Drop `<name>.mk` anywhere under the repo (except `build/`,
`production/`, `container/`, `.git/`, `note/`) and it becomes a
target.  The filename decides both the target's *name* and its
*type*:

| `.mk` filename    | sibling files      | type | artifact                              |
|-------------------|--------------------|------|---------------------------------------|
| `test-foo.mk`     |                    | test | `build/exec/<arch>/<mode>/test-foo`   |
| `libfoo.mk`       |                    | lib  | `build/lib/<arch>/<mode>/libfoo.so`   |
| any              | `go.mod` present   | go   | `build/exec/<arch>/<mode>/<name>`     |
| any              | `*.java` present   | java | `build/java/<name>.jar`               |
| `pkg-foo.mk`      |                    | pkg  | `build/pkg/<arch>/<mode>/pkg-foo-*.rpm` |
| anything else     |                    | exe  | `build/exec/<arch>/<mode>/<name>`     |

**The artifact is always named after the `.mk` file.**  There is no
rename knob — to rename, `git mv libfoo.mk libbar.mk`.  (gm keys five
separate contracts on that name; see AGENTS.md §4.)

### 2.2 The output tree

Everything lands under `$(GM_OUT)`, default `build/`:

```
build/
├── lib/<arch>/<mode>/        libfoo.so, libbar.a
├── exec/<arch>/<mode>/       binaries: exe, go, test
├── pkg/<arch>/<mode>/        *.rpm
├── java/                     *.jar
├── gen/include/<arch>/       generated headers
├── coverage/                 gcovr / lcov reports
├── depend.mk                 auto-derived build-order graph
└── <relpath>/<arch>/<mode>/  per-target intermediates (.o, .d, .dep.json)
```

Relocate the whole tree with one variable:

```bash
make GM_OUT=/tmp/scratch libfoo      # everything under /tmp/scratch/
```

### 2.3 Build order is derived, not declared

You never write "libt2 must build before t3".  gm reads `LDLIBS` in
each `.mk`, cross-references the in-tree target list, and writes
`build/depend.mk`:

```make
t3: libt1 libt2 pkg-p2-header
test-t2: libt2 libgtest libgtest_main pkg-p2-header
```

This regenerates automatically whenever any `.mk` changes.  You only
run `make deps` by hand after a **rename or delete** (the auto path
sees changed files, not vanished ones).

### 2.4 Naming discipline (globally-unique `.mk` basenames)

gm requires every `.mk` file's basename to be **unique across the
whole tree**.  Two `libutil.mk` files anywhere is a hard `$(error)`
at parse time:

```
gm: libutil must be unique.
```

`grep -rn` or `find . -name libutil.mk` locates the two colliding
paths; rename one (`git mv component1/libutil.mk component1/component1_util.mk`).

**Why the constraint** — 5 downstream contracts (`-l<name>` link
resolution, `depend.mk` edges, `pkg_of.mk` keys, `IMPORT_OF_*` map,
`dep_query` identity) all key off this one name.  Allowing duplicates
means either (a) same-name libs that link by `-L` order — a bug
waiting to happen — or (b) same-name binaries that confuse the user.

**Naming conventions that avoid collisions:**

| you want                        | do this                                    |
|---------------------------------|--------------------------------------------|
| internal helper of one component | `<component>_util.mk` → `-lcomponent_util` |
| namespaced product family        | `libacme_core.mk`, `libacme_ipc.mk`         |
| version-carrying artefact        | `libfoo_v2.mk` alongside `libfoo.mk`        |
| shared code across components    | one `libutil.mk` in a shared dir            |

Full rationale + comparison with CMake / Bazel / Meson / Cargo /
Maven: see [`2-NAMING.md`](2-NAMING.md).

---

## 3. Adding a target

### 3.1 C/C++ library

```make
# mylib/libmylib.mk
CXXSOURCE += mylib.cxx           # sources; mylib/src/ is auto-vpath'd
CCFLAGS   += -DSOME_DEFINE       # mylib/include/ is auto -I'd
LDLIBS    += -lz                 # system libs pass through
LIB_KIND  := static              # optional: .a instead of the default .so
```

Conventions gm auto-wires (you don't declare these):

- `mylib/src/` → added to `vpath` for `.c` / `.cxx`
- `mylib/include/` → added to `-I`
- `mylib/**/*.h.in` → substituted into `build/.../\*.h` (see §3.6)

### 3.2 Executable

```make
# tools/myapp.mk
CXXSOURCE += main.cxx
LDLIBS    += -lmylib             # in-tree; gm chains the build order
```

### 3.3 Unit test (gtest)

Put it in a `test/` subdirectory next to the library:

```make
# mylib/test/test-mylib.mk
CXXSOURCE += test_mylib.cxx
LDLIBS    += -lmylib
```

gm auto-adds `-lgtest -lgtest_main -lpthread`, the vendored gtest
headers, and `-I../include` (the library-under-test's public headers).
Then:

```bash
make test                       # build + run everything
make test TESTS='test-mylib'    # just this one
make test-list                  # what tests exist
make -jN -Otarget test          # parallel, grouped output
```

### 3.4 Go

```make
# svc/mysvc.mk
GO_PROJ_ROOT   := $(MAKEFILE_DIR)     # where go.mod lives (this is the default)
GO_PROJ_SUBPKG := cmd/server          # optional
GO_BUILD_FLAGS += -trimpath
```

Requires a sibling `go.mod` — that's what makes gm classify it as go.

### 3.5 Java

```make
# j2/j2.mk
JAR_DEPS       := j1                          # in-tree jar dependency
JAVA_SRC_ROOTS += $(PROJ_TOP)/j1              # so depjava.py can resolve j1's imports
MAIN_CLASS     := com.example.j2.App          # optional: makes the jar executable
JAVAC_FLAGS    += -Xlint:all
```

Zero-config also works — a plain library jar needs no knobs at all.

### 3.6 Generated headers (`*.h.in`)

Any `*.h.in` under a target's directory becomes a `.h` in
`$(BUILD_DIR)`, with `@VAR@` placeholders substituted:

```c
/* mylib/include/buildinfo.h.in */
#define MYLIB_VERSION "@PROJECT_VERSION@"
#define MYLIB_BUILT   "@BUILD_DATE@"
```

```make
# mylib/libmylib.mk
HEADER_GEN_VARS += PROJECT_VERSION
PROJECT_VERSION := 1.0.0
```

`TARGET BUILD_MODE BUILD_ARCH BUILD_DATE BUILD_HOST` are always
available without declaring them.

### 3.7 RPM package

Two modes.  **Plain** — you write the `.spec`:

```make
# p1/pkg-p1.mk
PKG_VERSION     := 1.0.0
PKG_RELEASE     := 1
PKG_FILES       := myapp libmylib      # in-tree targets to bundle
PKG_EXTRA_FILES := config/my.conf      # non-build files
PKG_SPEC        := p1.spec
PKG_RPM_DEPS    := some-runtime-rpm
```

**YAML-driven** — one small `pkg.yaml` beside the `.mk`, validated
against `production/make/schemas/pkg.schema.yaml`:

```make
# p2/pkg-p2.mk
PKG_VERSION := 1.0
PKG_YAML    := deployment/pkg.yaml
```

```yaml
# p2/deployment/pkg.yaml
# yaml-language-server: $schema=../../../production/make/schemas/pkg.schema.yaml

pkg:         pkg-p2
description: sample product
rpm_deps:    [pkg-p1]

component:
  name:      example/p2
  comp_type: application

files:
  - {src: $GM_EXEC_DIR/myapp,          filegroup: Binaries64}
  - {src: $GM_LIB_DIR/libmylib.so,     filegroup: Impl_Libraries64}
  - {src: $PROJ_TOP/p2/config/my.conf, filegroup: Config_OS}

alarms:      []      # optional; see example/p2/deployment/pkg.yaml
```

Everything the schema has a `default:` for can be omitted — a minimal
pkg.yaml is just `pkg: <name>` and a `files:` list.  `install_root`
defaults to `/opt/gm`, `pkg_type` to `full_product`, `license` / `group` to
`Proprietary` / `Networking`, the filegroup name → install-dir map covers the
common Linux service layout, etc.
`# yaml-language-server: $schema=...` gives you autocomplete +
inline validation in every editor with a YAML LSP.

YAML mode gives you two extras for free:

- **Auto build-order**: any `files[].src` under `$GM_LIB_DIR` or
  `$GM_EXEC_DIR` is detected and chained in `depend.mk` — you don't
  repeat it in `PKG_FILES`.
- **Version macros**: a `component.h` is generated per pkg, and every
  bundled lib/exe auto-inherits it (see §3.8).

### 3.8 Package version macros in your code

If your lib is bundled into a YAML-mode pkg, gm automatically wires
that pkg's `component.h` into your compile — **you write nothing**:

```c
#include <pkg-p2/component.h>

const char *v = P2_PKG_VERSION;     // "1.0"
int   major   = P2_MAJOR_VERSION;   // 1
```

Macros are prefixed per pkg (`P2_`, derived from the pkg name's last
segment).  A lib bundled by two pkgs sees both (`P1_*` and `P2_*`)
with no collision.

Every artifact also carries a recoverable versionstamp:

```bash
strings build/lib/rhlinux/debug/libt2.so | grep GM_VERSIONSTAMP:
# GM_VERSIONSTAMP: target=libt2 built=... host=... pkg=pkg-p2 ver=1.0 (1)
```

### 3.9 IDE integration -- `compile_commands.json`

Every `make` refreshes `build/compile_commands.json` (an array of
`{directory, command, file, output}` entries for every C/C++
translation unit).  A symlink `compile_commands.json` at the project
root points at it, so clangd / VS Code C++ / CLion / Zed / vim's YCM
find it without extra config.

Coverage: every TU that goes through `target.c.mk` -- product code,
`test-*` binaries, auto-generated versionstamp + alarm `.cxx`,
vendored gtest -- appears in the DB.  Go and Java targets don't (CDB
is a C/C++ convention).

Incremental builds only refresh the fragments they recompiled; the
aggregator re-runs at the end of every `make` regardless, so the DB
stays fresh whether you built everything or just one lib.


### 3.10 Vendored / prebuilt artefacts (`.import.mk`)

Some libraries / tools ship with **their own** build system (Makefile,
CMake, `configure`, whatever).  Rewriting or unpicking that build is
brittle; gm treats those vendors as **black boxes** and just imports
their finished `.so` / `.a` / executable.

Filename convention: `<name>.import.mk` (note the `.import`
intermediate).  Classification: `lib*.import.mk` becomes `import-lib`
(staged into `$(GM_LIB_DIR)`); anything else becomes `import-exe`
(staged into `$(GM_EXEC_DIR)`).  Neither compile nor link machinery
is involved -- gm just symlinks the vendor's product into place.

Minimal `.import.mk` (see `third_party/vlib/libvlib.import.mk`):

```makefile
# libvlib.import.mk
VENDOR          := $(CURDIR)/vendor
IMPORT_ARTIFACT := $(VENDOR)/build/libvlib.so \
                   $(VENDOR)/build/libvlib_extra.so \
                   $(VENDOR)/build/vtool2

.PHONY: _vendor_build
_vendor_build:
	@$(MAKE) -qC $(VENDOR) 2>/dev/null && exit 0 ; \
	 $(ECHO) "  VENDOR  $(TARGET) (via $(notdir $(VENDOR))/Makefile)" ; \
	 $(MAKE) -sC $(VENDOR)

$(IMPORT_ARTIFACT): _vendor_build
```

- **`IMPORT_ARTIFACT`** is a list of absolute paths to vendor's
  outputs.  One `.import.mk` can declare **any mix** of libs and
  execs; each artefact is routed by **its own suffix**:
  * `.so` / `.a`         → `$(GM_LIB_DIR)`
  * anything else        → `$(GM_EXEC_DIR)`

  The `.mk`'s filename (`lib*.import.mk` vs `*.import.mk`)
  classifies the *phony* into `import-lib` / `import-exe` for
  DRY_RUN ordering and `run-<name>` availability, but has **no
  bearing on where individual artefacts land**.
- **`_vendor_build`** is a phony that runs vendor's own build.
  `make -q` first so gm stays silent when nothing changed there.
  Vendor is a **BLACK BOX** -- do NOT enumerate its sources with
  `find`, that second-guesses vendor's own dep logic (missed
  generated files, transitive includes, etc.).

#### Multi-artefact reverse lookup

When a `pkg.yaml` references an artefact whose basename **doesn't
match** any `.mk` file (e.g. `libvlib_extra.so` from a `libvlib.import.mk`
that produces both), gm needs to know which `.mk` owns the artefact
so the DAG edge (`pkg-p3: libvlib`) resolves to the right target.

Reverse lookup lives in `build/import_of.mk` (auto-generated during
DRY_RUN):

```makefile
IMPORT_OF_libvlib       := libvlib
IMPORT_OF_libvlib_extra := libvlib
IMPORT_OF_vtool         := vtool
```

`target.pkg.mk` reads this during its DRY_RUN parse: any artefact
name in `pkg.yaml files` that isn't a direct `TARGET_ALL` member gets
its `IMPORT_OF_<name>` looked up.  Unresolved leftovers are a hard
`$(error)` -- silently dropping them would break DAG connectivity
and vendor updates wouldn't propagate to dependent packages.

#### Working example (in this repo)

`third_party/vlib/` demonstrates the full flow, including
mixed-type multi-artefact:

- vendor's `Makefile` produces `libvlib.so`, `libvlib_extra.so`
  (both shared libs), AND `vtool2` (an executable).
- `libvlib.import.mk` lists all three in `IMPORT_ARTIFACT`.
- gm routes them per-suffix:
  * `libvlib.so` / `libvlib_extra.so` → `$(GM_LIB_DIR)`
  * `vtool2` → `$(GM_EXEC_DIR)`
- `example/p3/pkg-p3.yaml` references `$GM_LIB_DIR/libvlib_extra.so`
  directly.  The DAG walks: `libvlib_extra` → (via
  `IMPORT_OF_libvlib_extra := libvlib` in `build/import_of.mk`)
  → `libvlib`, so `depend.mk` records `pkg-p3: libt2 libvlib`.
- Editing anything under `third_party/vlib/vendor/src/` propagates:
  vendor rebuilds → the affected symlink refreshes → `pkg-p3.rpm`
  rebuilds because it lists the artefact symlinks as file-level
  prereqs.

### 3.11 Compile flags — strict defaults and how to relax them

gm compiles with a strict warning set by default so that regressions in
code quality get caught at the compile line rather than during review.
The full defaults (see [`flags.mk`](../production/make/flags.mk)):

| flag group | contents |
|------------|----------|
| **C warnings** (`STRICT_C_WARNINGS`)      | `-Wall -Wextra -Wpedantic -Wshadow -Wcast-align -Wformat=2 -Wimplicit-fallthrough -Wnull-dereference` |
| **C++ warnings** (`STRICT_CXX_WARNINGS`)  | C set + `-Wnon-virtual-dtor -Woverloaded-virtual` |
| **`-Werror`**                             | on (any warning fails the build) |
| **`-std=`**                               | `c++17` (bump per-target with `CXX_STD := c++20`) |
| **debug**  (`BUILD_MODE=debug`, default)  | `-g -DDEBUG -O0` (C and C++) |
| **release** (`BUILD_MODE=release`)        | `-g -O2` (C and C++); symbols ship in `-debuginfo` RPMs (§3.13) |
| **hardening** (`HARDEN=yes`, default)     | stack protector, FORTIFY (release), PIE, relro/now (§3.14) |
| **sanitizers** (`SANITIZE=...`, opt-in)   | `-fsanitize=<list> -fno-omit-frame-pointer` on top of any mode (§3.12) |
| **coverage** (`COVERAGE=1`, opt-in)       | `--coverage -O0` on top of any mode (§3.12) |

Test targets (`test-*`) get an automatic loosening in
[`target.c.mk`](../production/make/target.c.mk):
`-Werror` is dropped and `-Wno-unused-variable -Wno-unused-parameter`
added, because gtest fixtures leak these constantly.

There are three ways to relax, ordered from broadest to narrowest.

#### (a) Whole project — `WARN_LEVEL=<name>`

```bash
make WARN_LEVEL=warn                 # keep the strict set, drop -Werror
make WARN_LEVEL=lax                  # just -Wall
```

Persistent by setting in your top-level Makefile before `include env.mk`.

#### (b) One target — remove specific flags in the child `.mk`

Because the sub-make loads `env.mk` (which loads `flags.mk`) BEFORE your
`.mk`, the accumulated `CFLAGS` / `CCFLAGS` / `LDFLAGS` are already
populated when your file parses.  `filter-out` and friends work
naturally:

```make
# libnoisy/libnoisy.mk -- legacy tree, allow warnings for now
CXXSOURCE += legacy.cxx
CCFLAGS   := $(filter-out -Werror -Wshadow,$(CCFLAGS))
CCFLAGS   += -Wno-unused-parameter -Wno-cast-align
```

This is the pattern `target.c.mk`'s test branch uses for gtest fixtures.
Load order comment lives in
[`target.common.mk`](../production/make/target.common.mk) if you want
to see the mechanism.

#### (c) One target — add extra flags

```make
# mylib/libmylib.mk
CCFLAGS += -Wold-style-cast -Wsuggest-override
LDFLAGS += -Wl,--no-undefined
```

Additive.  Common for tightening a specific lib past the project default.

#### When to use which

| situation | approach |
|-----------|----------|
| adopting a legacy tree that isn't clean yet | `WARN_LEVEL=warn` project-wide, tighten per file over time |
| one vendored / third-party lib is noisy    | (b) filter-out in that one `.mk` |
| a critical lib wants extra tight checks    | (c) add flags in that `.mk` |
| language bump for one target               | `CXX_STD := c++20` before its `CXXSOURCE +=` |

### 3.12 Sanitizers and coverage (`SANITIZE=`, `COVERAGE=1`)

Instrumentation is its own axis, **orthogonal to `BUILD_MODE`** (like a CMake
preset on top of `CMAKE_BUILD_TYPE`); `SANITIZE` and `COVERAGE` combine with
any mode and with each other.  Off by default; opt in per invocation:

```bash
make SANITIZE=address                          # ASan on the default (debug) mode
make BUILD_MODE=release SANITIZE=address test  # what ships, under ASan
make BUILD_MODE=release SANITIZE=address,undefined pkg-p1
make SANITIZE=thread                           # TSan (cannot be combined with address)
```

`SANITIZE` is a comma-separated set of `address` (ASan: heap / stack / global
overflow, use-after-free / use-after-scope, double free, leaks), `undefined`
(UBSan) and `thread` (TSan).  Every `BUILD_MODE` composes with it.

What it does:

- **Separate artefact tree** -- `build/{lib,exec,pkg}/rhlinux/<mode>-<tags>/`
  (`release-asan`, `release-asan-ubsan`, `debug-cov`, ...), so instrumented and
  plain objects never mix.  The tags are sorted, so `undefined,address` and
  `address,undefined` are the same directory.
- **Flags** -- `-fsanitize=<list> -fno-omit-frame-pointer` at compile *and*
  link time (`SANITIZE_FLAGS` overrides the whole string; the frame pointer
  keeps stack traces cheap and complete).  Instrumentation makes GCC's
  `-Wmaybe-uninitialized` raise false positives (gcc 11 on gtest's
  `int dummy = 0;`), so that one warning is shown but not fatal in sanitizer
  builds; the strict default builds still enforce it on the same sources.
- **Go** -- cgo gets the same flags, plus `go build -asan` for `address`
  (Go's ASan interop; also checks Go memory handed to C).  `address` and
  `undefined` are exercised; TSan with Go targets is not.
- **RPMs** -- carry `Requires:` for the runtime (`libasan` / `libubsan` /
  `libtsan`) and a release tag (`1.asan`, `1.asan.ubsan`).  Generated specs
  set `AutoReqProv: no` (gm RPMs never record system-library deps), so the
  sanitizer runtime has to be listed explicitly.  The tagged release sorts
  *older* than `1`: a normal upgrade replaces a sanitizer build, while
  moving a machine onto one needs `rpm -U --oldpackage` -- deliberate.
- **Self-test** -- `test-asan` (`example/asan/`) triggers deliberate
  overflow / use-after-free and expects ASan's report; without
  `SANITIZE=address` it *skips* rather than passing vacuously.

**Coverage** is the same kind of axis: `COVERAGE=1` adds `--coverage` and forces
`-O0` (optimization distorts line / branch attribution), building into
`<mode>-cov/`.  `make coverage` (gcovr) and `make coverage-lcov` rebuild with
`COVERAGE=1`, run every executable, then the unit tests (a failing test fails
the target), then aggregate into `build/coverage/`.  `BUILD_MODE=coverage` no
longer exists; the error points here.

Running a sanitizer build:

```bash
dnf install libasan                 # runtime (the RPM requires it)
ASAN_OPTIONS=log_path=/var/log/myprod/asan:detect_leaks=1:strict_string_checks=1 \
    /opt/myprod/bin/myprod
```

Reports go to `log_path.<pid>` (stderr if unset); the process exits non-zero
on the first error.  For a field site where deploying a sanitizer build is
impractical see §3.13.

How ASan works, and what it costs:

- The compiler puts a check before every load / store: each 8 bytes of
  program memory map to one *shadow byte* (`shadow = (addr >> 3) + offset`);
  `00` = all 8 bytes addressable, `01..07` = only the first *k*, anything
  else = poisoned, with a code for why (heap redzone, freed, stack redzone,
  ...).  A report prints that shadow map around the bad address.
- The runtime replaces `malloc` / `free` / `new` / `delete`: every block gets
  poisoned redzones on both sides and freed blocks sit in a quarantine, so
  overflows and use-after-free hit poisoned bytes.  Locals and globals get
  redzones at compile time; libc's `memcpy` / `strcpy` / ... are intercepted;
  LeakSanitizer scans for unreachable blocks at exit.
- Because *every* access is checked there is no cheap partial mode:
  roughly 2x CPU and 2-3x memory on typical code, and up to ~4x CPU / ~2.5x
  memory on allocation-heavy loops (measured).  `ASAN_OPTIONS=
  quarantine_size_mb=16:malloc_context_size=3:max_redzone=16` trades some
  detection power for about half the memory.  Test / staging, not customers.

Caveats:

- A *non*-instrumented host that loads an instrumented `.so` (Java JNI,
  Python ctypes) needs the runtime preloaded, e.g.
  `LD_PRELOAD=$(ldd build/exec/rhlinux/release-asan/t3 | awk '/libasan/ {print $3}')`.
  Java targets themselves are not instrumented.
- `.import.mk` artefacts are black boxes (built by their own build system)
  and are **not** instrumented; their `malloc` / `free` are still
  intercepted, so leaks and use-after-free across the boundary are caught,
  but overflows *inside* vendor code are not.
- Needs the runtime at build time too (`dnf install libasan libubsan
  libtsan` as needed); CI's nightly matrix has a `release` + `address` lane.
- `make clean` cleans only the selected variant's directory; `make
  distclean` removes all of them.

### 3.13 Debuginfo, and diagnosing a field crash

**Every package ships its symbols.**  All modes compile with `-g` (release
too; DWARF doesn't change codegen) and link with an explicit `--build-id`.
`target.pkg.mk` then splits each ELF's symbols into a sibling
`<pkg>-debuginfo-<ver>-<rel>.<arch>.rpm`, published next to the package:

```
build/pkg/rhlinux/release/pkg-p1-1.0.0-1.el8.x86_64.rpm            (stripped)
build/pkg/rhlinux/release/pkg-p1-debuginfo-1.0.0-1.el8.x86_64.rpm  (symbols)
```

The pair is matched by **build-id** (`/usr/lib/debug/.build-id/xx/yyyy.debug`),
so a release shipped weeks ago can be symbolized at any time: keep the
debuginfo RPM of each release next to its package (CI uploads
`build/pkg/**`; give release builds a long retention).  Packages with no ELF
payload simply have no debuginfo.  Hand-written (plain-mode) specs get the
same treatment unless they already mention `debug_package` (then they own it).

How it is wired (`pkg-debuginfo.spec.inc`, shared by the generated and the
plain-mode spec): rpmbuild's own `%debug_package` does the split.  Notes for
whoever touches it: no `-debugsource` (gm's sources live outside rpmbuild's
BUILD dir, which would leave an empty sub-package and fail the build); no gdb
index (it needs gdb at build time); a binary without a build-id only warns
(imported vendor artefacts); the split is skipped (plain package, no debuginfo RPM) on a host
without elfutils' `eu-strip`, e.g. an Ubuntu runner whose `find-debuginfo` would otherwise
fail the build; payload files are made writable in `%install`
(`%attr` still sets the packaged modes) because strip / objcopy cannot touch
a 0555 file; percent-brace macros must not appear in spec comments (rpm
expands them).

Symbolizing a crash:

```bash
rpm -ivh pkg-p1-debuginfo-1.0.0-1.el8.x86_64.rpm       # on the analysis host
gdb /opt/gm/bin/t3 core                                # finds symbols by build-id
(gdb) bt full
```

Sources are referenced by their absolute build paths; check out the release's
commit and `set substitute-path` if you build elsewhere.  Java jars are not
ELF and are not covered.

**Reading the core.**  The crash site is usually the *victim*, not the code
that broke the heap: glibc aborts in `free()` (`double free or corruption`,
`malloc(): corrupted top size`, ...) long after the bad write.  A stale
pointer into freed memory typically looks like a small bogus address.

**When you cannot deploy a sanitizer build** (big OpenShift estate, embedded
hardware) -- no rebuild is needed for these, only environment variables on
the suspect process:

| setting | effect |
|---------|--------|
| `MALLOC_CHECK_=3` | glibc aborts at the first detected heap-metadata damage (still the victim, not the culprit) |
| `GLIBC_TUNABLES=glibc.malloc.tcache_count=0` + `MALLOC_PERTURB_=165` | freed objects get a recognizable fill (`0xa5a5a5a5` in fields after the allocator's first 8 bytes) |
| `LD_PRELOAD=libtcmalloc_debug.so.4` (gperftools) | debug allocator: double free reported at the second `free`; heap overruns reported at `free` ("memory stomping bug: a word after object ... has been corrupted"); freed memory filled with `0xcd` so dead objects are recognizable in the core |
| `... TCMALLOC_PAGE_FENCE=1` | every allocation ends at a guard page: an overflow faults **on the offending instruction** (core points at the culprit line).  Costs a mapping per allocation: allocation-heavy workloads hit `vm.max_map_count` ("Guard page setup failed: ENOMEM"), so use it on one suspect process |
| `... TCMALLOC_PAGE_FENCE_NEVER_RECLAIM=1` | freed pages stay inaccessible: a use-after-free faults at the access |

The tcmalloc debug allocator is *not* cheap in CPU terms (tens of times slower
on allocation-heavy loops, comparable to or worse than ASan); its point is that
it needs no rebuild and no new binary.  Combined with the matching debuginfo
RPM, the resulting core names the offending line.  Best of all is to reproduce
the trigger locally (same input / request sequence) under `SANITIZE=address`
-- memory bugs rarely depend on where the process runs.

### 3.14 Optimization, hardening and link flags

- **Optimization**: debug is `-O0`, release `-O2`, for C and C++ alike
  (`COVERAGE=1` forces `-O0`).
- **`HARDEN`** (default `yes`; `HARDEN=no` for legacy or embedded toolchains):
  `-fstack-protector-strong` (a smashed stack aborts with a message instead of
  corrupting silently), `-D_FORTIFY_SOURCE=2` in release only (glibc needs
  optimization for it; `-O0` would warn), PIE executables and `-z relro -z now`.
- **RPATH**: executables (and cgo binaries) get an `$ORIGIN`-relative RPATH to
  the in-tree libraries, so the build tree is relocatable and no absolute build
  path ships.  Inside a package that path means nothing, so `elf-rpath.py`
  rewrites it in place to the libraries shipped in the same RPM
  (`$ORIGIN/../lib` for `/opt/gm/bin` + `/opt/gm/lib`).  An exe whose libraries
  come from another RPM needs the usual ld.so configuration.
- **`-z defs`** on shared libraries: an undefined symbol fails the link, not the
  load.  `LIB_ZDEFS := no` in a lib's `.mk` allows them (plugins resolved by the
  host); sanitizer builds skip it (the runtime provides symbols at load time).
- **Incremental correctness**: header dependencies carry `-MP`, so deleting or
  renaming a header no longer wedges the build; a static archive is rebuilt from
  scratch, so a source removed from `CSOURCE` / `CXXSOURCE` leaves no stale
  member.

### 3.15 Reproducible builds

`SOURCE_DATE_EPOCH` defaults to the last commit time (override it in the
environment) and is exported.  gcc (`__DATE__`), the generated headers'
`BUILD_DATE`, `ar` (deterministic mode), jars (`jar-normalize.py` fixes entry
mtimes and order), `rpmbuild` (payload mtimes, build time) and the generated
spec's changelog all follow it: on one host the same sources give identical
libraries, executables, jars and RPMs, including the `-debuginfo` ones (checked
on Rocky 8 / rpm 4.14 and Rocky 9 / rpm 4.16; `BuildHost` still differs across
hosts).  rpm needs two nudges that are wired in `target.pkg.mk`:
`use_source_date_epoch_as_buildtime` (rpm >= 4.15 otherwise stamps the clock)
and a `%__strip` wrapper (`strip-deterministic`), because `brp-strip-static-archive`
otherwise rewrites static-archive member times with the current time.

- **Go**: `GO_DEFAULT_FLAGS ?= -buildvcs=false -trimpath` -- no VCS stamp, no
  build paths in the binary (DWARF paths become module-relative: use
  `set substitute-path` in gdb).
- **Java**: `JAVA_RELEASE ?= 8` (`-source` / `-target`, so the class level does not
  depend on which JDK built it) and `-encoding UTF-8`.
- **RPM**: `license:` and `group:` in pkg.yaml (default `Proprietary` /
  `Networking`).

### 3.16 Field debugging: `gm core`, `gm watch`, `gm symbols`

For crashes you cannot reproduce under a sanitizer.  All three are one
stdlib-only Python file (`production/tools/gmdbg.py`, copyable to any jump
host) driving **gdb with Python support** (`dnf install gdb`); Linux only.

| situation | tool |
|-----------|------|
| you have a core file | `gm core <core>` |
| the core shows only addresses (no line numbers) | `gm symbols add <debuginfo rpm>` once, then `gm core` again |
| the same memory is corrupted again and again, process is live | `gm watch` |
| a field is overwritten but no user-space store touches it | `gm watch --kernel` |
| unknown victim, heap damage | `libtcmalloc_debug` (§3.13), else `SANITIZE=address` locally |

**`gm symbols`** -- a root-free debuginfo store for the analysis host.

```bash
gm symbols add pkg-p1-debuginfo-1.0.0-1.el8.x86_64.rpm   # also: a directory, or an unstripped ELF / .debug file
gm symbols find /opt/gm/bin/t3                           # build-id, and whether symbols are known
gm symbols list
```

It keeps the files in `${XDG_CACHE_HOME:-~/.cache}/gm/debug` in the standard
`.build-id/xx/yyyy.debug` layout (needs `rpm2cpio` + `cpio` for RPMs).  `gm core`
and `gm watch` look there, then in `/usr/lib/debug`; `--symdir DIR` (repeatable)
adds more, `--sysroot DIR` points at a copy of the target's shared libraries.

**`gm core <core> [--exe E] [--threads] [--full] [-n N]`** -- one report: the
signal and `si_code`, fault address, the backtrace, the faulting instruction with
the register that held the bad value, the first frame that has source (with the
line), a thread overview, and the modules whose symbols are missing.  The
executable is taken from the core's header when `--exe` is omitted.  It names
the usual suspects instead of leaving you to decode raw values:

| seen | reported as |
|------|-------------|
| fault address below 64 KiB | NULL pointer dereference, with the field offset |
| bad pointer made of printable bytes | a char buffer overran into the pointer (the text is shown) |
| `0xcdcd...` / `0xa5a5...` fill | use after free (tcmalloc_debug / `MALLOC_PERTURB_`) |
| fault next to `sp` | stack overflow (depth shown) |
| SIGSEGV with `si_code` `SI_KERNEL` | general-protection fault: non-canonical pointer, `movaps` misalignment |
| jump to an unmapped `pc` | corrupted function pointer / vtable / return address |
| abort in `malloc_printerr` / `__stack_chk_fail` / `*_chk` / `__assert_fail` / `terminate` | heap corruption (bad write was earlier) / stack smashing / fortify overflow / assertion / uncaught exception |
| crash inside malloc / free | heap metadata damaged earlier |
| `div` with a zero divisor register | integer divide by zero |

The classification is pattern matching, not proof: it points where to look next.

**`gm watch`** -- *who* writes this memory?  A hardware watchpoint (x86 debug
registers, at most 4 x 8 bytes) runs the target at native speed and stops it
only when the watched value changes; each hit prints old -> new value, thread
and a backtrace, then the target continues.

```bash
# watch what a singleton's first member points at (address of the pointer var, then follow it)
gm watch --pid 4321 --sym _ZN21FrwInitialSignalTable9_instanceE --deref
gm watch --name HLR_CALLP --wait 60 --repeat --sym ... --deref -n 0   # wait for the process, re-attach after restarts
gm watch --pid 4321 --expr 'g_table->head' --if 'g_table->head == 0'      # needs debug info; --if is a gdb expression
gm watch --pid 4321 --addr 0x7f12a4001230 --len 16 --timeout 600
gm watch --sym g_state --at init_done -- ./svc --config x                  # launch under gdb instead of attaching
```

| option | meaning |
|--------|---------|
| `--sym S` / `--addr A` / `--expr E` | what to watch: a symbol's address (mangled or demangled; an exported dynamic symbol is enough), an absolute address, or a gdb lvalue (needs debug info; resolved once) |
| `--deref` / `--off N` | the symbol / address holds a pointer: watch what it points to (+ offset) |
| `--len N` | 1, 2, 4, 8, or a multiple of 8 up to 32 (default 8, or `sizeof` for `--expr`) |
| `--if EXPR` | report only when this gdb expression is true (filters legitimate writers) |
| `--kernel` | also report `read` / `pread64` / `readv` / `recvfrom` / `recvmsg` / `epoll_wait` / `getdents64` / `getrandom` / `readlink` returns that stored into the range (x86-64) |
| `-n N` | detach after N hits (default 10; 0 = unlimited); `--timeout SEC` likewise; `--bt N` frames per hit |
| `--pid P` / `--name RE` (+ `--wait`, `--repeat`) | attach; `--name` matches the full command line and must be unique |
| `-- CMD ARGS` (+ `--at LOC`) | launch under gdb; arm at `LOC` (default `main`) |

Things to know:

- **Attached, never killed.**  Ctrl-C, `--timeout` and `-n` detach and the
  process keeps running; a fatal signal (SIGSEGV, SIGABRT, ...) is reported with
  its stack and then delivered, so the process dies and dumps core as usual.
- **Hardware only.**  gdb silently falls back to a software watchpoint (about a
  million times slower) when it cannot use a debug register; gm refuses instead.
  Some VMs and emulators expose no debug registers: the run ends with that message.
- **Read the stop point correctly.**  The report is made just *after* the
  storing instruction, so frame #0 is the writer or the line after it; a write
  of an identical value is not a change and is not reported.
- **`--kernel` is expensive.**  It stops the target twice per matching syscall;
  use it for a bounded window (`-n 1 --timeout 60`), after the plain watch found nothing.
  Only syscalls that fill a user buffer are covered.
- **Permissions.**  Attaching needs ptrace rights: the process owner with
  `kernel.yama.ptrace_scope=0`, or root / `CAP_SYS_PTRACE`.  Launch mode always works.
- **gdb's Python.**  If gdb's embedded Python cannot start under your environment (a
  venv / pyenv / CI `LD_LIBRARY_PATH` or `PYTHONHOME` pointing at another libpython),
  gm retries without `LD_LIBRARY_PATH`, `PYTHONHOME` and `PYTHONPATH` and gives them back
  to a launched target; if gdb is still unusable it stops with exit code 3 and gdb's message.
- **Scope.**  Writes by *other* processes (shared memory) and by DMA are
  invisible; multithreaded targets are covered (all threads, including new ones).

---

## 4. Everyday commands

| command                                | what it does                                    |
|----------------------------------------|-------------------------------------------------|
| `make`                                 | build everything + refresh `compile_commands.json` |
| `make V=1` / `VV=1`                    | show raw compile commands (`V=1`) / plus make's own trace (`VV=1`) |
| `make WARN_LEVEL=warn` / `lax`         | drop `-Werror` (`warn`) or drop the whole strict warning set (`lax`); default is `strict` |
| `make deps LDLIB_CHECK=1`              | opt-in scan for LDLIBS `-l<X>` typos (in-tree, system libs, and this .mk's `-L` paths); off by default |
| `make <target>`                        | build one target                                |
| `make run-<name>`                      | build + execute `<name>` (any exe / test / go target).  Args: `RUN_ARGS='...'` |
| `make <target> SUB_TARGET=clean`       | clean that target's output                      |
| `make clean`                           | clean every target                              |
| `make distclean`                       | wipe `$(GM_OUT)` entirely                       |
| `make deps`                            | force-regenerate `depend.mk` (after rename/delete) |
| `make list-targets`                    | what gm discovered                              |
| `make test` / `test-list`              | see §3.3                                        |
| `make coverage`                        | gcovr HTML + JSON + text                        |
| `make coverage-lcov`                   | lcov + genhtml alternative                      |
| `make precheck`                        | every local static check (see §9)               |

Useful variables:

| variable       | values                     | effect                                 |
|----------------|----------------------------|----------------------------------------|
| `BUILD_MODE`   | `debug` (default) / `release` | flag group in `flags.mk` |
| `SANITIZE`     | empty (default) / `address` / `undefined` / `thread`, comma-separated | sanitizer set, orthogonal to `BUILD_MODE` (§3.12) |
| `SANITIZE_FLAGS` | `-fsanitize=<set> -fno-omit-frame-pointer` | override the sanitizer flag string (compile + link) |
| `COVERAGE`     | empty (default) / `1` | gcov instrumentation, orthogonal to `BUILD_MODE` (§3.12) |
| `HARDEN`       | `yes` (default) / `no` | stack protector, FORTIFY (release), PIE, relro/now (§3.14) |
| `SOURCE_DATE_EPOCH` | last commit time | timestamp for reproducible builds (§3.15) |
| `CC` / `CXX`   | a path, or a name on `PATH` | C / C++ compiler; default: first `gcc` / `g++` on `PATH` (README "Toolchain") |
| `BUILD_ARCH`   | `rhlinux` (default)        | arch subdirectory                       |
| `GM_OUT`       | any path                   | relocate the whole output tree           |
| `DEP_TREE`     | `yes`                      | emit `.dep.json` sidecars while building |
| `-jN`          |                            | parallel; gm is parallel-safe            |

Invalid values fail at parse time with an actionable message — e.g.
`BUILD_MODE=fuzz` prints the valid set and tells you to extend
`GM_VALID_MODES` if you want your own.

---

## 5. Dependency queries & incremental builds

First populate the file-level graph (once, or after big changes):

```bash
make DEP_TREE=yes all
```

Then ask questions:

```bash
# What breaks if I touch this file?
make changes CHANGES="mylib/src/mylib.cxx"
# {"changed":[...], "images":[], "pkgs":["pkg-p1"], "exes":["myapp"], "libs":["libmylib"]}

# Same, sourced from git
make changes-since SINCE=HEAD~5

# Rebuild only what's affected, and refresh the graph
make refresh SINCE=HEAD~5
make refresh CHANGES="mylib/src/mylib.cxx"
make refresh SINCE=HEAD~5 DRY_RUN=1     # show the plan, build nothing

# Inspect the graph
make deps-files                          # human-readable dump of every tier

DQ="python3 production/make/scripts/dep_query.py"
$DQ show --format json                   # the whole graph as JSON
$DQ changes --format files <path>...     # affected artifacts, one per line
```

### 5.1 Clean, project-relative dep cache (`make deps-snap`)

Raw `.dep.json` files under `build/**/` contain absolute paths (they
have to, for local make's mtime comparisons to work).  For anything
that wants *portable* dep data — CI cache, change-impact tooling in a
different checkout, `git`-check-in-able snapshots — run:

```bash
DEP_TREE=yes make          # emit raw .dep.json under build/**/
make deps-snap             # aggregate + rewrite paths to project-relative
```

The output lives at `build/deps/{lib,exec,pkg,java}/<target>.dep.json`,
one file per artefact, everything under `$(PROJ_TOP)` rewritten to a
repo-relative path (paths outside are dropped, so the cache stays
purely internal).  Same schema as the raw files (`{file, deps}` for
lib/exec/java, `{pkg, deps, rpms}` for pkg).

Example (`build/deps/exec/vuser.dep.json` — a white-box exe linking a
black-box vendor lib):

```json
{
  "file": "build/exec/rhlinux/debug/vuser",
  "deps": [
    "Makefile",
    "build/lib/rhlinux/debug/libvlib.so",
    "production/make/env.mk",
    "production/make/target.c.mk",
    "third_party/vlib/src/vuser_main.cxx",
    "third_party/vlib/vendor/include/vlib.h",
    "third_party/vlib/vuser.mk"
  ]
}
```

Deterministic + host-independent, safe to commit or ship as a CI
artefact.  Re-runs are idempotent (the output tree is truncated
first).

Two inverse queries exist but are **image-rooted** — they take a
container image name, not a lib/pkg name, and only return anything
after `container/imageBuild.py` has emitted that image's `.dep.json`:

```bash
$DQ sources <image-name>       # every file this image transitively needs
$DQ rpms    <image-name>       # the rpms[] tuples baked into it
```

**Framework changes count too.**  Touching `production/make/flags.mk`
correctly reports every downstream target — the framework files are
recorded in each `.dep.json`.

---

## 6. Container images

Container images are built by a **separate tool** (`container/`), not
by `make`.  It emits `.dep.json` in gm's schema, so `dep_query` walks
a single graph from your source files all the way to images.

```bash
container/imageBuild.py build   container/examples/hello/image.yaml
container/imageBuild.py render  <manifest>      # print the Dockerfile, no build
container/imageBuild.py deps    <manifest>      # stage + emit dep.json, no docker
container/imageBuild.py lock    <manifest>      # per-image rpm versionlock
container/imageBuild.py check-rpm-update        # poll upstream for newer RPMs
```

See [`container/README.md`](../container/README.md) for the manifest
reference.

`make refresh` **lists** affected images but doesn't rebuild them —
run `imageBuild.py` yourself.

---

## 7. Shipping a sub-project on its own (vendoring)

A sub-project can be built completely independently by vendoring gm
into it.  Two paths steer everything:

- `PROJ_TOP` — where your source lives
- `ADMIN_DIR` — where the framework lives (default `$(PROJ_TOP)/production`)

Because they're decoupled, `production/` can be a `git subtree`, a
submodule, or just a copy.

### 7.1 Layout

```
myproject/
├── Makefile              # ~15 lines, see below
├── production/           # vendored gm (git subtree / submodule / copy)
│   ├── make/
│   └── tools/
├── mylib/
│   ├── libmylib.mk
│   └── src/mylib.cxx
└── build/                # output tree (gitignore this)
```

### 7.2 Vendor it in

```bash
cd myproject
git subtree add --prefix=production https://<gm-repo> main --squash
# updates later:
git subtree pull --prefix=production https://<gm-repo> main --squash
```

Or as a submodule if you prefer pinned SHAs:

```bash
git submodule add https://<gm-repo> production
```

### 7.3 The Makefile

```make
.DEFAULT_GOAL := all

include $(CURDIR)/production/make/env.mk
include $(CURDIR)/production/make/project.mk
include $(CURDIR)/production/make/incremental.mk
include $(CURDIR)/production/make/coverage.mk
include $(CURDIR)/production/make/test.mk

ifneq ($(DRY_RUN),1)
-include $(TARGET_DEP)
endif

.PHONY: all clean distclean
all:   $(TARGET_ALL)
clean: SUB_TARGET := clean
clean: $(TARGET_ALL)
distclean:
	@$(RM) -r $(GM_OUT)

TARGET_RULES_FOR = $(strip \
    $(if $(filter exe lib test,$(1)),$(ADMIN_DIR)/make/target.c.mk,\
    $(if $(filter go,$(1)),          $(ADMIN_DIR)/make/target.go.mk,\
    $(if $(filter java,$(1)),        $(ADMIN_DIR)/make/target.java.mk,\
    $(if $(filter pkg,$(1)),         $(ADMIN_DIR)/make/target.pkg.mk,\
    $(error No recipe file for target type "$(1)"))))))

$(TARGET_ALL):
	@$(MAKE) -C $(SOURCE_DIR) -f $@.mk -f $(call TARGET_RULES_FOR,$(TYPE)) \
	    BUILD_DIR='$(BUILD_DIR)' OUT_DIR='$(OUT_DIR)' SOURCE_DIR='$(SOURCE_DIR)' \
	    REL_DIR='$(REL_DIR)' TYPE='$(TYPE)' $(SUB_TARGET)
```

Copy `gm/Makefile` and delete the parts you don't need (the
`pkg-<name>-header` block only matters if you use XML-mode pkgs).

### 7.4 Verify

```bash
make list-targets      # should list your .mk files
make                   # builds into ./build/
```

Everything works: dependency derivation, `.dep.json`, `make refresh`,
tests, coverage.  The only thing you inherit from gm's repo is
`production/` — your source tree stays yours.

### 7.5 What you *don't* need to do

You do **not** need `make -f libmylib.mk` to work — it never does, by
design.  A user `.mk` is a pure declaration; the rules live in
`target.<type>.mk` and the dispatcher composes them.  If what you
actually wanted was one of these, there's a better answer:

| you want                           | do this                                   |
|------------------------------------|-------------------------------------------|
| less typing from a sub-directory   | `make -C $(PROJ_TOP) libmylib`            |
| artifacts next to your source      | `make libmylib GM_OUT=$PWD/out`           |
| ship the sub-project alone         | vendor gm (this section)                  |

---

## 8. Integrating gm into another build system

gm works fine as a component of a larger build.  Nothing special is
required:

```make
# someone else's Makefile
.PHONY: all
all: third_party/gm-built

third_party/gm-built:
	$(MAKE) -C third_party/gm all
```

Or with an explicit output location so gm's artifacts land where your
outer system expects them:

```make
	$(MAKE) -C third_party/gm all GM_OUT=$(CURDIR)/out/gm
```

**Why this works**: gm exports `GM_TREE=1` to its children as a
nesting marker.  A non-gm outer make doesn't set it, so gm's
top-level check sees "empty" and treats the invocation as a fresh
entry.

**gm-inside-gm is not supported.**  If your outer project *also*
builds with gm and a gm recipe there tries to `$(MAKE) -C` a second,
unrelated gm tree, the inner tree errors out at parse time:

```
Makefile:*** GM_TREE='1' was set outside gm.  Either you set it on
the command line (it is gm-internal, do not) or another gm's recipe
invoked this tree (not supported -- the two trees' tree-scoped exports
would collide).  Call this tree from a non-gm context: a shell rule,
a CI step, or `GM_TREE= make -C ...`.
```

Reason: a gm recipe exports a dozen tree-scoped variables (`PROJ_TOP`,
`ADMIN_DIR`, `GM_OUT`, every `GM_*_DIR`, ...), and the inner tree's
`?=` defaults cannot override an inherited environment value, so it
would silently build into the outer's output directory.  Scrubbing
every possible tree-scoped variable at every entry would make the
scrub list itself load-bearing (a new `GM_*` variable added later
would need to remember to join it); refusing the whole scenario is
cheaper and honest.

To integrate two gm trees, either call the inner one from a
non-gm context, or clear `GM_TREE` at the spawn site so the inner
tree sees "empty" and treats itself as a fresh entry:

```make
# in outer's Makefile: prefix the spawn with GM_TREE= to clear the
# nesting-marker inherited from outer's env.mk
build-third-party:
	GM_TREE= $(MAKE) -C third_party/gm all
```

```yaml
# CI: two independent steps -- no inherited env
- run: make -C third_party/gm all
- run: make libt1 pkg-p2
```

Note that the inner tree still adopts whatever `PROJ_TOP` /
`ADMIN_DIR` / `GM_OUT` the outer tree exported unless you also
override them on the inner spawn.  For fully independent builds,
run the inner tree from an environment that doesn't contain gm's
exports at all -- a CI step or a shell wrapper is the cleanest
answer.

A **single** gm tree under a *non-gm* outer make system is fine and
supported: the outer make doesn't set `GM_TREE`, so the inner is
recognised as the entry point automatically.

---

## 9. Before you push: `make precheck`

One command runs every static check that CI runs:

```bash
make precheck              # every check
make precheck FAST=1       # skip mypy + actionlint download
make precheck FIX=1        # apply safe auto-fixes (ruff)

production/tools/precheck.sh --list          # what checks exist
production/tools/precheck.sh --only ruff     # run just one
```

Checks: YAML syntax, Python AST parse, ruff, mypy, shellcheck,
actionlint, jq syntax, the gm smoke / nesting / idempotence / compile-database
tests, the build-variant and compiler-selection tests, and a gdb-based test of
`gm core` / `gm watch` / `gm symbols` (skipped without gdb).

**Rule**: any check CI runs must also be runnable here.  If CI catches
a class of problem `precheck` misses, that's a bug in `precheck.sh` —
add a `check_<name>` function and register it in `ALL_CHECKS`.

---

## 10. Troubleshooting

### `No rule to make target '-lfoo'`

`LDLIBS += -lfoo` names a library gm can't find.  Either:

- it's an in-tree target but the name doesn't match any `.mk` file
  (remember: `libfoo.mk` → `-lfoo`), or
- it's a system library and its `-L` path isn't in `LDFLAGS`.

### `No rule to make target 'libfoo'`

The `.mk` file's basename doesn't match what you asked for.  Check
`make list-targets`.

### `gm: duplicate .mk basenames -- every target name must be globally unique.`

Two `.mk` files share the same basename anywhere in the tree.  The
error lists every colliding path.  Rename one — see
[§2.4 Naming discipline](#24-naming-discipline-globally-unique-mk-basenames)
for why and for suggested naming patterns.

### `AR_NAME / LIB_NAME / BIN_NAME is removed`

Those rename knobs are gone.  For static/shared selection use
`LIB_KIND := static|shared`.  To rename, rename the file — the error
message includes the exact `git mv` command.

### `Cannot mix lib and pkg targets in one make invocation`

`make libfoo pkg-bar` is refused because the two sit at different DAG
tiers and the ordering is ambiguous.  Run them as two commands.

### Build order is wrong / a dependency didn't build

`depend.mk` is stale.  It auto-regenerates on `.mk` changes but cannot
see *deleted* or *renamed* targets:

```bash
make deps       # full refresh
```

### `make changes` reports nothing

The `.dep.json` sidecars don't exist yet:

```bash
make DEP_TREE=yes all
```

### `BUILD_MODE='xyz' is not in {debug release}`

Working as intended.  To add your own mode, set it *before* including
`env.mk` in your top-level Makefile:

```make
GM_VALID_MODES += fuzz
include $(CURDIR)/production/make/env.mk
```

...then add the matching `C_FLAGS_FUZZ` / `CC_FLAGS_FUZZ` /
`LD_FLAGS_FUZZ` groups in `flags.mk`.

### Something in `production/` changed and nothing rebuilt

It should.  Framework files are recorded as prerequisites of every
object and in every `.dep.json`.  If a specific file isn't triggering
rebuilds, check whether it's in `GM_FRAMEWORK_CORE_MK` (`env.mk`) —
dispatch-only files (`incremental.mk`, `coverage.mk`, `test.mk`) are
deliberately excluded because they can't change artifact bytes.
