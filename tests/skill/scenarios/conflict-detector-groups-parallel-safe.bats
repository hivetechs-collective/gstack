#!/usr/bin/env bats
# tests/skill/scenarios/conflict-detector-groups-parallel-safe.bats
#
# Scenario: pwt-conflict-detector groups task directives by file-overlap.
# Three synthetic directives:
#   A — touches shared/supervisor-protocol.md
#   B — also touches shared/supervisor-protocol.md
#   C — touches only docs/specs/standalone.md (disjoint)
# Expected groups: [[C], [A, B]] (or [[A, B], [C]] — outer order is unspecified;
# the assertion is that A+B are together and C is alone).
#
# Spec: docs/specs/task-conflict-detector.md
# Implementation: .claude/scripts/pwt-conflict-detector.sh
# Originating goal: PWT-RAM2 / RAM2 — safe parallel /plan-w-team spawning.

# Resolve repo root from any worktree path so this works under EnterWorktree.
DETECTOR_SCRIPT="${BATS_TEST_DIRNAME%/tests/skill/scenarios}/.claude/scripts/pwt-conflict-detector.sh"

setup() {
    SANDBOX=$(mktemp -d -t conflict-detector-e2e.XXXXXX)
    # Isolate registry — even though detector doesn't touch it, integration
    # paths might. Belt-and-braces.
    REG_TMP=$(mktemp -t conflict-e2e-reg.XXXXXX)
    export PWT_RAM_CLAIMS_REGISTRY="$REG_TMP"

    # Build three directives.
    cat > "$SANDBOX/A.md" <<'EOF'
# Task A
Edit shared/supervisor-protocol.md to add new POLLING LOOP entry.
EOF

    cat > "$SANDBOX/B.md" <<'EOF'
# Task B
Update shared/supervisor-protocol.md hard rules section.
EOF

    cat > "$SANDBOX/C.md" <<'EOF'
# Task C
Write docs/specs/standalone.md — pure documentation, no shared edits.
EOF
}

teardown() {
    rm -rf "$SANDBOX" "$REG_TMP"
}

# Helper: assert a substring is present in $output
assert_contains() {
    local needle="$1"
    if ! printf '%s' "$output" | grep -qF -- "$needle"; then
        echo "expected to find: $needle"
        echo "got: $output"
        return 1
    fi
}

assert_not_contains() {
    local needle="$1"
    if printf '%s' "$output" | grep -qF -- "$needle"; then
        echo "did not expect to find: $needle"
        echo "got: $output"
        return 1
    fi
}

@test "conflict-detector AC5: detector exists and is executable" {
    [ -x "$DETECTOR_SCRIPT" ]
}

@test "conflict-detector AC5: three directives (A+B share, C disjoint) group as expected" {
    run "$DETECTOR_SCRIPT" "$SANDBOX/A.md" "$SANDBOX/B.md" "$SANDBOX/C.md"
    [ "$status" -eq 0 ]
    # A and B must appear together in some group.
    assert_contains '["A", "B"]'
    # C must appear alone.
    assert_contains '["C"]'
    # C must NOT be grouped with A or B.
    assert_not_contains '"C", "A"'
    assert_not_contains '"C", "B"'
    assert_not_contains '"A", "B", "C"'
}

@test "conflict-detector AC5: reasons cite the shared file by name" {
    run "$DETECTOR_SCRIPT" "$SANDBOX/A.md" "$SANDBOX/B.md" "$SANDBOX/C.md"
    [ "$status" -eq 0 ]
    assert_contains 'shared file shared/supervisor-protocol.md with task B'
    assert_contains 'shared file shared/supervisor-protocol.md with task A'
    # C has no shared peers → empty reason list.
    assert_contains '"C": []'
}

@test "conflict-detector AC5: output is valid-shape JSON with required top-level keys" {
    run "$DETECTOR_SCRIPT" "$SANDBOX/A.md" "$SANDBOX/B.md" "$SANDBOX/C.md"
    [ "$status" -eq 0 ]
    assert_contains '"parallel_safe_groups"'
    assert_contains '"reasons"'
    assert_contains '"tasks_with_unknown_scope"'
    assert_contains '"skipped"'
}

@test "conflict-detector AC5: detector does NOT write to production claims registry" {
    PROD_REG="$HOME/.claude/state/pwt-ram-claims.jsonl"
    local before_size=""
    [ -f "$PROD_REG" ] && before_size=$(wc -c < "$PROD_REG")
    run "$DETECTOR_SCRIPT" "$SANDBOX/A.md" "$SANDBOX/B.md" "$SANDBOX/C.md"
    [ "$status" -eq 0 ]
    local after_size=""
    [ -f "$PROD_REG" ] && after_size=$(wc -c < "$PROD_REG")
    [ "$before_size" = "$after_size" ]
}

@test "conflict-detector AC5: invocation with no args returns empty advisory JSON, exit 0" {
    run "$DETECTOR_SCRIPT"
    [ "$status" -eq 0 ]
    assert_contains '"parallel_safe_groups": []'
}
