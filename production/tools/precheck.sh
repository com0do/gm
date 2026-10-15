#!/bin/bash
# production/tools/precheck.sh -- run every static check locally,
# before pushing.  Exit non-zero if ANY check failed.
#
#
# This is the same set the CI runs (.github/workflows/ci.yml).
# The rule is: any static check that CI runs must also be runnable
# locally with one command.  If you find CI catching a class of
# problem that this script misses, add a `check_<name>` function
# and register it in $ALL_CHECKS at the bottom.
#
# Usage:
#   make precheck                              # via Makefile (recommended)
#   production/tools/precheck.sh               # direct: run every check
#   production/tools/precheck.sh --fast        # skip slow checks (mypy, actionlint fetch)
#   production/tools/precheck.sh --fix         # apply safe auto-fixes (ruff)
#   production/tools/precheck.sh --only ruff   # run one named check
#   production/tools/precheck.sh --list        # show every registered check
#
# Requirements (all optional; missing tools trigger a skip, not a
# failure): python3, ruff, mypy, shellcheck, actionlint, jq, PyYAML.
#
# Design: each check is a `check_<name>` bash function.  The driver
# calls whatever's in $ALL_CHECKS (or the single --only target).
# Each function is self-contained -- start banner, tool probe, run,
# ok/skip/fail via helpers -- so a new check is one new function +
# one new $ALL_CHECKS entry.  No refactoring of surrounding code.

set -uo pipefail


########################################################################
# CLI arg parsing
########################################################################
FAST=0
FIX=0
ONLY=""
LIST=0
show_help() { sed -n '2,35p' "$0" ; exit 0 ; }
while [ $# -gt 0 ]; do
    case "$1" in
        --fast)        FAST=1 ;;
        --fix)         FIX=1  ;;
        --only)        shift ; ONLY="${1:-}"; [ -z "$ONLY" ] && { echo "--only needs a check name" >&2; exit 2 ; } ;;
        --only=*)      ONLY="${1#--only=}" ;;
        --list)        LIST=1 ;;
        -h|--help)     show_help ;;
        *) echo "precheck.sh: unknown arg $1  (--help for usage)" >&2; exit 2 ;;
    esac
    shift
done


########################################################################
# Setup -- cd to the repo root.  This script lives at
# production/tools/precheck.sh, so `../..` reaches the top of gm.
# All lint invocations use paths relative to $ROOT so the script
# works no matter where the caller invoked it from.
########################################################################
cd "$(dirname "$0")/../.." || {
    echo "precheck.sh: cannot cd to repo root -- was the script relocated?" >&2
    exit 2
}
ROOT=$(pwd)

# Tool-specific config paths -- passed explicitly to ruff/mypy so we
# don't rely on their upward-directory config search (which would
# fail on container/ since that subtree has no ancestor holding a
# config file).
RUFF_CONFIG="$ROOT/production/ruff/ruff.toml"
MYPY_CONFIG="$ROOT/production/mypy/mypy.ini"


########################################################################
# Output helpers.  ANSI-only when stdout is a TTY.
########################################################################
if [ -t 1 ]; then
    C_RED=$'\e[31m';   C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=; C_GREEN=; C_YELLOW=; C_BOLD=; C_RESET=
fi

FAIL=()
SKIP=()

start_check() { printf '\n%s%s>> %s%s\n' "$C_BOLD" "$C_YELLOW" "$1" "$C_RESET" ; }
ok_check()    { printf '%s ✓ %s%s\n'    "$C_GREEN"  "$1" "$C_RESET" ; }
skip_check()  { printf '%s ↷ %s (skipped: %s)%s\n' "$C_YELLOW" "$1" "$2" "$C_RESET"; SKIP+=("$1"); }
fail_check()  { printf '%s ✗ %s%s\n'    "$C_RED"    "$1" "$C_RESET"; FAIL+=("$1"); }

have() { command -v "$1" >/dev/null 2>&1 ; }

# On GitHub Actions also raise an annotation: it is readable without the (login-gated) raw log.
ci_error() {  # ci_error <title> <text>
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    local msg
    msg=$(printf '%s' "$2" | tr -d '\r' | tail -c 3800 | sed ':a;N;$!ba;s/%/%25/g;s/\n/%0A/g')
    printf '::error title=%s::%s\n' "$1" "$msg"
}

ci_notice() {  # ci_notice <title> <text>: visible in the annotation list without the raw log
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
    printf '::notice title=%s::%s\n' "$1" "$2"
}

# Full build used by several checks; on failure show why instead of a bare "failed".
build_or_explain() {  # build_or_explain <check name>; returns 1 and prints the tail on failure
    local log
    log=$(mktemp)
    # shellcheck disable=SC1007
    if GM_TREE= make -s >"$log" 2>&1; then
        rm -f "$log"
        return 0
    fi
    local tc rpmlog=""
    tc="$(gcc --version 2>&1 | head -1); $(go version 2>&1 | head -1); $(javac -version 2>&1 | head -1); rpmbuild: $(command -v rpmbuild || echo none); $(python3 --version 2>&1)"
    echo "  make failed; toolchain: $tc"
    echo "  last lines:"
    tail -n 25 "$log" | sed 's/^/    /'
    # rpmbuild failures only name their log: show its tail too.
    rpmlog=$(sed -n 's/.*rpmbuild failed (see \(.*\)).*/\1/p' "$log" | head -1)
    if [ -n "$rpmlog" ] && [ -f "$rpmlog" ]; then
        echo "  rpmbuild log $rpmlog (tail):"
        tail -n 40 "$rpmlog" | cut -c1-220 | sed 's/^/    /'
    fi
    ci_error "$1: make failed" "toolchain: $tc
$(tail -n 6 "$log")
--- rpmbuild log tail ---
$( [ -n "$rpmlog" ] && [ -f "$rpmlog" ] && tail -n 40 "$rpmlog" | cut -c1-200)"
    rm -f "$log"
    return 1
}


########################################################################
# Individual checks -- one function per check.
#
# Contract:
#   * name starts with `check_`
#   * calls `start_check "<banner>"` first
#   * probes for tools; missing tool -> `skip_check`, return 0
#   * runs the actual check
#   * on success -> `ok_check "<lane>"`
#   * on failure -> `fail_check "<lane>"` (does NOT exit; the driver
#     accumulates FAIL[] and reports at the end so users see every
#     class of failure in one pass)
#
# Naming: `<lane>` is a short kebab-case tag that shows up in the
# final report.  Keep it stable -- CI comments and README reference
# these names.
########################################################################

# ---- 1. YAML validity ------------------------------------------------
check_yaml() {
    start_check "1. YAML syntax (.github + container YAMLs)"
    if ! have python3 || ! python3 -c "import yaml" 2>/dev/null; then
        skip_check "yaml" "no PyYAML"
        return 0
    fi
    if python3 - <<'PY'
import glob, sys, yaml
patterns = [".github/**/*.yml",
            ".github/**/*.yaml",
            "container/**/image.yaml",
            "container/**/*.yml"]
bad = []
for pat in patterns:
    for f in sorted(glob.glob(pat, recursive=True)):
        try: yaml.safe_load(open(f))
        except Exception as e: bad.append(f"{f}: {e}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
PY
    then ok_check "yaml"
    else fail_check "yaml"
    fi
}

# ---- 2. Python AST parse ---------------------------------------------
check_python_ast() {
    start_check "2. Python AST parse (production/ + container/ + .github/)"
    if ! have python3; then
        skip_check "python-syntax" "no python3"
        return 0
    fi
    if python3 - <<'PY'
import ast, glob, sys
files = sorted(set(
    glob.glob("production/**/*.py", recursive=True) +
    glob.glob("container/**/*.py",  recursive=True) +
    glob.glob(".github/**/*.py",    recursive=True)))
files = [f for f in files
         if "__pycache__" not in f and "gtest-1.14.0" not in f]
bad = []
for f in files:
    try: ast.parse(open(f).read(), filename=f)
    except SyntaxError as e: bad.append(f"{f}: {e}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
print(f"  {len(files)} files parse cleanly")
PY
    then ok_check "python-syntax"
    else fail_check "python-syntax"
    fi
}

# ---- 3. Ruff ---------------------------------------------------------
check_ruff() {
    start_check "3. ruff check (production/ container/)"
    if ! have ruff && ! python3 -m ruff --version >/dev/null 2>&1; then
        skip_check "ruff" "ruff not installed (pip install --user ruff)"
        return 0
    fi
    local fix_flag=""
    [ "$FIX" = "1" ] && fix_flag="--fix"
    if python3 -m ruff check --config "$RUFF_CONFIG" $fix_flag production/ container/; then
        ok_check "ruff"
    else
        fail_check "ruff"
    fi
}

# ---- 4. Mypy ---------------------------------------------------------
check_mypy() {
    if [ "$FAST" = "1" ]; then
        # Only report the skip; keep the banner off so --fast output
        # stays tidy (there'd be one skip banner per fast-only check).
        skip_check "mypy" "--fast requested"
        return 0
    fi
    start_check "4. mypy production/ container/"
    if ! have mypy && ! python3 -m mypy --version >/dev/null 2>&1; then
        skip_check "mypy" "mypy not installed (pip install --user mypy)"
        return 0
    fi
    if python3 -m mypy --config-file "$MYPY_CONFIG" \
            production/ container/ 2>&1 \
            | tee /tmp/gm-mypy.out | tail -1 | grep -q '^Success:'; then
        ok_check "mypy"
    else
        fail_check "mypy"
        echo "  --> full log at /tmp/gm-mypy.out"
    fi
}

# ---- 5. Shellcheck ---------------------------------------------------
check_shellcheck() {
    start_check "5. shellcheck on every shell script (production/ container/ example/ + do_build.sh)"
    if ! have shellcheck; then
        skip_check "shellcheck" "not installed (dnf install shellcheck / apt-get install shellcheck)"
        return 0
    fi
    # Two passes: *.sh by name, plus extension-less executables whose
    # shebang says shell.  The second pass exists because user-facing
    # entry points are installed onto PATH without an extension
    # (production/tools/gm), and those are exactly the scripts a bug
    # hurts most.
    local files
    files=$( { find production/make/scripts production/tools container example \
                    -name '*.sh' -type f 2>/dev/null
               find production/make/scripts production/tools container example \
                    ! -name '*.*' -type f -perm -u+x 2>/dev/null \
               | while read -r f; do
                     head -c 64 "$f" 2>/dev/null | head -1 \
                         | grep -qE '^#!.*\b(ba)?sh\b' && echo "$f"
                 done
               [ -f do_build.sh ] && echo do_build.sh ; } | sort -u)
    if [ -z "$files" ]; then
        skip_check "shellcheck" "no .sh found"
        return 0
    fi
    # -S warning: warn+error (info+style filtered out by default)
    # -e SC1091: allow dynamic `source` paths (our scripts do this)
    # -x       : follow sourced files during checking
    # shellcheck disable=SC2086  # $files is intentionally word-split
    if shellcheck -S warning -e SC1091 -x $files; then
        ok_check "shellcheck"
    else
        fail_check "shellcheck"
    fi
}

# ---- 6. actionlint ---------------------------------------------------
check_actionlint() {
    start_check "6. actionlint on .github/workflows/"
    local bin=""
    if have actionlint; then
        bin=actionlint
    elif [ -x /tmp/actionlint ]; then
        bin=/tmp/actionlint
    elif [ "$FAST" = "0" ] && have curl; then
        echo "  actionlint missing; installing to /tmp/actionlint ..."
        if curl -sSL "https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash" \
                | bash -s -- 1.7.7 /tmp >/dev/null 2>&1 ; then
            bin=/tmp/actionlint
        fi
    fi
    if [ -z "$bin" ]; then
        skip_check "actionlint" "not installed; --fast skips the download too"
        return 0
    fi
    # -shellcheck='' -pyflakes='' : we ran those already above; skip
    # actionlint's embedded copies to avoid version-mismatch noise.
    if "$bin" -no-color -shellcheck='' -pyflakes='' .github/workflows/*.yml; then
        ok_check "actionlint"
    else
        fail_check "actionlint"
    fi
}

# ---- 7. jq scripts syntax --------------------------------------------
check_jq() {
    start_check "7. jq -n --arg=... -f on .jq scripts (syntax only)"
    if ! have jq; then
        skip_check "jq" "not installed"
        return 0
    fi
    # We can't execute the scripts because they consume --arg values
    # supplied by the make recipes; we only want to catch syntax
    # errors.  `jq -f` fails on parse errors before it reads stdin,
    # so a null-input run detects syntax breakage even when runtime
    # deps aren't available.  Seed common vars so a missing --arg
    # doesn't itself mask the parse.
    local bad=0
    for j in production/make/scripts/*.jq; do
        [ -f "$j" ] || continue
        if ! jq -n \
                --arg FILE       x  --arg LIB_DEPS   x \
                --arg HEADER_INS x  --arg MK_FILE    x \
                --arg FRAMEWORK  x \
                -f "$j" </dev/null >/dev/null 2>err.tmp
        then
            # Only treat compile errors as real; runtime errors
            # (which jq reports as `jq: error (at <top-level>...)`)
            # are fine -- they're from feeding null to a jq program
            # that expected structured input.
            if grep -qE 'compile error|syntax error' err.tmp; then
                echo "  bad jq syntax: $j"
                cat err.tmp
                bad=$((bad+1))
            fi
        fi
        rm -f err.tmp
    done
    if [ "$bad" -eq 0 ]; then ok_check "jq"
    else fail_check "jq"; fi
}

# ---- 8. gm smoke -----------------------------------------------------
check_make_smoke() {
    start_check "8. gm smoke (make list sees every example target)"
    if ! have make; then
        skip_check "make list" "no make"
        return 0
    fi
    local out
    # Clear GM_TREE so this smoke-test make does not trip the
    # gm-inside-gm guard when precheck was itself invoked from a gm
    # recipe (`make precheck`).
    # shellcheck disable=SC1007  # `VAR= cmd` is a command prefix, not assignment
    out=$(GM_TREE= make -s list 2>/dev/null || true)
    if echo "$out" | grep -q -E 'libtmcore|tmd|pkg-tm-tools|tmapi|tmview'; then
        ok_check "make list"
    else
        echo "  got: $out"
        fail_check "make list"
    fi
}

# ---- 9. gm nested-invocation guard -----------------------------------
check_make_nested_gm() {
    start_check "9. gm rejects nested invocation (GM_TREE=1 make)"
    if ! have make; then
        skip_check "make nested-gm" "no make"
        return 0
    fi
    # `-n` short-circuits the actual build; parse-time $(error) fires
    # regardless.  Capture into a var so pipefail doesn't swallow the
    # make failure -> grep sees empty input.
    local out
    out=$(GM_TREE=1 make -n 2>&1 || true)
    if echo "$out" | grep -q 'gm cannot be nested'; then
        ok_check "make nested-gm"
    else
        echo "  got: $out" | head -3
        fail_check "make nested-gm"
    fi
}

# ---- 10. gm duplicate-basename guard ---------------------------------
# Cleanup happens BEFORE the assertion (not via RETURN trap) so the
# tree is restored even if the assertion path throws under `set -e`.
check_make_dup_basename() {
    start_check "10. gm rejects duplicate .mk basename (G4)"
    if ! have make; then
        skip_check "make dup-basename" "no make"
        return 0
    fi
    local orig=example/core/libtmcore.mk dup=example/cli/libtmcore.mk
    if [ ! -f "$orig" ]; then
        skip_check "make dup-basename" "$orig missing"
        return 0
    fi
    cp "$orig" "$dup"
    local out
    # shellcheck disable=SC1007
    out=$(GM_TREE= make -n 2>&1 || true)
    rm -f "$dup"
    if echo "$out" | grep -q 'libtmcore must be unique'; then
        ok_check "make dup-basename"
    else
        echo "  got:" ; echo "$out" | head -3 | sed 's/^/    /'
        fail_check "make dup-basename"
    fi
}

# ---- 11. gm unresolved -l diagnostic ---------------------------------
# LDLIB_CHECK is opt-in; exercise both states so we catch regressions
# in the gate AND the diagnostic itself.  Off state: silent even with
# a bogus -l.  On state: warning surfaces during `make deps`.
check_make_bad_ldlib() {
    start_check "11. gm LDLIB_CHECK gate + diagnostic"
    if ! have make; then
        skip_check "make bad-ldlib" "no make"
        return 0
    fi
    local mk=example/core/libtmcore.mk backup=/tmp/gm-precheck-libtmcore.mk.$$
    if [ ! -f "$mk" ]; then
        skip_check "make bad-ldlib" "$mk missing"
        return 0
    fi
    # -p preserves the .mk's mtime in the backup; mv restores it so
    # the subsequent idempotent check doesn't see this file as newer.
    cp -p "$mk" "$backup"
    printf '\nLDLIBS += -lZZZ_PRECHECK_FAKE\n' >> "$mk"

    local off_out on_out
    # shellcheck disable=SC1007
    off_out=$(GM_TREE= make deps 2>&1 || true)
    # shellcheck disable=SC1007
    on_out=$(GM_TREE= make deps LDLIB_CHECK=1 2>&1 || true)
    mv "$backup" "$mk"

    if echo "$off_out" | grep -q 'ZZZ_PRECHECK_FAKE'; then
        echo "  LDLIB_CHECK=0 leaked a warning:"
        echo "$off_out" | grep ZZZ | head -1 | sed 's/^/    /'
        fail_check "make bad-ldlib"
        return 0
    fi
    if echo "$on_out" | grep -q 'missing separator'; then
        echo "  LDLIB_CHECK=1 broke make itself:"
        echo "$on_out" | grep -B1 'missing separator' | head -3 | sed 's/^/    /'
        fail_check "make bad-ldlib"
        return 0
    fi
    if echo "$on_out" | grep -q 'ZZZ_PRECHECK_FAKE'; then
        ok_check "make bad-ldlib (off silent, on fires)"
    else
        echo "  LDLIB_CHECK=1 did NOT warn.  got:"
        echo "$on_out" | head -3 | sed 's/^/    /'
        fail_check "make bad-ldlib"
    fi
}

# ---- 12. gm idempotent (no-op) build ---------------------------------
check_make_idempotent() {
    start_check "12. gm second make on unchanged tree is quiet"
    if ! have make; then
        skip_check "make idempotent" "no make"
        return 0
    fi
    # Precondition: full build must complete first.  We tolerate the
    # first make's noise; the invariant is the SECOND make produces
    # zero output (no phony spam, no spurious rebuilds).
    if ! build_or_explain "make idempotent"; then
        fail_check "make idempotent"
        return 0
    fi
    local out
    # shellcheck disable=SC1007
    out=$(GM_TREE= make 2>&1)
    if [ -z "$(echo "$out" | grep -vE '^(make\[|$)')" ]; then
        ok_check "make idempotent"
    else
        echo "  got:"
        echo "$out" | head -6 | sed 's/^/    /'
        fail_check "make idempotent"
    fi
}

# ---- 13. gm compile_commands.json ------------------------------------
check_make_cdb() {
    start_check "13. gm generates build/compile_commands.json (clangd)"
    if ! have make || ! have jq; then
        skip_check "make cdb" "no make or no jq"
        return 0
    fi
    build_or_explain "make cdb" || {
        fail_check "make cdb"
        return 0
    }
    if [ ! -f build/compile_commands.json ]; then
        fail_check "make cdb"
        echo "  build/compile_commands.json missing after make"
        return 0
    fi
    local n
    n=$(jq 'length' build/compile_commands.json 2>/dev/null || echo 0)
    if [ "$n" -ge 5 ]; then
        # Also assert every entry has required fields.
        if jq -e 'all(.[]; has("file") and has("directory") and has("command"))' \
                build/compile_commands.json >/dev/null; then
            ok_check "make cdb ($n entries)"
        else
            fail_check "make cdb"
            echo "  entries missing required fields"
        fi
    else
        fail_check "make cdb"
        echo "  only $n entries (expected >=5)"
    fi
}

# ---- 14. gm variant axes and flag groups -------------------------------
# No compiling: env.mk + a throwaway `show` goal.  SANITIZE / COVERAGE are off
# by default and cover compile AND link; each mode keeps its own -O level and
# hardening; every variant gets a canonical dir; bad input is refused.
_gm_probe() {  # _gm_probe VAR=VAL...  -> flag dump on stdout (make output, errors included)
    printf '%b' 'show:\n\t@echo DIR=$(GM_MODE_DIR)\n\t@echo CFLAGS=$(CFLAGS)\n\t@echo CCFLAGS=$(CCFLAGS)\n\t@echo LDFLAGS=$(LDFLAGS)\n' \
        | env GM_TREE= make -s -f production/make/env.mk -f - show "$@" 2>&1 || true
}
check_make_variants() {
    start_check "14. gm variant axes (SANITIZE, COVERAGE) and per-mode flag groups"
    if ! have make; then
        skip_check "make variants" "no make"
        return 0
    fi
    local out var mode bad=0
    _need() {  # _need <label> <output> <egrep pattern>
        echo "$2" | grep -Eq -- "$3" || { echo "  $1: missing /$3/"; bad=$((bad+1)); }
    }
    _lack() {  # _lack <label> <output> <egrep pattern>
        echo "$2" | grep -Eq -- "$3" && { echo "  $1: unexpected /$3/"; bad=$((bad+1)); }
    }
    for mode in debug release; do
        out=$(_gm_probe BUILD_MODE="$mode")
        _need "$mode" "$out" "^DIR=$mode\$"
        _lack "$mode" "$out" 'fsanitize|--coverage'
        _need "$mode" "$out" '^CFLAGS=.*-fstack-protector-strong'
        _need "$mode" "$out" '^CCFLAGS=.*-fstack-protector-strong'
        _need "$mode" "$out" '^LDFLAGS=.*-z,relro,-z,now'
    done
    out=$(_gm_probe BUILD_MODE=debug);   _need debug "$out" '^CFLAGS=.* -O0( |$)'; _need debug "$out" '^CCFLAGS=.* -O0( |$)'; _lack debug "$out" 'FORTIFY|-O2'
    out=$(_gm_probe BUILD_MODE=release); _need release "$out" '^CFLAGS=.* -O2( |$)'; _need release "$out" '^CCFLAGS=.* -O2( |$)'; _need release "$out" 'D_FORTIFY_SOURCE=2'
    out=$(_gm_probe HARDEN=no BUILD_MODE=release); _lack HARDEN=no "$out" 'stack-protector|FORTIFY|relro'
    out=$(_gm_probe BUILD_MODE=release SANITIZE=undefined,address)
    _need sanitize "$out" '^DIR=release-asan-ubsan$'
    for var in CFLAGS CCFLAGS LDFLAGS; do _need "SANITIZE $var" "$out" "^$var=.*-fsanitize=address,undefined"; done
    out=$(_gm_probe COVERAGE=1)
    _need coverage "$out" '^DIR=debug-cov$'
    for var in CFLAGS CCFLAGS LDFLAGS; do _need "COVERAGE $var" "$out" "^$var=.*--coverage"; done
    _need coverage "$out" '^CCFLAGS=.* -O0( |$)'
    out=$(_gm_probe BUILD_MODE=release COVERAGE=yes SANITIZE=address)
    _need "both axes" "$out" '^DIR=release-asan-cov$'
    [ "$(echo "$out" | grep '^CCFLAGS=' | grep -oE ' -O[0-9s]' | tail -1)" = " -O0" ] \
        || { echo "  both axes: the last -O is not -O0 (coverage must win)"; bad=$((bad+1)); }
    _need refused "$(_gm_probe SANITIZE=thread,address)" 'SANITIZE='
    _need refused "$(_gm_probe SANITIZE=bogus)" 'SANITIZE='
    _need refused "$(_gm_probe COVERAGE=maybe)" 'COVERAGE='
    _need refused "$(_gm_probe BUILD_MODE=coverage)" 'COVERAGE=1'
    if [ "$bad" -eq 0 ]; then ok_check "make variants"
    else fail_check "make variants"; fi
}

# ---- 15. gm compiler selection (CC / CXX / PATH) -----------------------
# Precedence and PATH lookup (README "Toolchain"), with stub compilers.
_gm_cc_probe() {  # _gm_cc_probe -> "C_PATH CC_PATH LD_PATH CC=<value>" on one line
    printf '%b' 'show:\n\t@echo $(C_PATH) $(CC_PATH) $(LD_PATH) CC=$(CC)\n' \
        | env GM_TREE= make -s -f production/make/env.mk -f - show 2>&1 || true
}
check_make_compiler() {
    start_check "15. gm compiler selection (CC / CXX, else gcc / g++ on PATH; ccache shims skipped)"
    if ! have make; then
        skip_check "make compiler" "no make"
        return 0
    fi
    local d bad=0 got f
    d=$(mktemp -d)
    mkdir -p "$d/bin" "$d/alt" "$d/ccache"
    for f in bin/gcc bin/g++ alt/gcc-x alt/g++-x ccache/gcc ccache/g++; do
        printf '#!/bin/sh\nexit 0\n' > "$d/$f"; chmod +x "$d/$f"
    done
    _expect() {  # _expect <label> <want> <got>
        if [ "$2" != "$3" ]; then echo "  $1: want [$2]"; echo "  $1: got  [$3]"; bad=$((bad+1)); fi
    }
    got=$(PATH="$d/ccache:$d/bin:$PATH" _gm_cc_probe)
    _expect "PATH lookup (ccache shim skipped)" "$d/bin/gcc $d/bin/g++ $d/bin/g++ CC=" "$got"
    got=$(CC="$d/alt/gcc-x" CXX="$d/alt/g++-x" _gm_cc_probe)
    _expect "CC/CXX from env" "$d/alt/gcc-x $d/alt/g++-x $d/alt/g++-x CC=$d/alt/gcc-x" "$got"
    got=$(PATH="$d/alt:$PATH" CC=gcc-x CXX=g++-x _gm_cc_probe)
    _expect "bare names resolved on PATH" "$d/alt/gcc-x $d/alt/g++-x $d/alt/g++-x CC=gcc-x" "$got"
    got=$(CC=no-such-compiler-xyz _gm_cc_probe)
    case "$got" in *"compiler not found"*"CC='no-such-compiler-xyz'"*) ;; *) echo "  unknown CC not diagnosed: $got"; bad=$((bad+1)) ;; esac
    rm -rf "$d"
    if [ "$bad" -eq 0 ]; then ok_check "make compiler"
    else fail_check "make compiler"; fi
}


# ---- 16. gm core / watch / symbols (production/tools/gmdbg.py) ---------
check_gm_debug() {
    start_check "16. gm core / watch / symbols (real gdb on tiny crash programs)"
    local g="$ROOT/production/tools/gmdbg.py"
    if ! have gdb || ! have gcc || ! have python3; then
        skip_check "gm debug tools" "needs gdb, gcc, python3"
        return 0
    fi
    if ! gdb -nx -batch -ex 'python print(1)' 2>&1 | grep -q '^1$'; then
        skip_check "gm debug tools" "gdb has no Python"
        return 0
    fi
    local d bad=0 out watch_skipped=""
    d=$(mktemp -d)
    cat > "$d/t.c" <<'EOF'
struct S { long a, b; };
volatile long victim;
__attribute__((noinline)) void stomp(void) { victim = 42; }
__attribute__((noinline)) long deref(struct S *s) { return s->b; }
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) return (int)deref(0);
    stomp();
    return 0;
}
EOF
    gcc -g -O0 -Wl,--build-id -o "$d/t" "$d/t.c"
    export XDG_CACHE_HOME="$d/cache"
    gdb -nx -batch -ex run -ex "generate-core-file $d/t.core" --args "$d/t" crash >/dev/null 2>&1
    out=$(python3 "$g" core "$d/t.core" --exe "$d/t" 2>&1)
    case "$out" in
        *"embedded Python is unusable"*)
            skip_check "gm debug tools" "gdb's embedded Python is unusable here"
            echo "$out" | sed 's/^/    /'
            ci_notice "gm debug tools" "SKIPPED: $out"
            unset XDG_CACHE_HOME
            rm -rf "$d"
            return 0 ;;
    esac
    case "$out" in
        *"NULL pointer dereference (field offset 0x8)"*"deref"*) ;;
        *) echo "  core: missing NULL-deref analysis:"; echo "$out" | sed 's/^/    /'; bad=$((bad+1)) ;;
    esac
    out=$(python3 "$g" watch --sym victim --at main -n 1 -- "$d/t" 2>&1)
    case "$out" in
        *"refuses hardware watchpoints"*|*"no hardware watchpoint"*)
            echo "  (watch leg skipped: no hardware watchpoints here)"
            watch_skipped="(watch skipped: no hardware watchpoints) " ;;
        *"write #1"*"-> 0x000000000000002a"*"stomp"*) ;;
        *) echo "  watch: missing the writer:"; echo "$out" | sed 's/^/    /'; bad=$((bad+1)) ;;
    esac
    cp "$d/t" "$d/t.full"
    cp "$d/t" "$d/t.strip"
    strip --strip-debug "$d/t.strip"
    if python3 "$g" symbols find "$d/t.strip" >/dev/null 2>&1; then
        echo "  symbols: a stripped binary must be MISSING before 'add'"; bad=$((bad+1))
    fi
    if ! python3 "$g" symbols add "$d/t.full" >/dev/null \
        || ! python3 "$g" symbols find "$d/t.strip" >/dev/null; then
        echo "  symbols: add -> find round trip failed"; bad=$((bad+1))
    fi
    unset XDG_CACHE_HOME
    rm -rf "$d"
    if [ "$bad" -eq 0 ]; then
        ok_check "gm debug tools"
        ci_notice "gm debug tools" "ran: core + ${watch_skipped:-watch + }symbols; $(gdb --version | head -1)"
    else
        fail_check "gm debug tools"
        ci_error "gm debug tools" "$out"
    fi
}


# ---- 17. gm build regressions, in a scratch copy of the tree ------------
# Each leg pins a bug that once passed silently (docs/1-USER_GUIDE.md 10).
check_make_regress() {
    start_check "17. gm build regressions (shadowed target, sub-dir sources, quoting, clean, jq, tool gating, project flags, rpm yaml, reproducible paths, show, generated headers, no-op cost, parallel fresh build, sibling layout, graph loading, scan without PyYAML, no find, changes through generated files, pkg version, make -n on a variant never built, make -q / -e / -f)"
    if ! have make || ! have gcc; then
        skip_check "make regressions" "needs make and gcc"
        return 0
    fi
    local d bad=0 out arch exe
    _gm() { GM_TREE='' make "$@"; }
    d=$(mktemp -d)
    tar --exclude=./build --exclude=./.git --exclude=./note --exclude=./backup -C "$ROOT" -cf - . \
        | tar -xf - -C "$d"
    arch=rhlinux
    exe="$d/build/exec/$arch/debug"
    _leg() { echo "  $1"; bad=$((bad+1)); }

    # P: only a goal that builds targets loads the dependency graph (graph.mk): a goal that
    #    builds none must not scan the tree first.  `make prereq` on a new machine runs before
    #    the Python modules the pkg.yaml scan needs are installed.
    local g
    for g in help list -n\ prereq clean; do
        # shellcheck disable=SC2086  # `-n prereq` is two words on purpose
        out=$(cd "$d" && _gm -s $g 2>&1)
        case "$out" in *"DEPS    scanning"*) _leg "P: 'make $g' scanned the dependency graph" ;; esac
    done
    [ ! -e "$d/build/depend.mk" ] || _leg "P: a goal that builds no target wrote depend.mk"
    rm -rf "$d/build"
    out=$(cd "$d" && _gm -s libtmcore 2>&1)
    case "$out" in *"DEPS    scanning"*) ;; *) _leg "P: 'make libtmcore' did not load the dependency graph" ;; esac
    rm -rf "$d/build"

    # Q: `make` before `make prereq`: without PyYAML the scan stops with the hint and keeps no
    #    depend.mk (it used to record the yaml pkgs with no files, so a later -j build packaged
    #    files before they existed); once PyYAML is there the next build rescans in full.
    if python3 -c 'import yaml, jsonschema' 2>/dev/null; then
        mkdir -p "$d/.noyaml" && printf 'import sys\nsys.modules["yaml"] = None\n' > "$d/.noyaml/sitecustomize.py"
        out=$(cd "$d" && PYTHONPATH="$d/.noyaml" _gm -s libtmcore 2>&1)
        case "$out" in *"needs PyYAML + jsonschema"*) ;; *) _leg "Q: a scan without PyYAML did not stop with the install hint" ;; esac
        [ ! -e "$d/build/depend.mk" ] || _leg "Q: a failed scan left depend.mk behind"
        (cd "$d" && _gm -s libtmcore >/dev/null 2>&1)
        grep -q '^pkg-tmd:.*tmd' "$d/build/depend.mk" 2>/dev/null \
            || _leg "Q: after PyYAML is installed the scan did not record pkg-tmd's edges"
        rm -rf "$d/.noyaml" "$d/build"
    fi

    # R: no find (minimal Rocky 8 images): discovery saw an empty tree and `make` built nothing,
    #    successfully.  It must stop and name the package instead.
    local nofind="$d/.nofind" p f path_dirs
    mkdir -p "$nofind"
    IFS=: read -ra path_dirs <<< "$PATH"
    for p in "${path_dirs[@]}"; do
        for f in "$p"/*; do
            [ -x "$f" ] && [ "${f##*/}" != find ] && ln -s "$f" "$nofind/" 2>/dev/null
        done
    done
    out=$(cd "$d" && PATH="$nofind" _gm -s 2>&1)
    case "$out" in *"find not found"*"findutils"*) ;; *) _leg "R: make without find did not stop: $out" ;; esac
    rm -rf "$nofind" "$d/build"

    (
        cd "$d" || exit 1
        # A: app/ next to app/app.mk (a same-named directory used to turn `make app` into a no-op),
        #    sources in sub-directories, two sources with one basename, quoted defines.
        mkdir -p app/sub app/other
        printf 'int sub_fn() { return 3; }\n'   > app/sub/util.cxx
        printf 'int other_fn() { return 4; }\n' > app/other/util.cxx
        cat > app/main.cxx <<'EOF'
#include <cstdio>
int sub_fn();
int other_fn();
int main() { std::printf("%s|%s|%s|%d|%d\n", VER, NAME, SPACED, sub_fn(), other_fn()); return 0; }
EOF
        cat > app/app.mk <<'EOF'
CXXSOURCE += main.cxx sub/util.cxx other/util.cxx
CCFLAGS += -DVER='"1.2"' -DNAME=\"it\'s\" -DSPACED='"a b"'
EOF
    ) || bad=$((bad+1))
    out=$(cd "$d" && _gm app 2>&1)
    if [ "$("$exe/app" 2>/dev/null)" != "1.2|it's|a b|3|4" ]; then
        _leg "A: app (same-named dir, sub-dir sources, quoted defines) did not build / run right:"
        echo "$out" | tail -5 | sed 's/^/      /'
    fi
    if have jq; then
        local frag
        frag=$(find "$d/build/app" -name main.cc.json | head -1)
        if [ -z "$frag" ] || ! jq -e . "$frag" >/dev/null 2>&1 \
            || ! jq -r .command "$frag" | grep -qF -- "-DVER='\"1.2\"'" \
            || ! jq -r .command "$frag" | grep -qF -- "-DSPACED='\"a b\"'"; then
            _leg "A: compile_commands fragment lost the quoting of -D values: ${frag:-<none>}"
        fi
    fi
    (cd "$d" && _gm app SUB_TARGET=clean >/dev/null 2>&1)
    if [ -n "$(find "$d/build/app" -name '*.o' 2>/dev/null)" ]; then
        _leg "A: clean left objects of sub-directory sources behind"
    fi

    # B: cleaning one target must not clean what it depends on.
    (cd "$d" && _gm tmctl >/dev/null 2>&1; _gm tmctl SUB_TARGET=clean >/dev/null 2>&1)
    if ! ls "$d"/build/lib/"$arch"/debug/libtmcore.* >/dev/null 2>&1; then
        _leg "B: 'make tmctl SUB_TARGET=clean' also cleaned its dependency libtmcore"
    fi

    # B2: which sub-goals skip the dependency graph is the SUB_TARGET_ALONE list, not "any
    #     SUB_TARGET": with the list empty the graph is loaded and clean follows the edges.
    (cd "$d" && _gm tmctl SUB_TARGET=clean SUB_TARGET_ALONE= >/dev/null 2>&1)
    if ls "$d"/build/lib/"$arch"/debug/libtmcore.* >/dev/null 2>&1; then
        _leg "B: a sub-goal outside SUB_TARGET_ALONE did not get the dependency graph"
    fi

    # C: jq is optional (a compile used to fail after the compiler had succeeded).
    local nojq="$d/.nojq" f
    mkdir -p "$nojq"
    for f in /usr/bin/* /bin/*; do
        [ "${f##*/}" = jq ] || ln -sf "$f" "$nojq/${f##*/}" 2>/dev/null
    done
    out=$(cd "$d" && PATH="$nojq" _gm CCACHE_ENABLE=no libtmcore SUB_TARGET=clean 2>&1; \
          PATH="$nojq" _gm CCACHE_ENABLE=no libtmcore 2>&1)
    if ! ls "$d"/build/lib/"$arch"/debug/libtmcore.* >/dev/null 2>&1; then
        _leg "C: libtmcore did not build without jq:"
        echo "$out" | tail -4 | sed 's/^/      /'
    fi

    # D: a missing go / javac leaves those targets out of the target set (one place, so nothing
    #    downstream filters); pkg stays (libs need its header) and only skips its rpm step.
    out=$(cd "$d" && printf 'q:\n\t@echo SKIPPED=$(_GM_NO_GO) $(_GM_NO_JAVA)\n\t@echo ALL=$(TARGET_ALL)\n' \
          | _gm -f Makefile -f - GO=/nonexistent/go JAVAC=/nonexistent/javac q 2>&1)
    case "$out" in
        *"SKIPPED="*tmexport*tmview*) ;;
        *) _leg "D: missing go / javac are not detected: $out" ;;
    esac
    case "$out" in
        *"ALL="*"tmexport"*|*"ALL="*"tmapi"*) _leg "D: skipped targets are still in TARGET_ALL: $out" ;;
        *"ALL="*"pkg-tm-tools"*) ;;
        *) _leg "D: pkg targets must stay in TARGET_ALL: $out" ;;
    esac
    out=$(cd "$d" && printf 'q:\n\t@echo SKIPPED=$(_GM_NO_GO)$(_GM_NO_JAVA)\n' | _gm -f Makefile -f - q 2>&1)
    if have go && have javac && have jar && [ "$(echo "$out" | tail -1)" != "SKIPPED=" ]; then
        _leg "D: targets skipped although every toolchain is present: $out"
    fi
    out=$(cd "$d" && printf 'q:\n\t@:\n' | _gm -p -f Makefile -f - GO=/nonexistent/go q 2>/dev/null | grep -m1 '^all:')
    case "$out" in *_skip_go*) ;; *) _leg "D: make all does not report the skipped go targets: $out" ;; esac
    if have javac && have jar; then
        case "$out" in *_skip_java*) _leg "D: java reported as skipped although javac/jar are present: $out" ;; esac
    fi
    out=$(cd "$d" && _gm GO=/nonexistent/go _skip_go 2>&1)
    case "$out" in *"SKIP    "*tmexport*"(go not found)"*) ;; *) _leg "D: SKIP line for go is wrong: $out" ;; esac
    out=$(cd "$d" && _gm GO=/nonexistent/go tmexport 2>&1)
    case "$out" in *"not built here"*) ;; *) _leg "D: asking for a skipped target by name gives no clear error: $out" ;; esac
    out=$(cd "$d" && _gm RPMBUILD=/nonexistent/rpmbuild pkg-tm-tools 2>&1)
    case "$out" in *"SKIP"*"rpmbuild not found"*) ;; *) _leg "D: pkg without rpmbuild does not say SKIP: $out" ;; esac

    # E: an rpmbuild failure shows the log tail.
    printf '#!/bin/sh\necho "error: gm-precheck fake rpmbuild failure" >&2\nexit 1\n' > "$d/.badrpm"
    chmod +x "$d/.badrpm"
    out=$(cd "$d" && _gm RPMBUILD="$d/.badrpm" pkg-tm-tools 2>&1)
    if ! echo "$out" | grep -q 'gm-precheck fake rpmbuild failure'; then
        _leg "E: rpmbuild failure did not print the log tail"
    fi

    # G: project-wide flags set in the top-level Makefile reach every target.
    cp "$d/Makefile" "$d/Makefile.orig"
    sed -i '1i WARN_LEVEL := lax\nPROJECT_CPPFLAGS += -DFROM_TOP_LEVEL\nPROJECT_CCFLAGS += -DCXX_ONLY' "$d/Makefile"
    (cd "$d" && _gm libtmcore SUB_TARGET=clean >/dev/null 2>&1; _gm libtmstats SUB_TARGET=clean >/dev/null 2>&1)
    out=$(cd "$d" && _gm V=1 libtmstats 2>&1)
    cp "$d/Makefile.orig" "$d/Makefile"
    if ! echo "$out" | grep -E ' -c [^ ]*summary\.cxx' | grep -q -- '-DFROM_TOP_LEVEL.*-DCXX_ONLY' \
        || ! echo "$out" | grep -E ' -c [^ ]*ring\.c' | grep -q -- '-DFROM_TOP_LEVEL' \
        || echo "$out" | grep -E ' -c [^ ]*ring\.c' | grep -q -- '-DCXX_ONLY' \
        || echo "$out" | grep -E ' -c [^ ]*\.(c|cxx) ' | grep -q -- '-Werror'; then
        _leg "G: PROJECT_* flags / WARN_LEVEL from the top-level Makefile did not reach the compile lines"
    fi

    # N: sub-make arguments.  A variant axis set in the top-level Makefile reaches the targets
    #    (a top-level COVERAGE used to name a -cov build dir the sub-make never made); a vendor's
    #    own make does not get gm's BUILD_DIR / TYPE / CC; the DRY_RUN vars file is not
    #    rewritten when nothing changed.
    sed -i '1i COVERAGE := 1' "$d/Makefile"
    out=$(cd "$d" && _gm libtmcore 2>&1)
    cp "$d/Makefile.orig" "$d/Makefile"
    if [ -z "$(find "$d/build/example/core/$arch/debug-cov" -name '*.gcno' 2>/dev/null)" ]; then
        _leg "N: COVERAGE from the top-level Makefile did not reach libtmcore:"
        echo "$out" | tail -3 | sed 's/^/      /'
    fi
    cp "$d/third_party/loadgen/vendor/Makefile" "$d/vendor.mk.orig"
    printf '\n$(info VENDOR-SEES [$(BUILD_DIR)|$(TYPE)|$(PROJ_TOP)|$(C_PATH)] CC=$(CC) $(origin CC))\n' \
        >> "$d/third_party/loadgen/vendor/Makefile"
    out=$(cd "$d" && _gm loadgen 2>&1 | grep VENDOR-SEES)
    cp "$d/vendor.mk.orig" "$d/third_party/loadgen/vendor/Makefile"
    case "$out" in *"VENDOR-SEES [|||] CC=/"*" environment"*) ;; *) _leg "N: the vendor's make sees gm's sub-make variables, or not gm's compiler as CC: $out" ;; esac
    local m1 m2
    (cd "$d" && _gm -s deps >/dev/null 2>&1); m1=$(stat -c %Y "$d/build/.dry-run-vars.mk" 2>/dev/null)
    touch -d '@1' "$d/build/.dry-run-vars.mk" 2>/dev/null; m1=$(stat -c %Y "$d/build/.dry-run-vars.mk" 2>/dev/null)
    (cd "$d" && _gm -s deps >/dev/null 2>&1); m2=$(stat -c %Y "$d/build/.dry-run-vars.mk" 2>/dev/null)
    if [ -z "$m1" ] || [ "$m1" != "$m2" ]; then
        _leg "N: .dry-run-vars.mk is rewritten although the target list did not change"
    fi

    # O: a parallel build from an empty build tree (several makes rebuild the same cache files
    #    at once: a pkg's build and its <pkg>-header, the top level and the dependency scan).
    out=$(cd "$d" && _gm -s distclean >/dev/null 2>&1; _gm -j8 2>&1)
    if [ $? -ne 0 ] || echo "$out" | grep -qE 'cannot stat|Deleting file'; then
        _leg "O: make -j8 from an empty build tree failed:"
        echo "$out" | grep -E 'cannot stat|Deleting file|Error' | head -5 | sed 's/^/      /'
    fi

    # I: rpm YAML features (scriptlets, provides / conflicts, %config, %dir, %ghost).
    if have rpmbuild && have rpm; then
        local r
        out=$(cd "$d" && _gm pkg-tmd 2>&1)
        r=$(ls "$d"/build/pkg/"$arch"/debug/pkg-tmd-[0-9]*.rpm 2>/dev/null | head -1)
        if [ -z "$r" ] \
            || ! rpm -qp --scripts "$r" | grep -q 'pkg-tmd installed under' \
            || ! rpm -qp --conflicts "$r" | grep -qx 'tmd-legacy' \
            || ! rpm -qp --provides "$r" | grep -qx 'telemetry-daemon = 1.4' \
            || ! rpm -qpc "$r" | grep -qx '/opt/gm/config/tmd.conf' \
            || ! rpm -qpl "$r" | grep -qx '/var/lib/tmd' \
            || ! rpm -qpl "$r" | grep -qx '/var/run/tmd.pid'; then
            _leg "I: pkg-tmd's rpm lacks the yaml features (scripts / provides / conflicts / config / dirs / ghosts):"
            echo "$out" | tail -3 | sed 's/^/      /'
        fi
    fi

    # H: the same sources in another directory give the same binaries (and rpm).
    local d2 got want_sums=''
    d2=$(mktemp -d)/some/deeper/path/gm-copy
    mkdir -p "$d2"
    tar --exclude=./build --exclude=./.git --exclude=./note --exclude=./backup -C "$ROOT" -cf - . \
        | tar -xf - -C "$d2"
    for f in "$d" "$d2"; do
        # lib and pkg goals may not share one make invocation: two runs
        (cd "$f" && _gm distclean >/dev/null 2>&1; export SOURCE_DATE_EPOCH=1700000000 BUILD_HOST=gm-precheck
         _gm CCACHE_ENABLE=no tmd libtmstats >/dev/null 2>&1
         if have rpmbuild; then _gm CCACHE_ENABLE=no pkg-tmd >/dev/null 2>&1; fi)
        got=$(cd "$f/build" && sha256sum exec/"$arch"/debug/tmd lib/"$arch"/debug/libtmstats.so \
              lib/"$arch"/debug/libtmcore.a lib/"$arch"/debug/libminijson_file.so \
              pkg/"$arch"/debug/pkg-tmd-[0-9]*.rpm 2>/dev/null | cut -d' ' -f1 | tr '\n' ' ')
        [ "$f" = "$d" ] && want_sums=$got
    done
    if [ -z "$want_sums" ] || [ "$want_sums" != "$got" ]; then
        _leg "H: builds in two directories differ: [$want_sums] vs [$got]"
    fi
    rm -rf "${d2%%/some/*}"

    # K: `make show` lists every discovered target, show-<name> its derived edges and type facts,
    #    show-<type> the targets of a type; target names that clash with gm's own goals are refused.
    local all shown
    all=$(cd "$d" && _gm -s list 2>/dev/null | sort)
    shown=$(cd "$d" && _gm -s show 2>/dev/null | awk 'NR > 1 && NF == 0 { exit } NR > 1 { print $1 }' | sort)
    if [ -z "$all" ] || [ "$all" != "$shown" ]; then
        _leg "K: make show does not list exactly the discovered targets"
    fi
    out=$(cd "$d" && _gm -s show-tmd 2>&1)
    case "$out" in
        *"depends on  libtmcore libtmalarms libtmstats libini libminijson pkg-tmd (component.h)"*"used by     pkg-tmd"*"output      build/exec/$arch/debug/tmd"*) ;;
        *) _leg "K: show-tmd lacks its derived edges or its exe facts: $out" ;;
    esac
    out=$(cd "$d" && _gm -s show-lib 2>&1)
    if ! echo "$out" | grep -Eq '^libtmcore +example/core +build/lib/[^ ]+/libtmcore\.a +static '; then
        _leg "K: show-lib does not report libtmcore as a static lib: $out"
    fi

    mkdir -p "$d/clash" && printf 'CXXSOURCE += x.cxx\n' > "$d/clash/show.mk"
    out=$(cd "$d" && _gm -s list 2>&1)
    case "$out" in *"clash with gm's own goals"*) ;; *) _leg "K: a target named like a gm goal (show) is not refused: $out" ;; esac
    rm -rf "$d/clash"

    # M: inputs are declared, not searched: generated headers are the HEADER_GEN templates only
    #    (a stray .h.in is left alone, a missing listed one stops the build); a stray .java does
    #    not change a target's type, a java target needs JAVASOURCE.
    printf '#define STRAY 1\n' > "$d/example/core/include/stray.h.in"
    (cd "$d" && _gm -s libtmcore >/dev/null 2>&1)
    if [ ! -f "$d/build/example/core/$arch/debug/include/tm_build.h" ]; then
        _leg "M: the declared HEADER_GEN template was not generated"
    fi
    if [ -n "$(find "$d/build/example/core" -name stray.h 2>/dev/null)" ]; then
        _leg "M: an undeclared .h.in was generated"
    fi
    rm -f "$d/example/core/include/stray.h.in"
    out=$(cd "$d" && _gm -s libtmcore HEADER_GEN=include/nope.h.in 2>&1)
    case "$out" in *"HEADER_GEN file(s) not found: include/nope.h.in"*) ;; *) _leg "M: a missing HEADER_GEN file gives no clear error: $out" ;; esac
    # java: the type comes from the .java.mk suffix, the sources from JAVASOURCE.
    printf 'class Stray {}\n' > "$d/example/cli/Stray.java"
    out=$(cd "$d" && _gm -s show 2>&1 | awk '$1 == "tmctl" { print $2 }')
    [ "$out" = exe ] || _leg "M: a stray .java turned tmctl into a '$out' target"
    rm -f "$d/example/cli/Stray.java"
    out=$(cd "$d" && _gm -s tmapi JAVASOURCE= 2>&1)
    case "$out" in *"JAVASOURCE is empty"*) ;; *) _leg "M: a java target without JAVASOURCE gives no clear error: $out" ;; esac

    # L: a no-op build starts no python and no rpm (their results are cached / probed once).
    local shim="$d/.shim" tool
    mkdir -p "$shim"
    for tool in python3 rpm; do
        if have "$tool"; then
            printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexec %s "$@"\n' \
                "$tool" "$shim" "$(command -v "$tool")" > "$shim/$tool"
            chmod +x "$shim/$tool"
        fi
    done
    (cd "$d" && _gm -s tmd >/dev/null 2>&1)
    : > "$shim/calls"
    (cd "$d" && PATH="$shim:$PATH" _gm -s tmd >/dev/null 2>&1)
    if [ -s "$shim/calls" ]; then
        _leg "L: a no-op build still starts: $(sort "$shim/calls" | uniq -c | tr '\n' ';')"
    fi
    # ...and a sub-make's command line does not grow with the tree (TARGET_ALL / GM_SYS_LIBS go
    # through $(GM_OUT)/.dry-run-vars.mk).
    if (cd "$d" && _gm -n tmd LDLIB_CHECK=1 2>/dev/null) | grep -Eq "(TARGET_ALL|GM_SYS_LIBS)="; then
        _leg "L: the target list is on a sub-make command line again"
    fi
    # ...nor carries what another target type needs (a C sub-make gets no go / java / rpm probe).
    if (cd "$d" && _gm -n tmd 2>/dev/null) | grep -E "make .*-C [^ ]*/example/daemon " \
        | grep -Eq "_GM_(GO|JAVAC|JAR|RPMBUILD|RPM_DIST|UNAME_M)="; then
        _leg "L: a C sub-make is handed go / java / rpm probes"
    fi

    # S: `make changes` follows a generated file back to its input (pkg.yaml -> component.h and
    #    alarms.* -> what compiles them) and a cgo target to the C library it links.
    if have jq; then
        local goals=tmd
        have go && goals="tmd tmcrc"
        # shellcheck disable=SC2086  # two goals on purpose
        (cd "$d" && _gm -s DEP_TREE=yes $goals >/dev/null 2>&1)
        out=$(cd "$d" && _gm -s changes CHANGES=example/daemon/deploy/pkg.yaml 2>&1 | tr -d ' \n')
        case "$out" in *'"exes":['*'"tmd"'*) ;; *) _leg "S: make changes <pkg.yaml> misses the exe that includes its component.h: $out" ;; esac
        out=$(cd "$d" && python3 production/make/scripts/dep_query.py --build-dir build --proj-top . \
              changes --format files example/daemon/deploy/pkg.yaml 2>&1)
        case "$out" in *"gen	"*"/pkg-tmd/alarms.cxx"*) ;; *) _leg "S: the graph does not know alarms.cxx is generated from pkg.yaml: $out" ;; esac
        if have go; then
            out=$(cd "$d" && _gm -s changes CHANGES=example/core/src/ring.c 2>&1 | tr -d ' \n')
            case "$out" in *'"tmcrc"'*) ;; *) _leg "S: make changes <C source> misses the cgo target linking its library: $out" ;; esac
        fi
    fi

    # T: a new PKG_VERSION in a pkg's .mk reaches the version macros of what the pkg ships (the
    #    generated component.h used to depend on pkg.yaml alone).
    cp "$d/example/daemon/deploy/pkg-tmd.mk" "$d/pkg-tmd.mk.orig"
    sed -i 's/^PKG_VERSION := .*/PKG_VERSION := 9.9.9/' "$d/example/daemon/deploy/pkg-tmd.mk"
    (cd "$d" && _gm -s tmd >/dev/null 2>&1)
    case "$("$exe/tmd" --version 2>/dev/null | head -1)" in
        "tmd 9.9.9-"*) ;;
        *) _leg "T: PKG_VERSION changed in pkg-tmd.mk, tmd still reports: $("$exe/tmd" --version 2>&1 | head -1)" ;;
    esac
    cp "$d/pkg-tmd.mk.orig" "$d/example/daemon/deploy/pkg-tmd.mk"

    # U: `make -n` on a variant never built: the in-tree libs, component.h, jars and packaged
    #    artefacts other sub-makes would make are not on disk ("No rule to make target '-lgtest'").
    #    GM_OUT inside the tree on purpose: discovery must not take the .mk files gm writes there
    #    (depend.mk, caches) for targets.
    out=$(cd "$d" && _gm -s GM_OUT="$d/.fresh-n" -Bn all 2>&1) \
        || _leg "U: make -Bn all on a variant never built failed: $(grep -m1 -E 'No rule|\*\*\*' <<<"$out")"
    case "$out" in *"-o $d/.fresh-n/"*"/test-asan "*) ;; *) _leg "U: make -Bn all did not print the link of test-asan" ;; esac
    if have rpmbuild; then
        case "$out" in *"rpmbuild "*"pkg-tm-tools.spec"*) ;; *) _leg "U: make -Bn all did not print the rpmbuild of pkg-tm-tools" ;; esac
    fi
    rm -rf "$d/.fresh-n"

    # V: make's own options.  -q answers through the target makes (compile_commands, whose
    #    targets are phony, used to make it 1 on an up-to-date tree); -e is refused (the knobs in
    #    the environment would beat every .mk); -f from another directory says what is wrong.
    (cd "$d" && _gm -s -j8 all >/dev/null 2>&1)
    (cd "$d" && _gm -s -q all >/dev/null 2>&1) || _leg "V: make -q calls an up-to-date tree out of date"
    touch "$d/example/core/src/ring.c"
    local rc=0
    (cd "$d" && _gm -s -q tmd >/dev/null 2>&1) || rc=$?
    [ "$rc" = 1 ] || _leg "V: make -q tmd answers $rc, not 1, after ring.c changed"
    out=$(cd "$d" && _gm -e libtmcore 2>&1)
    case "$out" in *"does not support make -e"*) ;; *) _leg "V: make -e is not refused: $out" ;; esac
    out=$(cd / && _gm -f "$d/Makefile" libtmcore 2>&1)
    case "$out" in *"is not a gm tree"*) ;; *) _leg "V: make -f from another directory gives no clear error: $out" ;; esac

    # J: gm checked out next to the project repo (SINGLE_REPO=N): make runs in the gm checkout,
    #    PROJ_TOP is the directory holding both, gm's own examples are not project targets.
    local w
    w=$(mktemp -d)
    mkdir -p "$w/gm" "$w/proj/app"
    tar --exclude=./build --exclude=./.git --exclude=./note --exclude=./backup -C "$ROOT" -cf - . \
        | tar -xf - -C "$w/gm"
    printf 'CXXSOURCE += hello.cxx\n' > "$w/proj/app/hello.mk"
    printf '#include <cstdio>\nint main() { std::puts("sibling"); return 0; }\n' > "$w/proj/app/hello.cxx"
    out=$(cd "$w/gm" && SINGLE_REPO=N _gm list 2>&1)
    case "$out" in
        *hello*) ;;
        *) _leg "J: SINGLE_REPO=N does not find the project next to gm: $out" ;;
    esac
    case " $(echo "$out" | tr '\n' ' ') " in
        *" tmd "*) _leg "J: SINGLE_REPO=N lists gm's own examples as project targets" ;;
    esac
    local dt=''
    have jq && dt=DEP_TREE=yes
    out=$(cd "$w/gm" && SINGLE_REPO=N _gm hello ${dt:+"$dt"} 2>&1)
    if [ "$("$w/build/exec/$arch/debug/hello" 2>/dev/null)" != "sibling" ]; then
        _leg "J: SINGLE_REPO=N: hello did not build into <PROJ_TOP>/build:"
        echo "$out" | tail -5 | sed 's/^/      /'
    fi
    # The gm wrapper on PATH works from the project directory: with SINGLE_REPO=N it uses its own
    # checkout; a vendored tree above CWD still wins (and builds as Y); paths are CWD-relative.
    local g="$w/bin/gm"
    mkdir -p "$w/bin" && ln -s "$w/gm/production/tools/gm" "$g"
    out=$(cd "$w/proj/app" && GM_TREE='' SINGLE_REPO=N "$g" list 2>&1)
    case "$out" in *hello*) ;; *) _leg "J: gm (SINGLE_REPO=N) from the project dir: $out" ;; esac
    out=$(cd "$w/proj/app" && GM_TREE='' "$g" list 2>&1)
    case "$out" in *"export SINGLE_REPO=N"*) ;; *) _leg "J: gm outside any tree gives no SINGLE_REPO=N hint: $out" ;; esac
    out=$(cd "$d/example/cli" && GM_TREE='' SINGLE_REPO=N "$g" help 2>&1)
    case "$out" in *"$d  (SINGLE_REPO=Y)"*) ;; *) _leg "J: a vendored tree above CWD does not win over SINGLE_REPO=N: $(echo "$out" | sed -n 2p)" ;; esac
    if have jq; then
        out=$(cd "$w/proj/app" && GM_TREE='' SINGLE_REPO=N "$g" changes hello.cxx 2>&1)
        case "$out" in *'"exes": ["hello"]'*) ;; *) _leg "J: gm changes <CWD-relative own source> misses its exe: $out" ;; esac
    fi
    rm -rf "$w"

    rm -rf "$d"
    if [ "$bad" -eq 0 ]; then ok_check "make regressions"
    else
        fail_check "make regressions"
        ci_error "make regressions" "$bad leg(s) failed; see the log"
    fi
}


########################################################################
# Registry -- name -> function.  Adding a check = write `check_<foo>`
# and add its short name here.
#
# Ordered by cost (cheap first) so an early failure shortcuts the
# feedback loop when the caller passes `--only <name>`.
########################################################################
ALL_CHECKS=(
    yaml
    python_ast
    ruff
    mypy
    shellcheck
    actionlint
    jq
    make_smoke
    make_nested_gm
    make_dup_basename
    make_bad_ldlib
    make_idempotent
    make_cdb
    make_variants
    make_compiler
    gm_debug
    make_regress
)

run_one() {
    local name="$1"
    local fn="check_${name}"
    if declare -F "$fn" >/dev/null; then
        "$fn"
    else
        echo "precheck.sh: no such check '$name'.  Available:" >&2
        printf '  %s\n' "${ALL_CHECKS[@]}" >&2
        exit 2
    fi
}


########################################################################
# Driver
########################################################################
if [ "$LIST" = "1" ]; then
    echo "Registered checks:"
    printf '  %s\n' "${ALL_CHECKS[@]}"
    exit 0
fi

if [ -n "$ONLY" ]; then
    run_one "$ONLY"
else
    for c in "${ALL_CHECKS[@]}"; do
        run_one "$c"
    done
fi


########################################################################
# Report
########################################################################
echo
echo "==================================================="
if [ ${#FAIL[@]} -eq 0 ]; then
    printf '%s✅ every check passed%s (%d skipped)\n' \
        "$C_GREEN" "$C_RESET" "${#SKIP[@]}"
    exit 0
else
    printf '%s❌ %d check(s) failed:%s\n' "$C_RED" "${#FAIL[@]}" "$C_RESET"
    for f in "${FAIL[@]}"; do echo "  - $f"; done
    exit 1
fi
