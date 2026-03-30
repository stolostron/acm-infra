#!/usr/bin/env bash
# Unit tests for pending-state.sh
# Run: bash test-pending-state.sh
# No external dependencies required (only jq)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Override PENDING_FILE to use a temp location
export PENDING_FILE="$TEST_DIR/pending-failures.json"

# Source the module under test
source "$SCRIPT_DIR/pending-state.sh"

# --- Test helpers ---

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local test_name="$1"
    local expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [[ "$expected_code" == "$actual_code" ]]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (expected exit=$expected_code, actual exit=$actual_code)"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
echo "=== Test 1: init_pending_state ==="
# ============================================================

rm -f "$PENDING_FILE"
init_pending_state
assert_eq "creates file" "true" "$([ -f "$PENDING_FILE" ] && echo true || echo false)"
assert_eq "file contains empty JSON object" "{}" "$(cat "$PENDING_FILE")"

# Test with corrupted file
echo "not json" > "$PENDING_FILE"
init_pending_state
assert_eq "reinitializes corrupted file" "{}" "$(cat "$PENDING_FILE")"

# ============================================================
echo ""
echo "=== Test 2: add_to_pending ==="
# ============================================================

init_pending_state
add_to_pending "console-acm-217" "acm-217" "push,ec"

assert_exit_code "component exists in state" 0 jq -e 'has("console-acm-217")' "$PENDING_FILE"
assert_eq "app is set" "acm-217" "$(jq -r '.["console-acm-217"].app' "$PENDING_FILE")"
assert_eq "retrigger_count is 0" "0" "$(jq -r '.["console-acm-217"].retrigger_count' "$PENDING_FILE")"
assert_eq "failed_dimensions set" "push,ec" "$(jq -r '.["console-acm-217"].failed_dimensions' "$PENDING_FILE")"
assert_exit_code "first_seen is set" 0 jq -e '.["console-acm-217"].first_seen != null' "$PENDING_FILE"
assert_exit_code "retrigger_time is set" 0 jq -e '.["console-acm-217"].retrigger_time != null' "$PENDING_FILE"

# ============================================================
echo ""
echo "=== Test 3: is_pending ==="
# ============================================================

assert_exit_code "console-acm-217 is pending" 0 is_pending "console-acm-217"
assert_exit_code "nonexistent-component is NOT pending" 1 is_pending "nonexistent-component"

# ============================================================
echo ""
echo "=== Test 4: get_retrigger_count ==="
# ============================================================

count=$(get_retrigger_count "console-acm-217")
assert_eq "initial retrigger_count is 0" "0" "$count"

count=$(get_retrigger_count "nonexistent-component")
assert_eq "nonexistent component returns 0" "0" "$count"

# ============================================================
echo ""
echo "=== Test 5: increment_retrigger ==="
# ============================================================

increment_retrigger "console-acm-217"
count=$(get_retrigger_count "console-acm-217")
assert_eq "retrigger_count after increment is 1" "1" "$count"

increment_retrigger "console-acm-217"
count=$(get_retrigger_count "console-acm-217")
assert_eq "retrigger_count after second increment is 2" "2" "$count"

# ============================================================
echo ""
echo "=== Test 6: is_ready_for_recheck (not enough time) ==="
# ============================================================

# Component was just added/retriggered — with default 60 min wait, not ready
export RETRIGGER_WAIT_MINUTES=60
# Re-add to reset retrigger_time to now
add_to_pending "fresh-component" "acm-217" "push"
assert_exit_code "just-added component is NOT ready (60min wait)" 1 is_ready_for_recheck "fresh-component"

# ============================================================
echo ""
echo "=== Test 7: is_ready_for_recheck (enough time) ==="
# ============================================================

export RETRIGGER_WAIT_MINUTES=0
assert_exit_code "component is ready with 0 wait" 0 is_ready_for_recheck "fresh-component"

# Manually set retrigger_time to 2 hours ago
two_hours_ago=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
if [[ -n "$two_hours_ago" ]]; then
    export RETRIGGER_WAIT_MINUTES=60
    tmp=$(mktemp)
    jq --arg c "fresh-component" --arg ts "$two_hours_ago" \
        '.[$c].retrigger_time = $ts' "$PENDING_FILE" > "$tmp" && mv "$tmp" "$PENDING_FILE"
    assert_exit_code "component 2h old is ready with 60min wait" 0 is_ready_for_recheck "fresh-component"
fi

# ============================================================
echo ""
echo "=== Test 8: is_confirmed_failure ==="
# ============================================================

export RETRIGGER_WAIT_MINUTES=0
export CONFIRMED_FAILURE_THRESHOLD=2

# fresh-component has retrigger_count=0 (never incremented from test 5: count was 2, but let's reset)
echo '{}' > "$PENDING_FILE"
add_to_pending "test-confirm" "acm-217" "push"

# retrigger_count=0, threshold=2 -> NOT confirmed
assert_exit_code "retrigger_count=0 < threshold=2 is NOT confirmed" 1 is_confirmed_failure "test-confirm"

# Increment to 1 -> still NOT confirmed
increment_retrigger "test-confirm"
assert_exit_code "retrigger_count=1 < threshold=2 is NOT confirmed" 1 is_confirmed_failure "test-confirm"

# Increment to 2 -> NOW confirmed (>= threshold)
increment_retrigger "test-confirm"
assert_exit_code "retrigger_count=2 >= threshold=2 is confirmed" 0 is_confirmed_failure "test-confirm"

# Test with threshold=3
export CONFIRMED_FAILURE_THRESHOLD=3
assert_exit_code "retrigger_count=2 < threshold=3 is NOT confirmed" 1 is_confirmed_failure "test-confirm"
increment_retrigger "test-confirm"
assert_exit_code "retrigger_count=3 >= threshold=3 is confirmed" 0 is_confirmed_failure "test-confirm"

# Not ready even with count >= threshold
export RETRIGGER_WAIT_MINUTES=9999
increment_retrigger "test-confirm"
assert_exit_code "count=4 >= threshold but not ready = NOT confirmed" 1 is_confirmed_failure "test-confirm"

# Reset for remaining tests
export CONFIRMED_FAILURE_THRESHOLD=2
export RETRIGGER_WAIT_MINUTES=0

# ============================================================
echo ""
echo "=== Test 9: remove_from_pending ==="
# ============================================================

# Set up fresh state for remove test
echo '{}' > "$PENDING_FILE"
add_to_pending "comp-a" "acm-217" "push"
add_to_pending "comp-b" "acm-217" "ec"
remove_from_pending "comp-a"
assert_exit_code "removed component is NOT pending" 1 is_pending "comp-a"
assert_exit_code "other component still pending" 0 is_pending "comp-b"

# ============================================================
echo ""
echo "=== Test 10: get_pending_components ==="
# ============================================================

# Add a second component
add_to_pending "search-acm-217" "acm-217" "hermetic"
components=$(get_pending_components)
component_count=$(echo "$components" | wc -l | tr -d ' ')
assert_eq "2 components in pending" "2" "$component_count"

# ============================================================
echo ""
echo "=== Test 11: cleanup_stale_pending ==="
# ============================================================

# Set first_seen to 72 hours ago for one component
export PENDING_STALE_HOURS=48
old_time=$(date -u -v-72H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "72 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
if [[ -n "$old_time" ]]; then
    tmp=$(mktemp)
    jq --arg c "search-acm-217" --arg ts "$old_time" \
        '.[$c].first_seen = $ts' "$PENDING_FILE" > "$tmp" && mv "$tmp" "$PENDING_FILE"

    cleanup_stale_pending 2>/dev/null
    assert_exit_code "stale component (72h) removed" 1 is_pending "search-acm-217"
    assert_exit_code "fresh component still pending" 0 is_pending "comp-b"
else
    echo "  SKIP: could not compute old timestamp on this platform"
fi

# ============================================================
echo ""
echo "=== Test 12: multiple operations integrity ==="
# ============================================================

echo '{}' > "$PENDING_FILE"
for i in comp-1 comp-2 comp-3 comp-4 comp-5; do
    add_to_pending "$i" "acm-217" "push"
done
assert_eq "5 components added" "5" "$(jq 'keys | length' "$PENDING_FILE")"

remove_from_pending "comp-3"
assert_eq "4 after removing comp-3" "4" "$(jq 'keys | length' "$PENDING_FILE")"

increment_retrigger "comp-1"
increment_retrigger "comp-1"
assert_eq "comp-1 retrigger_count=2" "2" "$(get_retrigger_count comp-1)"
assert_eq "comp-2 retrigger_count=0" "0" "$(get_retrigger_count comp-2)"

# Verify JSON is still valid
assert_eq "JSON still valid" "true" "$(jq empty "$PENDING_FILE" 2>/dev/null && echo true || echo false)"

# ============================================================
echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
