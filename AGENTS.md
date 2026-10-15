# gm — AGENTS.md

Instructions and design orientation for AI coding assistants (and humans)
working on the `gm` build system.  This file is deliberately dense —
each section is what the code would need in comments if it didn't have
this file to point at.  Prefer reading this once end-to-end; then use
it as the map, and only chase into the .mk / .py / .sh files for
implementation-level detail.

**Never guess at the design.**  If a claim here contradicts the code,
the code is the truth — but before "fixing" the code, ask whether
this doc's claim was intentional and the code drifted.

---

## 1. What gm is

`gm` is a **zero-configuration, raw-GNU-make build framework** for a
polyglot repo:

- **C / C++**   → static libs (`.a`), shared libs (`.so`), executables
- **Go**        → main-package binaries (via `go build`)
- **Java**      → jars (via `javac` + `jar`, plain projects only —
                  no maven/gradle integration)
- **RPM**       → `rpmbuild` in two modes:
                  plain hand-written `.spec`, OR YAML-driven (pkg.yaml
                  validated against pkg.schema.yaml, .spec auto-generated)

Container images live in a **standalone sibling tool** (`container/`),
not in gm's dispatch — see §11.

**"Zero-configuration" means**: users drop a single `<name>.mk` file
in a directory that holds source, and gm classifies + builds it based
on filename convention + sibling files.  No central registry, no
`SUBDIRS`, no per-target boilerplate.

**Non-goals**: gm is not trying to become bazel/cmake/meson.  It stays
"raw GNU-make + a Python dep-graph walker" on purpose.  Every user
`.mk` is just a make file — users get the full power of make (and
its footguns).

**The wider product stack** (four independent systems, gm is #1):

```
1. gm         → *.rpm + *.dep.json                     (this repo)
2. container/ → container image                        (sibling; consumes rpms)
3. gm_helm    → helm chart / pod composition           (separate repo)
4. runtime    → cmproxy + generic.xml + YANG schemas   (in-cluster; not built)
```

Everything about **runtime configuration** — YANG schemas driving
`generic.xml`, per-container `cmproxy` templates, live reconfig, etc.
— lives at layers 3–4.  gm's job stops at the rpm boundary; YANG
modules a pkg ships are just opaque files staged into the rpm like
any other config asset.  See `docs/5-CM_DESIGN.md` for the full
boundary + how YANG modules pass through gm.

**Toolchain floor**: Linux + GNU make 3.82+ + Python 3.12+ + gcc/g++ +
rpmbuild.  The Python helpers use PEP 604 unions, PEP 585 built-in
generics, and PEP 695 `type` statements throughout — 3.11 or earlier
will syntax-error at parse time.

Python deps: `PyYAML` and `jsonschema` are hard requirements.  There
is no XML input path and no lxml dependency; pkg specs are authored
in YAML and validated against a JSON Schema.

**Pkg config: schema-first YAML.**  `production/make/schemas/pkg.schema.yaml`
is the single source of truth for what a valid pkg looks like.
Install root, filegroup → {dir,mode,owner,group} map, pkg_type enum,
alarm severity enum, version defaults — all live in the schema, not
in Python code.  Users author `pkg.yaml` files that carry a
`# yaml-language-server: $schema=...` directive so VS Code / IntelliJ
/ vim YAML LSP give inline autocomplete + validation while typing.
The compiler is `production/make/scripts/pkg-build.py` (loads the
schema, applies defaults, emits `manifest.json` + generated `.spec`
+ optional `alarms.h/.cxx` + optional `component.h`).  A minimal
pkg.yaml is just `pkg: <name>` + a `files:` list — every other field
falls back to a schema default.

---

## 2. Two properties that shape every design decision

### 2.1 Fail-fast, before anything derives from a bad input

The top of `env.mk` is a strict funnel:

1. Tool paths + `MAKEFLAGS` defence (`--no-builtin-rules`,
   `--no-builtin-variables`)
2. `BUILD_MODE ?= debug`, `BUILD_ARCH` derivation
3. **Legality guards** — SUB_TARGET / BUILD_MODE whitelist, `SANITIZE`
   set validation, `lib*` + `pkg*` goal-mixing refusal, `o=` alias.
   Any invalid input `$(error)`s here.
4. Only AFTER (3) does env.mk derive `GM_MODE_DIR` and from it
   `GM_LIB_DIR`, `GM_EXEC_DIR`, `GM_PKG_DIR`, ... from the validated
   `BUILD_MODE` / `SANITIZE`.

An earlier revision had a separate `check.mk` after env.mk;
that was a bug — a bad `BUILD_MODE` would silently interpolate into
every derived path before validation caught it, and the error trace
pointed at a random `check.mk` line instead of at the actual bad
cmdline input.  **Never re-split legality out of env.mk.**  The
coupling (validate the value, then use it) is local by design.

### 2.2 Everything routes through the dep-graph

Two orthogonal but coordinated mechanisms:

- **`depend.mk`** (see §7) — link-time / target-level deps
  auto-derived by dry-run sub-makes.  Answers "what targets does
  target X need built first?"
- **`.dep.json` + `dep_query.py`** (see §8) — file-level DAG.
  Answers "if source `a.cxx` changes, which images / rpms / exes /
  libs need rebuilding?"

Both are auto-refreshed by `make deps` / `make refresh`.  Neither
requires the user to hand-write deps for typical targets — the
dry-run derivation figures them out from `LDLIBS`, PKG_FILES,
XML `<File>` elements, etc.

---

## 3. Repo layout

```
gm/
├── Makefile                      # top-level entry (only orchestration)
├── AGENTS.md                     # (this file)
├── README.md                     # user-facing overview
├── do_build.sh                   # smoke build for CI + humans
│
├── example/                      # the example product tm (example/README.md maps it)
│   ├── core/  stats/            #   libtmcore (static C), libtmstats (shared C++), tests under test/
│   ├── daemon/                   #   tmd (exe), alarms/ (generated lib), deploy/ (pkg-tmd, YAML)
│   ├── cli/  tmtools/           #   tmctl (C exe), pkg-tm-tools (plain-mode .spec)
│   ├── sdk/                      #   pkg-tm-devel (YAML, custom filegroups)
│   ├── exporter/  cgo/          #   go: tmexport, tmcrc (cgo on libtmcore)
│   ├── dashboard/                #   java: tmapi (library jar), tmview (depends on tmapi)
│   └── selftest/                 #   test-asan
├── third_party/                  # libini (gm-compiled), libminijson + loadgen (.import.mk)
│
├── production/                   # THE FRAMEWORK — never scanned as
│   │                            # user targets (EXCLUDE_DIR).
│   ├── make/
│   │   ├── env.mk                # tools + defaults + legality guards +
│   │   │                        #   GM_OUT layout + framework file list
│   │   ├── flags.mk              # CFLAGS/CCFLAGS/LDFLAGS accumulators + compiler selection (CC/CXX/PATH → GM_CC/GM_CXX/GM_LD)
│   │   ├── project.mk            # TARGET_ALL discovery, gm's goal list
│   │   ├── graph.mk              # top level: include depend.mk (goals that build), regen rule
│   │   ├── target.common.mk      # sub-make bootstrap (env.mk include etc.)
│   │   ├── target.dry-run.mk     # shared DRY_RUN=1 short-circuit
│   │   ├── target.c.mk           # C/C++ compile + link rules
│   │   ├── target.go.mk          # go build rules
│   │   ├── target.java.mk        # javac + jar rules
│   │   ├── target.pkg.mk         # rpmbuild rules (plain + XML modes)
│   │   ├── incremental.mk        # `make changes/refresh/incremental`
│   │   ├── coverage.mk           # `make coverage / coverage-lcov`
│   │   ├── test.mk               # `make test / test-list / test-<name>`
│   │   └── scripts/
│   │       ├── depcxx.sh         # resolve -lXXX -> abs .so path
│   │       ├── depgo.sh          # go list-based dep-json for go targets
│   │       ├── depjava.py        # import-parse-based dep-json for java
│   │       ├── pkg-build.py      # YAML pkg -> spec + manifest + header
│   │       │                     #   (validated against schemas/pkg.schema.yaml)
│   │       ├── pkgdeps.py        # aggregate pkg deps to dep.json
│   │       ├── make-versionstamp.sh  # per-target `strings`-recoverable
│   │       │                     #   compile-time versionstamp .cpp
│   │       ├── link_dep_json.jq  # .link.dep.json aggregator
│   │       └── dep_query.py      # image-rooted DAG walker (CLI)
│   ├── tools/
│   │   ├── pydep/                # python lib backing dep_query.py
│   │   ├── depUpdate.py          # closed-loop `make refresh` driver
│   │   ├── dep-hooks.sh          # cp/install hook -> hooks.jsonl
│   │   │                        #   (used by target.pkg.mk + container/)
│   │   ├── precheck.sh           # local static-check runner (`make precheck`)
│   │   ├── gmdbg.py              # `gm core|watch|symbols` (python CLI + gdb-side script)
│   │   └── gtest-1.14.0/         # vendored gtest as a gm-managed lib
│   ├── ruff/ruff.toml            # ruff config (not pyproject.toml — gm
│   │                            #   isn't a Python package)
│   └── mypy/mypy.ini             # mypy config
│
├── container/                    # standalone container-image build tool.
│                                # emits dep.json in gm's schema so
│                                # dep_query.py can walk gm ↔ image
│                                # edges — but not part of gm's make
│                                # dispatch.  see container/README.md
│                                # and §11.
│
├── build/                        # output tree (gitignored).  see §5.
├── backup/                       # historic reference designs (out of tree)
└── docs/                         # design notes (todo lists, deep dives)
```

**Rule of thumb**: only `production/make/`, `production/tools/`, the
top-level `Makefile`, and `container/` are framework surface.
Everything under `example/` is user-code demo — treat it as a
customer's project.

---

## 4. Target types and classification

Filename convention + sibling-file existence drive classification.  See
`_CLASSIFY` in `production/make/project.mk`.  First match wins:

| Signal                                         | TYPE  | Recipe file           | Artifact         |
|------------------------------------------------|-------|-----------------------|------------------|
| `.java.mk` suffix (`tmapi.java.mk` -> `tmapi`) | java  | target.java.mk        | `.jar`           |
| `.import.mk` suffix                            | import-lib / import-exe | target.import.mk | vendor artefacts |
| basename starts with `test-`                   | test  | target.c.mk           | binary + gtest   |
| basename starts with `lib`                     | lib   | target.c.mk           | `.so` or `.a`    |
| sibling `go.mod` present                       | go    | target.go.mk          | binary           |
| basename starts with `pkg-`                    | pkg   | target.pkg.mk         | `.rpm`           |
| else                                           | exe   | target.c.mk           | binary           |

**Deliberately does NOT peek inside the .mk file's content.**  An
earlier version grepped for `AR_NAME` / `go build` / `javac` markers,
which meant an innocuous comment ("no AR_NAME needed here") could flip
a target's type.

### The artifact name is NOT configurable

`$(TARGET)` is always the `.mk` basename.  There is no rename knob —
`AR_NAME` / `LIB_NAME` / `BIN_NAME` were removed and now hard-`$(error)`
with a `git mv` suggestion.

Five contracts key on that one name:

1. dispatcher's sub-make goal (`$(MAKE) ... $(TARGET)`)
2. `depend.mk`'s line key (`tmctl: libtmcore`)
3. `pkg_of.mk`'s key (`PKG_OF_libtmstats := pkg-tmd pkg-tm-devel`)
4. `dep_query.py`'s target identity
5. `TARGET_ALL` — the in-tree-vs-system-lib filter that makes
   automatic `-lfoo` → `libfoo` build-**order** derivation possible

Divergence broke all five.  Observed symptoms before removal:
`make libtmcore` → "No rule to make target"; `-lrenamed` silently
vanishing from depend.mk; go's `BIN_NAME` producing a differently-
named binary that `PKG_FILES` / dep_query could never resolve
(go was the nastiest — it did *not* error, just silently diverged).

The reference system (the reference build never had this knob either: its
`LIBRARY_SHARED(LibName)` imake macro uses ONE name for the phony
goal, the `.gmk` source filename, the generated `.mk`, and the
artifact.  gm needs it even more, because gm derives build ORDER
automatically (the reference build hand-declares `DIRS` recursion instead).

The one surviving lib knob selects the *form*, not the name:

```make
LIB_KIND := shared    # lib<name>.so   (default, omittable)
LIB_KIND := static    # lib<name>.a
```

exe / test / go / java / pkg have no knob at all.

---

## 5. Output tree — GM_OUT

Every artefact lands under `$(GM_OUT)` (default `$(PROJ_TOP)/build/`),
sorted by TYPE.  Layout mirrors reg's `ims_do/` tree:

```
$(GM_OUT)/
├── lib/<arch>/<variant>/         libt*.a, libt*.so   (GM_LIB_DIR)
├── exec/<arch>/<variant>/        exe + go + test    (GM_EXEC_DIR)
├── pkg/<arch>/<variant>/         *.rpm + *-debuginfo.rpm (GM_PKG_DIR)
├── java/                          *.jar              (GM_JAVA_DIR)
├── gen/include/<arch>/            generated headers  (GM_GEN_DIR)
├── coverage/                      gcovr/lcov output  (GM_COVERAGE_DIR)
├── release/                       staged release     (GM_RELEASE_DIR)
├── depend.mk                      link-time DAG      (GM_DEP_FILE)
├── pkg_of.mk                      pkg-of reverse map (GM_PKG_OF_FILE)
└── <relpath>/<arch>/<variant>/    per-target intermediates
                                   (.o, .d, .dep.json, MANIFEST.MF, ...)
```

`<variant>` is `GM_MODE_DIR`: the `BUILD_MODE`, plus the sorted `SANITIZE` /
`COVERAGE` tags when set (`release`, `release-asan-ubsan`, `debug-cov`).

**Rule**: no gm code hard-codes `build/`.  Everything goes through
`GM_OUT` / `GM_LIB_DIR` / etc.  This lets `make GM_OUT=/tmp/x`
completely relocate the tree.  Search for `PROJ_TOP)/build/` in a PR
diff — any hit is a regression.

**Java jars are the exception**: they are written **directly to
$(GM_JAVA_DIR)** instead of built in `BUILD_DIR` and symlinked out.
The reason is JVM classloader semantics — it resolves `Class-Path:` in
a jar's manifest relative to the jar's REAL location (following
symlinks), so sibling-jar Class-Path entries only work when jars are
siblings on disk.  `.so`/`.a`/exe files don't have this problem
because ELF `rpath` is baked in at link time (does not follow
symlinks).  See target.java.mk's `JAR_OUT` block.

---

## 6. Build flow (top to leaf)

```
                       user runs `make libtmstats`
                                │
                                ▼
                    ┌───────────────────────┐
                    │ TOP-LEVEL Makefile    │
                    │   .DEFAULT_GOAL = all │
                    │   include env.mk      │──── FAIL-FAST LEGALITY
                    │   include project.mk  │──── TARGET_ALL discovery
                    │   include incr/cov/…  │
                    │   include graph.mk    │──── depend.mk, if a goal builds
                    └──────────┬────────────┘
                               │
                    ┌──────────▼────────────┐
                    │ $(TARGET_ALL) rule    │
                    │   dispatch by TYPE    │──── $(MAKE) -C <srcdir>
                    │   forwards            │       -f libtmstats.mk
                    │   BUILD_DIR/OUT_DIR/  │       -f target.c.mk
                    │   TYPE/SUB_TARGET     │       BUILD_DIR=... TYPE=lib
                    │   to the sub-make     │       $(SUB_TARGET)
                    └──────────┬────────────┘
                               │
                               ▼
              ┌─────────────────────────────────┐
              │ SUB-MAKE (per-target leaf)      │
              │   -f <user>.mk                  │──── LDLIBS, CXXSOURCE, etc.
              │   -f target.c.mk / go / java /  │──── recipe rules
              │       pkg.mk (by TYPE)          │
              │      include target.common.mk   │──── env.mk again (defensive)
              │      include target.dry-run.mk  │──── if DRY_RUN=1
              │                                 │
              │   PARSE-TIME:                   │
              │      PKG_HEADERS ?= $(PKG_OF_$(TARGET)) │
              │      $(OBJS): $(GM_FRAMEWORK_MK) │──── framework-file
              │                                 │       invalidation
              │   RECIPE-TIME:                  │
              │      compile → link → symlink   │
              │      → emit .dep.json (if       │
              │         DEP_TREE=yes)           │
              └─────────────────────────────────┘
```

**The dispatcher is 3 lines** in the top Makefile:

```make
$(TARGET_ALL):
	@$(MAKE) -C $(SOURCE_DIR) -f $@.mk -f $(call TARGET_RULES_FOR,$(TYPE)) \
	    BUILD_DIR='$(BUILD_DIR)' OUT_DIR='$(OUT_DIR)' ... $(SUB_TARGET)
```

Everything else is set-up (`env.mk`, `project.mk`, ...) or per-type
recipes (`target.*.mk`).

### 6.1 Compiler, sanitizer and debuginfo choices

- **Compiler selection** (`flags.mk`).  `CC` / `CXX` (env or cmdline), else
  `gcc` / `g++` on `PATH`, found by a pure-make scan of `PATH` (ccache shim
  dirs skipped).  `C_PATH` / `CC_PATH` / `LD_PATH` are gm-internal results, not
  knobs, and not exported: env, cmdline (via `MAKEFLAGS`) and `PATH` reach every
  sub-make, so each one resolves the same compilers.  gm's own command lines are
  `GM_CC` / `GM_CXX` / `GM_LD`: gm used to assign `CC` / `C` / `LD` itself
  (`CC` meaning "C++ with ccache"), which clobbered the standard variable
  and polluted what vendor builds (`CC ?= gcc`) and cgo inherit.  Never
  assign `CC` / `CXX` in the framework.
- **Robustness rules in the make layer.**  Target names are `.PHONY` (a same-named dir
  would otherwise make a leaf target a silent no-op).  `.DELETE_ON_ERROR` is on and `.d`
  files are written to `.tmp`, installed only when non-empty.  Values that reach a shell go
  through `$(call _sq,..)` (env.mk), never inside hand-written `'...'`: flags with quotes broke
  the flag stamps and the compile database.  compile_commands fragments are written with `jq`
  behind `GM_JQ` (one probe in env.mk): without jq there is no compile database, the build is
  unaffected.  Sub-goals listed in `SUB_TARGET_ALONE` (env.mk, today `clean`) skip the dependency
  edges, so `clean` cleans one target; a sub-goal not listed gets the full `depend.mk`.
- **Dependency graph loading (graph.mk).**  make remakes every makefile it includes before it
  looks at a goal, so an included `depend.mk` scans the tree whenever it is stale, whatever the
  goal.  graph.mk includes it in the top-level make only when a goal builds targets there; the
  goals that build none are `_GM_GOALS_ALONE` in project.mk (they read files, or start a make of
  their own).  A new gm goal goes in `_GM_GOALS_ALONE` or the other half of `_GM_GOALS` -- the
  list every goal is already in for the name-clash check -- never behind its own
  `ifneq ($(MAKECMDGOALS),...)`.  Unlisted goals (targets, `run-<t>`, a project's own) get the
  graph: correct by default.  The top level never reads `pkg_of.mk` / `import_of.mk`: only
  target sub-makes do (env.mk `-include`s them there, read only, before the target's .mk), so
  nothing but `depend.mk` drives the scan.  Check 17 leg P: `make help/list/prereq/clean` on an
  empty tree start no scan.  A scan never records a graph it could not compute: a YAML pkg whose
  pkg.yaml cannot be read (no PyYAML) stops it (target.pkg.mk), and a failed scan removes
  `depend.mk` -- its sub-makes update it as they go, and a half-updated file newer than every
  `.mk` would look current (leg Q).  Likewise no `find` stops make at the probe (env.mk) instead of
  discovering an empty tree (leg R).
  Toolchain gating happens once, in project.mk, on two inputs: no `go` drops every go target,
  no `javac`/`jar` drops every java target.  They leave `TARGET_ALL` (and `TARGET_ALL_MK`)
  before `TARGET_LIB/EXE/GO/...` are derived, so no later flow filters.  The two lists
  (`_GM_NO_GO`, `_GM_NO_JAVA`) each have a virtual target (`_skip_go`, `_skip_java`) that `all`
  lists when non-empty, printing one `SKIP` line per toolchain; naming a skipped target fails
  with "not built here".  pkg targets stay (libs
  need their component.h); target.pkg.mk skips only the rpm step when rpmbuild is missing.
  There is deliberately no tree lock: one make per tree.  Check 17 in precheck pins these.
- **Inputs are declared, not searched.**  A target's inputs come from its `.mk`: sources
  (`CXXSOURCE` / `CSOURCE`), generated-header templates (`HEADER_GEN`), libs (`LDLIBS`).  `find`
  during a build would pick up files a user keeps around but does not use yet (a draft `.h.in`
  became a header nobody asked for) and costs a fork per target.  `find` is for discovering
  targets (the `*.mk` scan) and for the build's own outputs (`*.cc.json`, `*.gcda`, lib
  lookup).  Java follows the same rule: a java target is a `<name>.java.mk` and lists its
  `JAVASOURCE` (no "any `.java` below" classification, no default glob).  depjava.py's class
  index still walks `JAVA_SRC_ROOTS` (DEP_TREE only): it maps imports to the files of OTHER
  targets, whose JAVASOURCE a sub-make does not see.
- **No-op cost.**  A sub-make runs once per target per `make`, so nothing in its parse path may
  fork per target what is the same for the whole tree: host probes (`go javac jar jq ccache
  rpmbuild`, `uname -m`, hostname, the commit time) run in ONE shell in the top-level make
  (env.mk, `GM_TREE` still empty) and are exported.  Values that only change with their inputs
  go through `_CACHE` (env.mk: a makefile under BUILD_DIR / GM_OUT, rebuilt when a dependency is
  newer or its key differs, make then restarts): `go list`, the pkg.yaml in-tree list, rpm's
  `%{?dist}`.  Flag stamps (`_FLAG_STAMP`) compare at parse time with `$(file <)` and only get a
  rule when the flags changed.  Recursive (`=` / `?=`) variables holding `$(shell)` re-run it at
  every reference -- and an exported one at every recipe line: compute once with `:=`.
  Check 17 leg L fails if a no-op build starts python or rpm.
- **Introspection.**  `make show` (table from project.mk's variables + depend.mk, no sub-make),
  `make show-<type>` / `show-<name>` (adds the type's facts: each target's sub-make runs the
  `_gm_show` goal of target.common.mk, which prints `GM_SHOW_FIELDS` / `SHOW_<field>` set at the
  end of every target.<type>.mk -- a new type sets its own).  `show-<t>` depends on `_info-<t>`,
  whose recipe runs `<t>`'s sub-make with the goal `_gm_show` into `$(GM_OUT)/.show/<t>`.  Every
  sub-make (dispatch, `<pkg>-header`, `_info-<t>`) is `$(call _GM_SUBMAKE,<target>,<goal>)`
  (Makefile); its TYPE / SOURCE_DIR / BUILD_DIR / OUT_DIR / REL_DIR are the target-specific
  values SET_TARGET (for `<t>` and `_info-<t>`) and SET_HEADER_TARGET (for `<pkg>-header`) set.
  `make run` only lists `run-<name>` targets on purpose: exes may be servers or need arguments;
  tests are the self-checking ones (`make test`).
- **Layout.**  `SINGLE_REPO` (env.mk, default `Y`): gm is vendored, make runs in the project and
  `ADMIN_DIR=$(PROJ_TOP)/production`.  `N`: gm is a checkout next to the project repo(s), make
  runs in the gm checkout, `PROJ_TOP` is its parent and `ADMIN_DIR=$(CURDIR)/production`;
  project.mk prunes the gm checkout (`GM_SELF`) from the `*.mk` scan so gm's `example/` is not a
  target, and the gtest root comes from `ADMIN_DIR`.  The `gm` wrapper (`production/tools/gm`)
  makes both layouts usable from any directory: a marker tree above CWD wins (layout Y), else
  with `SINGLE_REPO=N` exported it uses the checkout it lives in (found through its symlink);
  it passes `SINGLE_REPO` explicitly and turns `gm changes` paths into absolute ones.  Object
  `.dep.json` sidecars store absolute paths (relative `.d` entries are resolved against the
  source dir), so a target's own sources are matched by `make changes`.  Check 17 leg J pins it.
- **Flags and reproducibility.**  flags.mk carries no product-specific flags; a project sets
  `PROJECT_CPPFLAGS / _CFLAGS / _CCFLAGS / _LDFLAGS` (and `WARN_LEVEL`, `HARDEN`, `CXX_STD`,
  `PATH_MAP`) in its top-level Makefile -- flags.mk exports them at its end (exporting earlier
  would define an unset `?=` knob as empty) and the sub-makes read the environment.  `-m64`
  depends on `GM_MACHINE` (`gcc -dumpmachine`, found once at the top level, passed down).
  `-ffile-prefix-map=<PROJ_TOP>=.` (+ `GM_OUT`, + `ADMIN_DIR` when outside) keeps the checkout
  directory out of binaries; off for coverage (gcov needs real paths).  Go adds `-ldflags=-buildid=`
  (its id hashes the cgo flags); the versionstamp's time follows SOURCE_DATE_EPOCH; `BUILD_HOST`
  feeds headers, versionstamp and rpm `_buildhost`; a `%ghost` file is created empty in the
  buildroot (a missing one makes rpm store a buildroot path).  Verified by hashing the same tree
  built under two paths and two hostnames (Rocky 8 / 9, Ubuntu 24.04) and by check 17.
- **Debug tools** (`production/tools/gmdbg.py`, dispatched by `tools/gm`).
  One file, two roles: under python it is the CLI; `gdb -x gmdbg.py` runs the
  gdb side (config in `$GMDBG_CFG`, report on a private fd so gdb's chatter
  stays out of the terminal; `_run_gdb` drains the rest and prints it only on
  failure or `-v`).  It never edits the target and never replaces gdb: `watch`
  arms `gdb.Breakpoint` hardware watchpoints and refuses a software fallback,
  `--kernel` is a `catch syscall` whose condition is a gdb convenience function
  (`$_gm_kw`) that reports from inside the condition and returns 0, so gdb keeps
  resuming.  Fatal signals are passed to the target.  Classification in
  `_classify` is plain pattern matching over (signal, frame names, instruction,
  registers); keep it a pure function.  gdb 8.2 is the floor (no
  `Inferior.architecture`).  `_find_gdb` probes gdb's Python (importing what the script
  imports) and, on failure, retries without `LD_LIBRARY_PATH` / `PYTHONHOME` / `PYTHONPATH`,
  handing them to a launched target via `set environment`.  Nothing here touches the build; `note/memwatch.*`
  is someone else's older tool and is not part of gm.
- **Instrumentation axes** (`SANITIZE`, `COVERAGE`).  Axes next to
  `BUILD_MODE`, not modes (coverage used to be one; it inherited debug's flags
  and could not be combined or placed on release):
  `env.mk` parses and validates them and derives `GM_MODE_DIR`; `flags.mk` adds
  the flags at compile and link; `target.go.mk` feeds them to cgo (+ `-asan`);
  `target.pkg.mk` tags the RPM release and adds the runtime `Requires:`.
  `component.h` is generated with the *untagged* release because
  `GM_GEN_DIR` is shared by all variants.  `coverage.mk` rebuilds with
  `COVERAGE=1`, runs the exes, then `make test`.  Guide: USER_GUIDE 3.12.
- **Link and reproducibility** (USER_GUIDE 3.14 / 3.15).  Exes get an
  `$ORIGIN`-relative RPATH (`_GM_RPATH_LIB`, target.common.mk); packaging
  repoints it with `elf-rpath.py` (spec `%install`, generated and plain mode
  alike).  `SOURCE_DATE_EPOCH` is exported by env.mk and consumed by `ar -D`,
  `jar-normalize.py`, rpmbuild (`clamp_mtime…`, `use_source_date_epoch_as_buildtime`,
  `%__strip` = `strip-deterministic`) and pkg-build.py.
- **Debuginfo** (`pkg-debuginfo.spec.inc`).  Every mode compiles with `-g`
  and links with `--build-id`; the generated spec and plain-mode specs both
  get `%debug_package`, and `target.pkg.mk` publishes the resulting
  `<pkg>-debuginfo` RPM next to the package.  Guide: USER_GUIDE 3.13.

---

## 7. Link-time DAG — depend.mk

`$(GM_OUT)/depend.mk` holds one line per target:

```
libtmstats:libtmcore pkg-tmd-header pkg-tm-devel-header
pkg-tmd:tmd libtmstats libminijson
tmd:libtmcore libtmalarms libtmstats libini libminijson pkg-tmd-header
test-tmstats:libtmstats libgtest libgtest_main
```

Each line is a plain make rule: `<target>: <its intree prereqs>`.
Included by graph.mk in the top-level make for a goal that builds
targets, so `make tmd` on a cold clone naturally builds
its libraries and `pkg-tmd-header` first.

### How it's derived: DRY_RUN sub-makes

1. `make deps` (or the auto-regen rule on any `.mk` mtime bump) sets
   `DRY_RUN := 1` as a target-specific variable.
2. It then loops every target: `for t in $(TARGET_ALL); do $(MAKE) -s $$t; done`.
3. `$(MAKE)` propagates `DRY_RUN=1` to the sub-make via env
   (see §9 for the mechanics).
4. Sub-make sees `ifeq ($(DRY_RUN),1)` → skips the real build,
   computes `DRY_DEPS`, calls target.dry-run.mk.
5. `target.dry-run.mk` runs a `sed -i` upsert on `depend.mk`:
   ```
   /^<TARGET>:/{h;s/:.*/:<DEPS>/}    # match -> rewrite
   ${x;/^$/{s//<TARGET>:<DEPS>/;H};x}  # EOF + no match -> append
   ```
6. Empty `DRY_DEPS` deletes the line entirely (target lost its deps).

**Two-phase order**:

- Phase 1 = every `pkg-*` target first.  This populates BOTH
  `depend.mk` and `pkg_of.mk` (see §8) with pkg-owned mappings.
- Phase 2 = everything else.  Now lib/exe/test sub-makes can consult
  `PKG_OF_<name>` in `pkg_of.mk` and auto-fill `PKG_HEADERS`.

**Framework-file invalidation** (see §10): if a framework `.mk` (like
`flags.mk`) is touched, `depend.mk`'s auto-regen rule is ALSO
triggered — because `$(TARGET_DEP): $(TARGET_ALL_MK)` gets extended
with `$(GM_FRAMEWORK_MK)` in project.mk.

---

## 8. File-level DAG — .dep.json + dep_query.py

Each artefact-tier target, when built with `DEP_TREE=yes`, emits:

```
$(OUT_DIR)/<target>.dep.json    # per-artefact (link-level)
$(BUILD_DIR)/<obj>.dep.json     # per-object (compile-level; C/C++ only)
```

**Schema** (universal across TYPE):

```json
{
  "file":   "/abs/path/to/artefact",
  "deps":   ["/abs/path/to/every source, header, framework file, lib, ..."],
  "rpms":   [...],           # pkg + img only
  "extra":  {...}            # optional pass-through metadata
}
```

Every dep.json also lists the **framework files** whose change should
invalidate this artefact (see §10).

### Aggregation per TYPE

| Type   | Emitter                                                      |
|--------|--------------------------------------------------------------|
| C/C++  | `link_dep_json.jq` — union of per-obj deps + `-lXXX` resolutions + framework |
| Go     | `depgo.sh` — `go list -deps` walk; a jq post-pass adds the in-tree C libraries cgo links (`LDLIBS`), the `.mk` and the framework |
| Java   | `depjava.py` — import + package-graph walker + `--intree-jar` (there's no `go list` for java, so we parse imports ourselves) |
| Pkg    | `pkgdeps.py` — hooks.jsonl (plain mode) or rpmbuild log (XML mode) + framework via `--extra-dep` |
| Image  | `container/` — see §11                                        |

**A generated file is an artefact too.**  Objects list the generated headers / sources they
compile (from `.d`), but nothing says what those were generated from -- so a walk from
`pkg.yaml` used to stop at the pkg.  The rule that generates a file therefore writes its
dep.json: `component.h.dep.json` (target.pkg.mk: pkg.yaml, the pkg's `.mk`, pkg-build.py) and
`alarms.{h,cxx}.dep.json` (_pkg_alarm.mk, registered through `_GM_GEN_DEP_JSON`).  pydep
classifies `.h` / `.c` / `.cxx` ... artefacts as `gen`: they carry edges, they are not targets.
`HEADER_GEN` templates need no file of their own: link_dep_json.jq lists the `.h.in` directly.
A new generator writes its outputs' dep.json the same way (check 17 leg S).

### The query interface: `dep_query.py`

Image-rooted DAG walker.  Every leaf dep in every dep.json is a
canonical absolute path — image-tier `deps[]` references pkg-tier
absolute `.rpm` paths; pkg-tier `deps[]` references exe/lib absolute
paths; exe/lib-tier `deps[]` references source files.  So dep_query
takes a changed leaf and walks upward, tier by tier, until it hits
the images that consume the change.

Subcommands (see `production/make/scripts/dep_query.py`):

- `changes <paths...>` — affected artefacts by tier
- `changes-since <ref>` — same, sourced from `git diff <ref>..HEAD`
- `sources <image>` — inverse: every file this image needs
- `rpms <image>` — the rpms[] tuple this image installs
- `show` — dump the loaded DAG
- `cache create/list/validate` — versioned dep.json snapshots

Backed by `production/tools/pydep/` (`DepGraph`, `ImageWalker`,
`ChangeSource`, `GitignoreFilter`, `DepCache`).

### Closed-loop workflow: `make refresh`

```
make refresh CHANGES="src/foo.cxx"
```

Runs `production/tools/depUpdate.py`, which:

1. Runs `make deps` (unless `SKIP_DEPS=1`).
2. Finds "new" targets (in `TARGET_ALL`, no dep.json yet) → builds
   them with `DEP_TREE=yes`.
3. Walks the graph from `CHANGES` (or `SINCE=<ref>`), yields
   affected libs/exes/pkgs/javas.
4. Rebuilds each phase (`libs`, then `exes`, then `pkgs`) with
   `DEP_TREE=yes`.
5. Reports any container images downstream — those live in
   container's own dispatch, not gm's.

---

## 9. Sub-make dispatch — how variables propagate

Non-obvious but critical.  Users occasionally ask "why does my
sub-make see BUILD_MODE?" or "how does DRY_RUN get across?".  Two
mechanisms coexist:

### 9.1 Explicit cmdline forwarding (dispatcher)

Every target sub-make (dispatch, `<pkg>-header`, `_info-<t>`) is one macro (top-level
`Makefile`):

```make
_GM_SUBMAKE = $(MAKE) -C $(SOURCE_DIR) -f env.mk -f $($(1)_mkfile) -f $(call TARGET_RULES_FOR,$(TYPE)) \
    $(foreach v,$(_GM_SUBMAKE_VARS) $(_GM_SUBMAKE_VARS_$(TYPE)),$(v)=$(call _sq,$($(v)))) $(2)
```

- `_GM_SUBMAKE_VARS` (env.mk) is what EVERY sub-make gets -- env.mk and flags.mk run in all of
  them: `PROJ_TOP ADMIN_DIR BUILD_ARCH BUILD_MODE SANITIZE COVERAGE GM_MACHINE C_PATH CC_PATH
  GM_OUT GM_TOP_MAKEFILES DEP_TREE TARGET_DEP TYPE SOURCE_DIR BUILD_DIR OUT_DIR REL_DIR _GM_JQ`
  (jq: DEP_TREE in every type).  `_GM_SUBMAKE_VARS_<type>` adds what one type uses: C
  (lib / exe / test) `_GM_CCACHE BUILD_HOST`, go `_GM_GO`, java `_GM_JAVAC _GM_JAR`, pkg
  `_GM_RPMBUILD _GM_UNAME_M _GM_RPM_DIST BUILD_HOST`; import none.  A C sub-make sees no go
  probe (check 17 leg L).  Everything the top level derived and the sub-makes must agree on is
  in them: the
  variant axes (a top-level `COVERAGE := 1` used to make the top level name a `-cov` build dir
  the sub-make never created), the compilers flags.mk resolved in the top-level make (`C_PATH` /
  `CC_PATH`; `GM_MACHINE` was asked from them -- a `CC` set in the top-level Makefile reaches
  every target this way).  Values go through `_sq`.
- Only short values.  A list that grows with the tree never goes on a command line (it would
  also ride in MAKEFLAGS into every child's environment): `TARGET_ALL` and `GM_SYS_LIBS`, which
  only the DRY_RUN sub-makes use, are written by project.mk to `$(GM_OUT)/.dry-run-vars.mk`
  (only when the content changes) and included by env.mk when `DRY_RUN=1` in a sub-make.
- These are passed on the sub-make's cmdline, so they get **cmdline-override**
  semantics: they beat any `:=` assignment in target.c.mk / target.go.mk / ...  And they
  reach every make the sub-make starts, in MAKEFLAGS and in the environment: target.import.mk
  removes them from both (`MAKEOVERRIDES` filter + `unexport`) so a vendor's own make does not
  get gm's `BUILD_DIR` / `TYPE` / ... imposed on its variables of the same name; it gets gm's
  compilers instead as `CC` / `CXX` in its environment (a default the vendor's own `CC :=`
  still beats).
- `$(SUB_TARGET)` is the sub-make's goal (empty = build the target;
  `clean` otherwise — see env.mk's SUB_TARGET whitelist).

### 9.2 MAKEFLAGS and the environment

- Variables given on the command line (`DRY_RUN=1`, `WARN_LEVEL=...`,
  `CC=...`) ride in `MAKEFLAGS` into every child make; that is how
  `DRY_RUN` reaches the leaf without being in `_GM_SUBMAKE_VARS`
  (docs/3-DRY_RUN.md).  A makefile assignment never beats a cmdline value.
- Two channels, chosen by what a target's `.mk` may do with the value (env.mk, above
  `_GM_SUBMAKE_VARS`).  Command line: must agree, cannot be changed by a `.mk`.  Environment
  (`export`): project defaults a `.mk` may still change -- flags.mk's `PROJECT_* WARN_LEVEL
  HARDEN CXX_STD PATH_MAP` (an assignment in the `.mk` beats the environment; `CXX_STD :=
  c++20` per target relies on that) -- and what tools other than make read: `SOURCE_DATE_EPOCH`
  (gcc, rpmbuild, jar), `GM_TREE`, `CC` / `CXX` for a vendor's make.  Nothing else is exported;
  target-specific variables never leave the top-level make.
- `GM_TREE`: the top-level Makefile reads it from the environment BEFORE env.mk's `export
  GM_TREE := 1` (an assignment beats the environment, so from then on this make and everything
  it starts see 1).  A nested `make` of a gm tree therefore finds 1 and stops; gm's own
  re-entries start with `GM_TREE= $(MAKE) ...` (empty in their environment) and pass.  On the
  command line it would beat the assignment and switch the guard off: refused.

### 9.3 Validation runs in every make instance

env.mk's legality guards (§2.1, §14) are cheap and not gated on `MAKELEVEL`:
every sub-make re-validates the values forwarded via §9.1.

---

## 10. Framework-file invalidation — GM_FRAMEWORK_MK

**The problem**: `flags.mk` adds a `-Wextra`.  User runs `make`.
Nothing rebuilds — because the obj recipe's prereqs only listed the
user's .mk plus `$(CURRENT_FILE)` (which is target.c.mk, not flags.mk).

**The fix** (implemented across env.mk + each target.*.mk):

`env.mk` defines the **core framework files**:

```make
GM_FRAMEWORK_CORE_MK = \
    $(GM_TOP_MAKEFILES)       \
    $(ADMIN_DIR)/make/env.mk  \
    $(ADMIN_DIR)/make/flags.mk \
    $(ADMIN_DIR)/make/project.mk \
    $(ADMIN_DIR)/make/target.common.mk
```

`GM_TOP_MAKEFILES` are the project's own makefiles the top-level make read: the one it was
started with (gm's `Makefile`, or the project's own one that includes env.mk) and everything
that one includes, i.e. `MAKEFILE_LIST` without gm's `make/` files and what lives under
`GM_OUT`.  Computed in the top-level make, passed down in `_GM_SUBMAKE_VARS`.

Each `target.<TYPE>.mk` extends this with its type-specific set:

```make
# target.c.mk
GM_FRAMEWORK_MK := $(GM_FRAMEWORK_CORE_MK) \
    $(CURRENT_FILE) \
    $(ADMIN_DIR)/make/scripts/depcxx.sh \
    $(ADMIN_DIR)/make/scripts/link_dep_json.jq \
    $(ADMIN_DIR)/make/scripts/make-versionstamp.sh
```

Two consumers:

1. **Make's recipe prereq** (invalidates the artefact):
   ```make
   $(BUILD_DIR)/%.o: %.cxx $(MAKEFILE) $(GM_FRAMEWORK_MK)|$(BUILD_DIR)
   ```
2. **`.link.dep.json`'s `deps[]`** (invalidates the DAG walk):
   ```make
   jq -s -f link_dep_json.jq --arg FRAMEWORK "$(GM_FRAMEWORK_MK)" ...
   ```

After this, `dep_query.py changes production/make/flags.mk` correctly
reports every downstream target.

**What's deliberately EXCLUDED from `GM_FRAMEWORK_CORE_MK`**:

- **User's `.mk` files** — per-target; already a prereq of just their
  own target.  A change to `libtmstats.mk` should invalidate libtmstats, not
  everything.
- **Dispatch-only files** — `incremental.mk` / `coverage.mk` /
  `test.mk` / `target.dry-run.mk`.  These add phonies (`refresh`,
  `coverage`, `test`) or short-circuit logic; they don't change the
  bytes of the compiled artefacts.  Excluding them avoids a "change
  one line of test.mk → the whole tree rebuilds" nuisance.
- **`container/**`** — standalone tool; gm's targets don't consume
  its files.

---

## 11. Container/ — the standalone subsystem

`container/imageBuild.py` is a Python CLI that builds docker images
from a YAML manifest.  It emits `dep.json` in the same schema as
gm's C/Go/Java/pkg targets — so `dep_query.py` can walk gm's `pkg-*`
outputs into `container/`'s image outputs, giving a single unified
DAG.

**But it is NOT part of gm's make dispatch.**  There is no
`target.img.mk` (was removed by design).  Users invoke
`container/imageBuild.py build <manifest.yaml>` directly, and
`make refresh` LISTS affected images (via dep_query) rather than
rebuilding them.

Why the split:

- Docker images have their own build model (Dockerfile, layer cache,
  registry push) that doesn't fit make's file-oriented model.
- Container is expected to eventually spin out to its own repo.  The
  dep.json schema is the stable contract; everything else can churn.

See `container/README.md` for its own architecture doc.

---

## 12. pkg_of.mk + PKG_HEADERS — pkg version-macro inheritance

YAML-mode pkgs (target.pkg.mk with `PKG_YAML` set) generate a per-pkg
header at `$(GM_GEN_DIR)/<pkg>/component.h`, filled with the pkg's
schema-validated name, version, unique ID, ...  Libs bundled into
that pkg often want to embed those values (versionstamp / runtime
identity strings).

The **auto-inheritance** flow:

1. **`make deps` phase 1** runs every `pkg-*` target under DRY_RUN=1.
   For YAML-mode pkgs, `target.pkg.mk` sets `DRY_REVERSE_PREFIX :=
   PKG_OF` before including `target.dry-run.mk`.
2. `target.dry-run.mk`'s reverse-map hook fires: for each `d` in
   `DRY_DEPS` (the intree libs/exes the pkg bundles), it upserts
   `PKG_OF_<d> := <pkg-name>` into `$(GM_OUT)/pkg_of.mk`.
3. **`make deps` phase 2** runs libs/exes/tests.  Their sub-makes
   load env.mk, which `-include`s pkg_of.mk in a target sub-make
   (read only) → variables like
   `PKG_OF_libtmstats = "pkg-tmd pkg-tm-devel"` are in scope.
4. **`target.c.mk`** consults them when the `.mk` asks for it:
   ```make
   ifeq ($(PKG_HEADERS),yes)
   PKG_HEADERS := $(PKG_OF_$(TARGET))    # every pkg that ships this target
   endif
   ```
   Unset means no coupling.  A target no pkg ships (a test, the generated alarm library)
   names the pkg instead: `PKG_HEADERS := pkg-tmd` (_pkg_alarm.mk does this).
5. **PKG_HEADERS drives**:
   - `-I $(GM_GEN_DIR)/<pkg>` (short include form:
     `#include <component.h>`)
   - `$(OBJS): $(GM_GEN_DIR)/<pkg>/component.h` (obj prereq)
   - DRY_DEPS gets `<pkg>-header` appended → depend.mk chains
     `libtmstats: pkg-tmd-header pkg-tm-devel-header` so a cold clone builds the header
     phony first (fast: no rpmbuild, just pkg-build.py + a sed).
6. **`make-versionstamp.sh`** compiles the pkg's macros
   (`NAME`, `PKG_VERSION`, `MAJOR_VERSION`, ...) into a
   `strings`-recoverable global in every consumer's artefact.
7. **component.h is remade from all its inputs**: pkg.yaml, pkg-build.py, and the values the
   pkg's `.mk` (or the command line) passes -- `PKG_VERSION`, the release, `PKG_YAML_VARS`,
   `PKG_INSTALL_ROOT` -- through a `_FLAG_STAMP` (`$(GM_GEN_DIR)/<pkg>/.values`).  It used to
   depend on pkg.yaml alone: a new PKG_VERSION left every binary with the old macros (check 17
   leg T).  The stamp sits next to the header because every variant shares the header; one per
   BUILD_DIR would regenerate it for each variant in turn and recompile the others' consumers.

### Multi-pkg headers — how a lib in two pkgs sees both identities

**Question**: `libtmstats` is bundled by BOTH `pkg-tmd` AND `pkg-tm-devel` (both YAML-mode);
does it embed both pkgs' versions?

**Answer**: yes.  Three coordinated pieces make it work:

**1. `pkg-build.py`'s `component.h` emits ONLY PREFIXED macros**:

   `TMD_NAME`, `TMD_PKG_VERSION`, `TMD_MAJOR_VERSION`, `TMD_UNIQUE_COMPONENT_ID`,
   ...  Prefix derived from the pkg name's last dot/hyphen segment,
   uppercased (`pkg-tmd` → `TMD`, `pkg-tm-devel` → `DEVEL`, `Component.HssServer.pcgw` → `PCGW`).

   Per-pkg include guard `COMPONENT_H_<PREFIX>_INCLUDED` protects
   the same pkg's header from being double-included.  Different pkgs'
   headers coexist in one TU with zero risk of macro collision —
   they live in disjoint namespaces (`TMD_*` vs `DEVEL_*`).

   **Design choice**: no unprefixed back-compat aliases.  While gm
   is pre-1.0, we require explicit prefixes so users learn the
   correct pattern up front.  Unprefixed shortcuts would silently
   resolve to whichever header was included first — invisible bug
   waiting to happen once a lib enters a second pkg.

**2. `target.dry-run.mk`'s reverse-map hook uses APPEND-TO-LIST**:

   ```
   PKG_OF_libtmstats := pkg-tmd pkg-tm-devel       # both owners
   ```

   Order is deterministic (sorted `TARGET_PKG`).  Idempotent: adding
   the same owner twice is a no-op.

**3. `target.c.mk`'s `PKG_HEADERS` fallback + `make-versionstamp.sh`
   loop the list**:

   ```make
   # target.c.mk
   PKG_HEADERS := $(PKG_OF_$(TARGET))    # = "pkg-tmd pkg-tm-devel"
   _PKG_HEADER_FILES := $(foreach p,$(PKG_HEADERS),$(GM_GEN_DIR)/$(p)/component.h)
   CCFLAGS += $(foreach p,$(PKG_HEADERS),-I$(GM_GEN_DIR)/$(p)) -I$(GM_GEN_DIR)
   ```

   Note `-I$(GM_GEN_DIR)` (unqualified parent dir) is ALSO added so
   users can write `#include <pkg-tmd/component.h>` regardless of
   how many pkg headers they consume.

   `make-versionstamp.sh` `#include`s each pkg-header and emits one
   identity block per pkg:

   ```c
   #include <pkg-tmd/component.h>
   #include <pkg-tm-devel/component.h>

   const char *__gm_versionstamp_libtmstats__ =
       "GM_VERSIONSTAMP:"
       " target=libtmstats ..."
       " pkg=" TMD_PKG_NAME " ver=" TMD_PKG_VERSION " (" TMD_PKG_RELEASE ")"
       " pkg=" DEVEL_PKG_NAME " ver=" DEVEL_PKG_VERSION " (" DEVEL_PKG_RELEASE ")"
       "";
   ```

**Result**: `strings libtmstats.so | grep GM_VERSIONSTAMP:` prints one
line with both pkgs' identity concatenated.

**Lib-author pattern** (example/stats/src/window.cxx):

```c
#include <pkg-tm-devel/component.h>
#include <pkg-tmd/component.h>

const char *v1 = TMD_PKG_VERSION;     // "1.4.0"
const char *v2 = DEVEL_PKG_VERSION;   // "1.4.0"
int major      = TMD_MAJOR_VERSION;   // 1
```

Always use the pkg-qualified include (`<pkg-tmd/component.h>`) and
the prefixed macros.  No ambiguity, no order dependence.

---

## 13. Container-friendly conventions in gm's code

For consistency with `container/` (which vendors `pydep/` and
`dep-hooks.sh` from `production/tools/` via a sys.path shim):

- `production/tools/pydep/` — canonical location of the DAG classes.
  `container/buildTools/pybuild/json_pretty.py` shims into
  `pydep.pretty`.  If you refactor pydep, container may need a matching
  update.
- `production/tools/dep-hooks.sh` — canonical location of the cp/install
  wrapper for capture-during-copy.  `container/` sources it directly.
  Both callers use `realpath -s` (not `realpath`), preserving symlinks
  so `$(GM_LIB_DIR)/libtmstats.so` doesn't resolve down to a per-target
  BUILD_DIR path.

---

## 14. Legality guards — what env.mk refuses

At parse time (every make instance, §9.3):

- `SUB_TARGET=<value>` — whitelist `clean` (empty = default).  `check`
  was previously accepted but every per-type implementation had drifted
  from its designed purpose (artefact-diff against a reference build);
  all removed pending a re-implementation.  See env.mk's design note
  next to `SUB_TARGET_VALID`.
- `BUILD_MODE=<value>` — whitelist `debug release`
  (extend via `GM_VALID_MODES += <name>` in the project Makefile
  BEFORE including env.mk).
- `SANITIZE=<set>` — comma list of `address undefined thread` (empty =
  off); unknown entries and `address`+`thread` are refused.  `COVERAGE` —
  empty / `0` / `no` / `1` / `yes`.  Every output dir, `BUILD_DIR` and
  `%/$(GM_MODE_DIR)` mkdir rule goes through `GM_MODE_DIR`, so instrumented
  and plain objects never share a directory (§6.1).
- `MAKECMDGOALS` mixing `lib*` + `pkg*` — refused (they're different
  DAG tiers; run separately for explicit ordering).  DRY_RUN dispatch
  is exempt (dep-derivation legitimately needs both).
- `o=<value>` — alias for `SUB_TARGET=`.

Every guard emits an error message that names the invalid value AND
tells the user how to fix / extend.

---

## 15. Where to add code — the footprint ladder

When a user wants "gm to do X", think in this order (least footprint
first):

1. **Just write a `<name>.mk`** — most needs are one file in the
   user's own directory, no framework change.
2. **Extend an existing `target.<TYPE>.mk`** knob — add a variable
   (`FOO_FLAGS`, `BAR_SOURCE`, ...) with a `?=` default.
3. **Add a new phony to `incremental.mk` / `coverage.mk` / `test.mk`**
   — for user-facing verbs (`make ...`).
4. **Add a new helper script under `production/make/scripts/` or
   `production/tools/`** — anything Python / bash that's easier to
   maintain outside make syntax.
5. **New TYPE / new `target.<TYPE>.mk`** — reserved for genuine new
   language integrations (java was the last).  Register in
   `_CLASSIFY` (project.mk) + `TARGET_RULES_FOR` (top Makefile) +
   `_OUT_DIR_FOR` (project.mk).
6. **Modify `env.mk` or the top-level `Makefile`** — last resort.
   These files are load-bearing for every sub-make.  Small changes,
   heavy review.

Never bypass gm by hand-editing `depend.mk` or `pkg_of.mk` — they're
build artefacts and get overwritten.

---

## 16. Testing + preflight

`make precheck` — runs `production/tools/precheck.sh`, which is the
single-command battery of local static checks.  CI runs the exact
same script.  If precheck passes locally, CI's static lanes will
also pass; if precheck breaks, CI is a wasted round-trip.

Checks (as of writing):

1. YAML syntax    (`.github/**/*.yml`, `container/**/*.yaml`)
2. Python AST     (every `.py` parses)
3. Ruff           (config: `production/ruff/ruff.toml`)
4. Mypy           (config: `production/mypy/mypy.ini`)
5. Shellcheck     (every `.sh`)
6. Actionlint     (`.github/workflows/*.yml`)
7. Jq syntax      (`production/make/scripts/*.jq`)
8. gm smoke       (`make list` sees every example target)
9. nested-gm guard, duplicate basenames, bad LDLIBS, idempotence, compile database
10. build variants (`SANITIZE` / `COVERAGE` axes, per-mode flags, hardening)
11. compiler selection (`CC` / `CXX` / `PATH`, ccache shims skipped)
12. `gm core|watch|symbols` against tiny crash programs (needs gdb + Python; skipped otherwise)
13. build regressions in a scratch copy (phony target names, sub-dir sources, quoting, per-target
    clean, optional jq, toolchain gating, rpmbuild log tail, concurrent makes)

Add a new check = write a `check_<name>` bash function in
precheck.sh, register in `ALL_CHECKS`.  Nothing else changes.
`--only <name>` runs a single check.  `--list` shows the registry.

---

## 17. Common pitfalls (things past PRs got wrong)

- **Hard-coding `build/`** — always go through `$(GM_OUT)` /
  `$(GM_LIB_DIR)` / etc.  See §5.
- **Forgetting `export`** — a new variable that sub-makes need won't
  work unless you add it to env.mk's `export` list.  See §9.2.
- **`DRY_RUN := 0`** — never assign this unconditionally.  See §9.2.
- **Adding a `pyproject.toml` at repo root** — gm is not a Python
  package.  Configs live at `production/ruff/`, `production/mypy/`
  (see §3).
- **Adding a check to CI without adding it to `precheck.sh`** —
  breaks the "local = CI" invariant.  See §16.
- **Grepping user's `.mk` content for classifier hints** — see §4,
  the classifier is filename+sibling ONLY on purpose.
- **Symlinking a jar into `$(GM_JAVA_DIR)`** — breaks
  `Class-Path:` resolution.  Build the jar directly there.  See §5.
- **Hard-coding a pkg-header path instead of using `PKG_HEADERS`** —
  the auto-inheritance via pkg_of.mk is the intended mechanism.  See §12.

---

## 18. Contact / lineage

- Framework author: `cyrus.cui@nokia.com`
- Design lineage: distilled from `the reference build (in-tree at
  `backup/the reference build — same conceptual model (depend.mk sed
  upsert, pkg-XML component headers, versionstamp .cpp), rewritten
  in raw GNU Make on top of a smaller, uniform Python core (pydep).
- Open design questions and future work are tracked in `docs/6-TODO.md`.
  When you see a design that looks incomplete, check TODO before
  proposing a fix — the direction is often already scoped.

---

**When in doubt, ask.**  The system has enough coupling that a
"cleanup" in one file can silently break assumptions in another.
Reading this doc + one round of `make precheck` + running
`do_build.sh` should be the standard opening move for any change.
