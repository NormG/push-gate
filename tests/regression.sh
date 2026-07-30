#!/usr/bin/env bash
# Regression tests for push-gate.
#
# Exercises the behaviors that have historically broken:
#   1. \t escaping  — tab-indented files must match a sync regex that uses \t
#   2. greedy-capture resilience — read_version() must strip stray
#      quote/comma/space even with an unanchored (.+) capture group
#   3. GATE_PASS_ON_EXIT_ONLY — a must-pass command that prints output on
#      success must still pass (judged by exit code only)
#
# Uses a throwaway temp repo; needs only bash + the gate script. No network.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    # $1 = description, $2 = 0 (expect pass) or 1 (expect fail)
    local desc="$1" expect="$2"
    if [[ "$expect" == "0" ]]; then
        if bash "$GATE" check "$TMP" >/dev/null 2>&1; then
            echo "  ✓  $desc"
            pass=$((pass+1))
        else
            echo "  ✗  $desc  (gate check unexpectedly FAILED)"
            bash "$GATE" check "$TMP" 2>&1 | sed 's/^/      /'
            fail=$((fail+1))
        fi
    else
        if bash "$GATE" check "$TMP" >/dev/null 2>&1; then
            echo "  ✗  $desc  (gate check unexpectedly PASSED)"
            fail=$((fail+1))
        else
            echo "  ✓  $desc  (correctly FAILED)"
            pass=$((pass+1))
        fi
    fi
}

echo "── push-gate regression tests ──"

# ---------------------------------------------------------------------------
# Test 1: \t escaping — tab-indented sync target, regex uses \t
# ---------------------------------------------------------------------------
cat > "$TMP/ver.txt" <<'EOF'
VERSION=2.0.0
EOF
printf '\t"version": "2.0.0",\n' > "$TMP/manifest.txt"
cat > "$TMP/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "building..."   # prints output on success
exit 0
EOF
chmod +x "$TMP/build.sh"
cat > "$TMP/.gate.conf" <<'EOF'
GATE_VERSION_SOURCE="ver.txt"
GATE_VERSION_REGEX='^VERSION=([0-9]+\.[0-9]+\.[0-9]+)'
GATE_SYNC=(
    'manifest.txt|^\t"version": "{VERSION}",|\t"version": "{VERSION}",'
)
GATE_AUTO_FIX=()
GATE_MUST_PASS=(
    "bash build.sh"
)
GATE_PASS_ON_EXIT_ONLY=(
    "bash build.sh"
)
EOF
check "tab-indented sync matches via \\t + output-tolerant build passes" 0

# ---------------------------------------------------------------------------
# Test 2: greedy-capture resilience — loose (.+) regex must still extract cleanly
# ---------------------------------------------------------------------------
rm -rf "$TMP"; mkdir -p "$TMP"
printf 'version = "1.0.2",\n' > "$TMP/src.txt"
cat > "$TMP/.gate.conf" <<'EOF'
GATE_VERSION_SOURCE="src.txt"
GATE_VERSION_REGEX='^version = "(.+)"'
GATE_SYNC=()
GATE_AUTO_FIX=()
GATE_MUST_PASS=("true")
EOF
out="$(bash "$GATE" check "$TMP" 2>&1)"
extracted="$(echo "$out" | grep -oE 'Version: [0-9.]+' | awk '{print $2}')"
if [[ "$extracted" == "1.0.2" ]]; then
    echo "  ✓  greedy (.+) regex stripped to 1.0.2"
    pass=$((pass+1))
else
    echo "  ✗  greedy (.+) regex extracted '$extracted' (expected 1.0.2)"
    fail=$((fail+1))
fi

# ---------------------------------------------------------------------------
# Test 3: drift detection still works (negative case)
# ---------------------------------------------------------------------------
rm -rf "$TMP"; mkdir -p "$TMP"
printf 'VERSION=3.1.4\n' > "$TMP/ver.txt"
printf '\t"version": "9.9.9",\n' > "$TMP/manifest.txt"
cat > "$TMP/.gate.conf" <<'EOF'
GATE_VERSION_SOURCE="ver.txt"
GATE_VERSION_REGEX='^VERSION=([0-9]+\.[0-9]+\.[0-9]+)'
GATE_SYNC=(
    'manifest.txt|^\t"version": "{VERSION}",|\t"version": "{VERSION}",'
)
GATE_AUTO_FIX=()
GATE_MUST_PASS=("true")
EOF
check "out-of-sync version is detected (drift)" 1

# ---------------------------------------------------------------------------
echo "── results: $pass passed, $fail failed ──"
[[ "$fail" == "0" ]] && exit 0 || exit 1
