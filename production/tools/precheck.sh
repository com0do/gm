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
    start_check "8. gm smoke (make list-targets sees every example target)"
    if ! have make; then
        skip_check "make list-targets" "no make"
        return 0
    fi
    local out
    # Clear GM_TREE so this smoke-test make does not trip the
    # gm-inside-gm guard when precheck was itself invoked from a gm
    # recipe (`make precheck`).
    # shellcheck disable=SC1007  # `VAR= cmd` is a command prefix, not assignment
    out=$(GM_TREE= make -s list-targets 2>/dev/null || true)
    if echo "$out" | grep -q -E 'libt1|t3|pkg-p1|j1|j2'; then
        ok_check "make list-targets"
    else
        echo "  got: $out"
        fail_check "make list-targets"
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
    local orig=example/t1/libt1.mk dup=example/t3/libt1.mk
    if [ ! -f "$orig" ]; then
        skip_check "make dup-basename" "$orig missing"
        return 0
    fi
    cp "$orig" "$dup"
    local out
    # shellcheck disable=SC1007
    out=$(GM_TREE= make -n 2>&1 || true)
    rm -f "$dup"
    if echo "$out" | grep -q 'libt1 must be unique'; then
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
    local mk=example/t1/libt1.mk backup=/tmp/gm-precheck-libt1.mk.$$
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
    # shellcheck disable=SC1007
    if ! GM_TREE= make -s >/dev/null 2>&1; then
        fail_check "make idempotent"
        echo "  first make failed"
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
    # shellcheck disable=SC1007
    GM_TREE= make -s >/dev/null 2>&1 || {
        fail_check "make cdb"
        echo "  build failed"
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
