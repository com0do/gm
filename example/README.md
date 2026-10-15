# The example product: `tm`, a small telemetry stack

gm's own example tree is one product, built the way a real one would be.  A daemon reads
`metric value` samples, keeps a sliding window per metric, raises alarms when a metric crosses
its threshold, and writes JSON snapshots; a Go exporter turns a snapshot into Prometheus text and
a Java dashboard draws it.  It is written in C, C++, Go and Java, uses two third-party
libraries and ships as three rpms.  Every `.mk` file says in its header what gm feature it
shows.

```
loadgen / tmctl wave  ──>  tmd  ──>  tmexport  ──>  tmview
  (sample lines)          (C++)        (Go)         (Java)
```

## What is where

| directory | target | type | what it shows |
|-----------|--------|------|---------------|
| `core/` | `libtmcore` | lib (static) | C sources under `src/`, public headers under `include/`, a header generated from `include/tm_build.h.in` (`HEADER_GEN`) |
| `core/test/` | `test-tmcore` | test | gtest target: gm adds gtest and the library's headers |
| `stats/` | `libtmstats` | lib (shared) | built on the static lib (`-ltmcore` is the whole declaration); shipped in two packages and gets both `component.h` (`PKG_HEADERS := yes`) |
| `stats/test/` | `test-tmstats` | test | |
| `cli/` | `tmctl` | exe (C) | a static in-tree lib plus a system lib (`-lm`) |
| `daemon/` | `tmd` | exe (C++) | links an in-tree lib, a third-party lib gm compiles, one a vendor Makefile builds, and a lib generated from pkg.yaml; versionstamp in the binary |
| `daemon/alarms/` | `libtmalarms` | lib (static) | the alarm table generated from the `alarms:` of pkg-tmd's `pkg.yaml` |
| `daemon/deploy/` | `pkg-tmd` | pkg (YAML) | scriptlets, `%config`, owned and ghost paths, a vendor artefact named unlike its `.mk`, `-debuginfo` rpm |
| `sdk/` | `pkg-tm-devel` | pkg (YAML) | filegroups of its own (`PKG_FILEGROUP_MAP`), `rpm_deps` on an in-tree package |
| `tmtools/` | `pkg-tm-tools` | pkg (`.spec`) | a hand-written `.spec`: `PKG_FILES`, `PKG_EXTRA_FILES` |
| `exporter/` | `tmexport` | go | a module with an `internal/` package and `cmd/` main (`GO_PROJ_SUBPKG`) |
| `cgo/` | `tmcrc` | go (cgo) | Go calling libtmcore; `LDLIBS` orders it after the C library |
| `dashboard/api/` | `tmapi` | java | a library jar |
| `dashboard/view/` | `tmview` | java | an executable jar on the library jar (`JAR_DEPS`, `MAIN_CLASS`) |
| `selftest/` | `test-asan` | test | checks that `SANITIZE=address` really reports memory errors |
| `../third_party/ini/` | `libini` | lib (static) | third-party sources kept pristine under `vendor/`, compiled by gm with relaxed warnings for this target only |
| `../third_party/minijson/` | `libminijson` | import-lib | a vendor Makefile gm runs as a black box; four artefacts (`.so`, `.a`, `libminijson_file.so`, the `jsonpp` tool), each routed by suffix |
| `../third_party/loadgen/` | `loadgen` | import-exe | an imported executable |

Nothing above is registered anywhere: gm finds the `.mk` files, classifies them by name and
derives the build order from what each one links or packages.

## C++11 / 14 / 17 in the code

The C++ is written for gm's default `CXX_STD` (`c++17`) and builds warning-free under gm's
strict set with gcc 8.5 (Rocky 8), 11 (Rocky 9) and 13 (Ubuntu 24.04).  Where to look:

| feature | standard | where |
|---------|----------|-------|
| `std::optional`, `if (init; cond)` | 17 | `daemon/src/main.cxx` (`parse_sample`), `daemon/src/config.cxx` (`load_config`) |
| structured bindings | 17 | `daemon/src/report.cxx` (map and table loops), `config.cxx` (`std::from_chars`), `stats/test/` |
| `std::string_view`, `<charconv>` `from_chars` | 17 | `config.cxx`, `main.cxx` (arguments, `kVersion`), `stats/src/window.cxx` (`version()`) |
| fold expression over a parameter pack | 17 | `main.cxx` (`say(...)`) |
| `inline constexpr` variable, `[[nodiscard]]`, `std::data` / `std::size` | 17 | `stats/include/tm/stats.hpp` |
| `map::try_emplace`, `insert_or_assign`, transparent `std::less<>` | 17 | `main.cxx`, `config.cxx` |
| relaxed `constexpr` function, checked by `static_assert` | 14 | `nearest_rank` in `stats.hpp`, `stats/test/test_tmstats.cxx` |
| generic lambda, init-capture | 14 | `stats/src/summary.cxx`, `report.cxx` |
| `std::make_unique`, digit separators | 14 | `main.cxx`, `core/test/test_tmcore.cxx` (`0xCBF4'3926u`) |
| `enum class`, `= delete`, `noexcept`, lambdas, pointers to members in a `constexpr std::array` | 11 | `main.cxx` (`Severity`, `Daemon`), `report.cxx` (`kStats`, `Writer`) |

## A tour

Set up the machine first ([README](../README.md#a-new-machine-step-by-step)).  Then:

```bash
make -j"$(nproc)"          # everything: 20 targets, three rpms
make test                  # test-tmcore, test-tmstats, test-asan (skips outside ASan)
```

**Run the product.**

```bash
E=build/exec/rhlinux/debug
$E/tmd --version           # package, libraries and build, from generated headers
$E/tmd --list-alarms       # the alarm table generated from pkg.yaml
( $E/loadgen cpu.load 0.5 300; $E/tmctl wave temp.celsius 120 35 ) \
    | $E/tmd --config example/daemon/deploy/tmd.conf \
    | $E/tmexport | java -jar build/java/tmview.jar
```

`tmd` logs its alarms (`ALARM 5103 MAJOR TmThresholdExceeded cpu.load=0.94 (limit 0.9)`) and
clears them; the dashboard shows mean and p95 per metric.  `strings $E/tmd | grep
GM_VERSIONSTAMP` shows what the binary was built from.

**See what gm derived.**

```bash
make show                  # every target, its type and what it depends on, in build order
make show-tmd              # tmd's edges, the package it ships in, its output, how to run it
make show-pkg              # the three packages: mode, version, rpm, what they contain
cat build/pkg_of.mk        # libtmstats is in pkg-tmd and pkg-tm-devel
cat build/import_of.mk     # libminijson_file and jsonpp map back to libminijson
```

**Which targets does a change affect?**  Build with `DEP_TREE=yes` once, then ask:

```bash
make DEP_TREE=yes
make changes CHANGES=example/core/src/ring.c
#   "libs": ["libtmcore", "libtmstats"], "exes": ["test-tmcore", "test-tmstats", "tmcrc", "tmctl", "tmd"],
#   "pkgs": ["pkg-tm-devel", "pkg-tm-tools", "pkg-tmd"]          (tmcrc: cgo links libtmcore)
make changes CHANGES=third_party/minijson/vendor/src/minijson.c     # libminijson, tmd, pkg-tmd
make changes CHANGES=example/daemon/deploy/pkg.yaml
#   through the files generated from it -- component.h, alarms.cxx:
#   "libs": ["libtmalarms", "libtmstats"], "exes": ["test-tmstats", "tmd"], "pkgs": [...]
```

Raise `PKG_VERSION` in `daemon/deploy/pkg-tmd.mk` and `make` regenerates `component.h`
(`FLAGS pkg-tmd: component.h values changed`): `tmd --version` and the versionstamp follow.

**Flags are tracked.**  Add `CCFLAGS += -DNDEBUG` to `stats/libtmstats.mk` and run `make`:
gm prints `FLAGS libtmstats: compile flags changed`, recompiles that library only, relinks
what links it and repackages the two rpms that ship it.

**Reproducible.**  Build the tree in two directories and compare:

```bash
for d in /tmp/a /tmp/b/deeper; do
    mkdir -p $d && git archive HEAD | tar -x -C $d
    (cd $d && BUILD_HOST=ci make -s -j8 tmd pkg-tmd)
done
sha256sum /tmp/a/build/pkg/*/*/pkg-tmd-1*.rpm /tmp/b/deeper/build/pkg/*/*/pkg-tmd-1*.rpm   # equal
```

**Variants.**  Each gets its own output tree next to `debug/`:

```bash
make SANITIZE=address test        # test-asan now runs and must see every error reported
make BUILD_MODE=release
make coverage                     # gcovr report in build/coverage/
```

**A crash in the field.**  `tmd --fail-fast` aborts on the first MAJOR alarm, for test runs
that want a core file:

```bash
ulimit -c unlimited
$E/loadgen cpu.load 0.5 300 | $E/tmd --config example/daemon/deploy/tmd.conf --fail-fast
# The core is ./core.<pid>, or with systemd-coredump: coredumpctl dump tmd -o tmd.core
gm core tmd.core --exe $E/tmd
#   signal: SIGABRT ... #2 Daemon::raise (number=5103, metric="cpu.load", value=0.9109, ...)
#   at ./example/daemon/src/main.cxx:75   | std::abort();
```

**Tolerant of what is missing.**  Without `go`, `javac` or `rpmbuild` the rest still builds:
`make` prints `SKIP tmcrc tmexport (go not found)` and the like.
