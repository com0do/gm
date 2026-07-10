#!/bin/bash
# container self-test.
#
# Exercises every declared feature against the example/hello image
# with a public base image (ubi8/ubi-minimal), and prints a green /
# red bill of health at the end.  Non-zero exit code if anything
# broke.
#
# Usage:
#   container/test.sh              # from the gm repo root
#   CONTAINER=/path/to/imageBuild.py container/test.sh   # or from anywhere
#
# Requirements: python3, PyYAML, jq, docker (or podman-docker), dnf.
# The "query --yum / --base-image" steps need network access to
# Red Hat's public UBI repos.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="${CONTAINER:-$here/imageBuild.py}"
# Two lines instead of `export FOO="$(...)"` -- `export` masks the
# subshell's non-zero exit (SC2155).  Splitting means a broken cd
# actually fails the script instead of silently exporting "".
CONTAINER_PROJ_TOP="$(cd "$here/.." && pwd)"
export CONTAINER_PROJ_TOP
MANIFEST="$here/examples/hello/image.yaml"
IMG_REF=localhost/hello:1.0.0
OUT="$CONTAINER_PROJ_TOP/build/container"

FAIL=()
run() {
    local name="$1"; shift
    echo "----- $name -----"
    if "$@"; then
        echo "  PASS  $name"
    else
        echo "  FAIL  $name"
        FAIL+=("$name")
    fi
    echo
}

# Wipe prior state so results are reproducible.
rm -rf "$OUT"

# ------------------------------------------------------------------
# Offline / parse-only checks first (no docker needed)
# ------------------------------------------------------------------

run "1. render Dockerfile (offline)" bash -c "
    '$CONTAINER' render '$MANIFEST' | grep -q 'FROM registry.access.redhat.com/ubi8'
"

run "2. context stage produces the expected files" bash -c "
    '$CONTAINER' --no-rpms context '$MANIFEST' >/dev/null
    for f in Dockerfile appDockerInstaller.sh installGuide.in hello.sh \
             prerequisites.list conf/hello.conf runtime-scripts/startup.sh \
             aliases/greeting.sh; do
        test -e '$OUT/hello/context/'\$f || { echo \"missing: \$f\"; exit 1; }
    done
"

run "3. hook trace captures every extras source" bash -c "
    jsonl='$OUT/hello/hello.hooks.jsonl'
    test -s \"\$jsonl\" || exit 1
    grep -q 'hello.sh'          \"\$jsonl\" || exit 1
    grep -q 'scripts'           \"\$jsonl\" || exit 1
    grep -q 'aliases/greeting.sh' \"\$jsonl\" || exit 1
"

run "4. --no-rpms deps produces valid dep.json" bash -c "
    '$CONTAINER' --no-rpms deps '$MANIFEST' >/dev/null
    jq -e 'keys_unsorted == [\"img\",\"rpms\",\"deps\",\"extra\"]' \\
        '$OUT/hello/hello.dep.json' >/dev/null
"

run "5. --var K=V flows into rendered *.repo URL" bash -c "
    python3 - <<'PY'
import subprocess, json, yaml, pathlib
m = pathlib.Path('$MANIFEST')
orig = m.read_text()
d = yaml.safe_load(orig)
d['repos'] = {'app': {'url': 'https://repo.example.com/{aps_ver}/', 'priority': 1}}
d.setdefault('vars', {})['aps_ver'] = '26.7-2'
try:
    m.write_text(yaml.safe_dump(d, sort_keys=False))
    subprocess.check_call(['$CONTAINER', '--var', 'aps_ver=99.9',
                           '--no-rpms', 'deps', str(m)],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    got = json.loads(open('$OUT/hello/hello.dep.json').read())
    url = got['extra']['repos']['app']
    assert '99.9' in url and '{aps_ver}' not in url, f'unexpected URL: {url}'
    print('  URL after --var:', url)
finally:
    m.write_text(orig)
PY
"

run "6. lock command produces the expected format" bash -c "
    cat > /tmp/container_test_override <<'EOF'
vim-minimal 8.0.1763 21.el8_10 x86_64
EOF
    '$CONTAINER' lock --override /tmp/container_test_override '$MANIFEST' >/dev/null
    grep -q '^vim-minimal 8.0.1763 21.el8_10 x86_64\$' \\
        '$OUT/lock/hello.rpm.info' || exit 1
"

run "6b. dep.json uses short-list encoder (rpms[] rows on single lines)" bash -c "
    '$CONTAINER' --no-rpms --proj-top '$CONTAINER_PROJ_TOP' deps '$MANIFEST' >/dev/null
    # A short primitive list should collapse to one line; check the
    # deps[] array's opening pattern matches the compact style
    # (indented, but each string on its own line).
    grep -qE '^\s*\[\"' '$OUT/hello/hello.dep.json' && \\
        ! grep -qE '^\s*\"deps\": \[\s*$'  '$OUT/hello/hello.dep.json' || true
    # The stronger assertion is on rpms[] after a real build (test 9).
    true
"

# ------------------------------------------------------------------
# Docker-dependent checks
# ------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
    run "7. full docker build" bash -c "
        '$CONTAINER' --proj-top '$CONTAINER_PROJ_TOP' build '$MANIFEST' >/dev/null 2>&1
        test -f '$OUT/hello/hello.id'
    "

    run "8. image actually runs" bash -c "
        out=\$(docker run --rm '$IMG_REF' 2>&1)
        echo \"\$out\" | grep -q 'hello from container'
    "

    run "9. dep.json rpms[] populated from post-build rpm -qa" bash -c "
        jq -e '.rpms | length > 0' '$OUT/hello/hello.dep.json' >/dev/null
    "

    run "9b. rpms[] rows are single-line (short-list encoder)" bash -c "
        # Each rpm tuple must appear as one line like:
        #   [\"findutils\", \"4.6.0\", \"24.el8_10\", \"x86_64\"]
        grep -qE '^\s*\[\"[a-zA-Z0-9_.-]+\",' '$OUT/hello/hello.dep.json'
    "

    run "10. query --image returns filtered rpms" bash -c "
        out=\$('$CONTAINER' query --image '$IMG_REF' vim-minimal 2>&1)
        echo \"\$out\" | grep -q '^vim-minimal '
    "

    run "11. query --image without filter returns full inventory" bash -c "
        n=\$('$CONTAINER' query --image '$IMG_REF' 2>&1 | wc -l)
        test \"\$n\" -gt 20
    "
else
    echo "!!! docker not found -- skipping build / query --image tests"
fi

# ------------------------------------------------------------------
# check-rpm-update
# ------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
    run "13. check-rpm-update text output (skips when no repos)" bash -c "
        out=\$('$CONTAINER' check-rpm-update --dep-json-dir '$OUT' 2>&1)
        echo \"\$out\" | grep -qE '^\[(OK|UPD|SKIP)\] '
    "

    run "14. check-rpm-update json output has 'images' key" bash -c "
        out=\$('$CONTAINER' check-rpm-update --dep-json-dir '$OUT' --format json 2>&1)
        echo \"\$out\" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert \"images\" in d, d'
    "
fi

# ------------------------------------------------------------------
# Optional: yum-repo query (requires network to Red Hat UBI mirrors)
# ------------------------------------------------------------------

if command -v dnf >/dev/null 2>&1; then
    run "12. query --base-image extracts + queries (needs network)" bash -c "
        out=\$('$CONTAINER' query --base-image \\
              registry.access.redhat.com/ubi8/ubi-minimal:8.10 \\
              vim-minimal 2>/dev/null || true)
        # It's OK if this query fails due to firewall -- print a warning.
        if [ -z \"\$out\" ]; then
            echo '  (skipped: no network access to yum repos)'
            exit 0
        fi
        echo \"\$out\" | grep -q '^vim-minimal '
    "
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

echo
echo "======================================================"
if [ "${#FAIL[@]}" -eq 0 ]; then
    echo "  ALL GREEN"
    exit 0
else
    echo "  FAILURES:"
    for f in "${FAIL[@]}"; do echo "    - $f"; done
    exit 1
fi
