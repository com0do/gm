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
├── example/                      # sample targets exercising every type
│   ├── t1/  t2/                 #   lib (C++ + gtest tests under test/)
│   ├── t3/                       #   exe
│   ├── g1/                       #   go
│   ├── j1/  j2/                 #   java  (j2 depends on j1)
│   ├── p1/                       #   pkg (plain-mode)
│   └── p2/                       #   pkg (XML-mode, versionstamp demo)
│
├── production/                   # THE FRAMEWORK — never scanned as
│   │                            # user targets (EXCLUDE_DIR).
│   ├── make/
│   │   ├── env.mk                # tools + defaults + legality guards +
│   │   │                        #   GM_OUT layout + framework file list
│   │   ├── flags.mk              # CFLAGS/CCFLAGS/LDFLAGS accumulators + compiler selection (CC/CXX/PATH → GM_CC/GM_CXX/GM_LD)
│   │   ├── project.mk            # TARGET_ALL discovery, deps rule
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
| basename starts with `test-`                   | test  | target.c.mk           | binary + gtest   |
| basename starts with `lib`                     | lib   | target.c.mk           | `.so` or `.a`    |
| sibling `go.mod` present                       | go    | target.go.mk          | binary           |
| any `.java` under the target dir (find -quit)  | java  | target.java.mk        | `.jar`           |
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
2. `depend.mk`'s line key (`t3: libt1 libt2`)
3. `pkg_of.mk`'s key (`PKG_OF_libt2 := pkg-p2`)
4. `dep_query.py`'s target identity
5. `TARGET_ALL` — the in-tree-vs-system-lib filter that makes
   automatic `-lfoo` → `libfoo` build-**order** derivation possible

Divergence broke all five.  Observed symptoms before removal:
`make libt1` → "No rule to make target"; `-lrenamed` silently
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
                       user runs `make libt2`
                                │
                                ▼
                    ┌───────────────────────┐
                    │ TOP-LEVEL Makefile    │
                    │   .DEFAULT_GOAL = all │
                    │   include env.mk      │──── FAIL-FAST LEGALITY
                    │   include project.mk  │──── TARGET_ALL discovery
                    │   include incr/cov/…  │
                    │   -include depend.mk  │──── pre-built lib-level DAG
                    └──────────┬────────────┘
                               │
                    ┌──────────▼────────────┐
                    │ $(TARGET_ALL) rule    │
                    │   dispatch by TYPE    │──── $(MAKE) -C <srcdir>
                    │   forwards            │       -f libt2.mk
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
libt2:pkg-p2-header
pkg-p1:libt2 t3
t3:libt1 libt2 pkg-p2-header
test-t2:libt2 libgtest libgtest_main pkg-p2-header
```

Each line is a plain make rule: `<target>: <its intree prereqs>`.
`-include`'d from the top Makefile, so `make t3` on a cold clone
naturally builds `libt1 libt2 pkg-p2-header` first.

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
| Go     | `depgo.sh` — `go list -deps` walk + framework post-processing (jq) |
| Java   | `depjava.py` — import + package-graph walker + `--intree-jar` (there's no `go list` for java, so we parse imports ourselves) |
| Pkg    | `pkgdeps.py` — hooks.jsonl (plain mode) or rpmbuild log (XML mode) + framework via `--extra-dep` |
| Image  | `container/` — see §11                                        |

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

`$(TARGET_ALL)` dispatcher recipe (top-level `Makefile`):

```make
$(MAKE) -C $(SOURCE_DIR) -f env.mk -f $($@_mkfile) -f $(call TARGET_RULES_FOR,$(TYPE)) \
    $(_GM_CMDLINE) BUILD_DIR='$(BUILD_DIR)' OUT_DIR='$(OUT_DIR)' \
    SOURCE_DIR='$(SOURCE_DIR)' REL_DIR='$(REL_DIR)' TYPE='$(TYPE)' $(SUB_TARGET)
```

- `_GM_CMDLINE` carries what the top level derived: `PROJ_TOP ADMIN_DIR
  BUILD_ARCH BUILD_MODE SANITIZE GM_OUT DEP_TREE GM_SYS_LIBS TARGET_ALL
  TARGET_DEP`.  Anything new that the top level computes and sub-makes must
  agree on belongs here.
- These are passed on the sub-make's cmdline, so they get **cmdline-override**
  semantics: they beat any `:=` assignment in target.c.mk / target.go.mk / ...
- `$(SUB_TARGET)` is the sub-make's goal (empty = build the target;
  `clean` otherwise — see env.mk's SUB_TARGET whitelist).

### 9.2 MAKEFLAGS and the environment

- Variables given on the command line (`DRY_RUN=1`, `WARN_LEVEL=...`,
  `CC=...`) ride in `MAKEFLAGS` into every child make; that is how
  `DRY_RUN` reaches the leaf without being in `_GM_CMDLINE`
  (docs/3-DRY_RUN.md).  A makefile assignment never beats a cmdline value.
- Exported on purpose: `GM_TREE=1` (nesting guard, env.mk) and
  `SOURCE_DATE_EPOCH`.  Re-entry sites clear the guard with `GM_TREE= $(MAKE) ...`.

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
GM_FRAMEWORK_CORE_MK := \
    $(PROJ_TOP)/Makefile      \
    $(ADMIN_DIR)/make/env.mk  \
    $(ADMIN_DIR)/make/flags.mk \
    $(ADMIN_DIR)/make/project.mk \
    $(ADMIN_DIR)/make/target.common.mk
```

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
  own target.  A change to `libt2.mk` should invalidate libt2, not
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
   load env.mk which `-include`s pkg_of.mk → variables like
   `PKG_OF_libt2 = "pkg-p2"` are in scope.
4. **`target.c.mk`** consults them:
   ```make
   PKG_HEADERS ?=
   ifeq ($(strip $(PKG_HEADERS)),)
   PKG_HEADERS := $(PKG_OF_$(TARGET))    # auto-fill
   endif
   ```
   User can override by hand-writing `PKG_HEADERS := pkg-p2` in the
   lib.mk.
5. **PKG_HEADERS drives**:
   - `-I $(GM_GEN_DIR)/<pkg>` (short include form:
     `#include <component.h>`)
   - `$(OBJS): $(GM_GEN_DIR)/<pkg>/component.h` (obj prereq)
   - DRY_DEPS gets `<pkg>-header` appended → depend.mk chains
     `libt2: pkg-p2-header` so a cold clone builds the header
     phony first (fast: no rpmbuild, just pkg-build.py + a sed).
6. **`make-versionstamp.sh`** compiles the pkg's macros
   (`NAME`, `PKG_VERSION`, `MAJOR_VERSION`, ...) into a
   `strings`-recoverable global in every consumer's artefact.

### Multi-pkg headers — how a lib in two pkgs sees both identities

**Question**: if `libt2` is bundled by BOTH `pkg-p1` AND `pkg-p2`
(both XML-mode), does libt2 embed both pkgs' versions?

**Answer**: yes.  Three coordinated pieces make it work:

**1. `pkg-build.py`'s `component.h` emits ONLY PREFIXED macros**:

   `P2_NAME`, `P2_PKG_VERSION`, `P2_MAJOR_VERSION`, `P2_UNIQUE_COMPONENT_ID`,
   ...  Prefix derived from the pkg name's last dot/hyphen segment,
   uppercased (`pkg-p2` → `P2`, `Component.HssServer.pcgw` → `PCGW`).

   Per-pkg include guard `COMPONENT_H_<PREFIX>_INCLUDED` protects
   the same pkg's header from being double-included.  Different pkgs'
   headers coexist in one TU with zero risk of macro collision —
   they live in disjoint namespaces (`P1_*` vs `P2_*`).

   **Design choice**: no unprefixed back-compat aliases.  While gm
   is pre-1.0, we require explicit prefixes so users learn the
   correct pattern up front.  Unprefixed shortcuts would silently
   resolve to whichever header was included first — invisible bug
   waiting to happen once a lib enters a second pkg.

**2. `target.dry-run.mk`'s reverse-map hook uses APPEND-TO-LIST**:

   ```
   PKG_OF_libt2 := pkg-p1 pkg-p2       # both owners
   ```

   Order is deterministic (sorted `TARGET_PKG`).  Idempotent: adding
   the same owner twice is a no-op.

**3. `target.c.mk`'s `PKG_HEADERS` fallback + `make-versionstamp.sh`
   loop the list**:

   ```make
   # target.c.mk
   PKG_HEADERS := $(PKG_OF_$(TARGET))    # = "pkg-p1 pkg-p2"
   _PKG_HEADER_FILES := $(foreach p,$(PKG_HEADERS),$(GM_GEN_DIR)/$(p)/component.h)
   CCFLAGS += $(foreach p,$(PKG_HEADERS),-I$(GM_GEN_DIR)/$(p)) -I$(GM_GEN_DIR)
   ```

   Note `-I$(GM_GEN_DIR)` (unqualified parent dir) is ALSO added so
   users can write `#include <pkg-p1/component.h>` regardless of
   how many pkg headers they consume.

   `make-versionstamp.sh` `#include`s each pkg-header and emits one
   identity block per pkg:

   ```c
   #include <pkg-p1/component.h>
   #include <pkg-p2/component.h>

   const char *__gm_versionstamp_libt2__ =
       "GM_VERSIONSTAMP:"
       " target=libt2 ..."
       " pkg=" P1_PKG_NAME " ver=" P1_PKG_VERSION " (" P1_PKG_RELEASE ")"
       " pkg=" P2_PKG_NAME " ver=" P2_PKG_VERSION " (" P2_PKG_RELEASE ")"
       "";
   ```

**Result**: `strings libt2.so | grep GM_VERSIONSTAMP:` prints one
line with both pkgs' identity concatenated.

**Lib-author pattern**:

```c
#include <pkg-p1/component.h>
#include <pkg-p2/component.h>

const char *v1 = P1_PKG_VERSION;   // "1.0"
const char *v2 = P2_PKG_VERSION;   // "2.5.1"
int major1     = P1_MAJOR_VERSION; // 1
int major2     = P2_MAJOR_VERSION; // 2
```

Always use the pkg-qualified include (`<pkg-p2/component.h>`) and
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
  so `$(GM_LIB_DIR)/libt2.so` doesn't resolve down to a per-target
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
8. gm smoke       (`make list-targets` sees every example target)
9. nested-gm guard, duplicate basenames, bad LDLIBS, idempotence, compile database
10. build variants (`SANITIZE` / `COVERAGE` axes, per-mode flags, hardening)
11. compiler selection (`CC` / `CXX` / `PATH`, ccache shims skipped)
12. `gm core|watch|symbols` against tiny crash programs (needs gdb + Python; skipped otherwise)

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
