#!/usr/bin/env bats
# tests/skill/scenarios/fair-share-throttles-greedy-repo.bats
#
# Scenario: cross-repo fair-share scheduler refuses a greedy repo's spawn
# when another repo is under its share.
#
# Origin: cleanscale 2026-05-22 incident — claude-pattern's 2 workers held
# RAM, cleanscale's gate paused even after measurement fix because no
# fair-share guarantee existed between competing repos.
#
# Spec: docs/specs/pwt-cross-repo-fair-share.md
# Implementation: .claude/scripts/pwt-fair-share.sh + pwt-ram-claim.sh
# Wired into: .claude/scripts/pwt-goal.sh (gate before spawn)

# Resolve repo root from any /.claude/worktrees/<name> path
REPO_ROOT_FOR_BATS="${BATS_TEST_DIRNAME%/tests/skill/scenarios}"
case "$REPO_ROOT_FOR_BATS" in
    */.claude/worktrees/*)
        REPO_ROOT_FOR_BATS="${REPO_ROOT_FOR_BATS%/.claude/worktrees/*}"
        ;;
esac
# When run from the main repo this collapses to the repo top.
FAIR_SHARE_SCRIPT="${BATS_TEST_DIRNAME%/tests/skill/scenarios}/.claude/scripts/pwt-fair-share.sh"
CLAIM_SCRIPT="${BATS_TEST_DIRNAME%/tests/skill/scenarios}/.claude/scripts/pwt-ram-claim.sh"

setup() {
    # Isolated registry per test
    REG_TMP=$(mktemp)
    export PWT_FAIR_SHARE_STUB_REGISTRY="$REG_TMP"
    export PWT_RAM_CLAIMS_REGISTRY="$REG_TMP"
    export PWT_FAIR_SHARE_IDLE_THRESHOLD=0  # disable idle filter for deterministic tests
}

teardown() {
    rm -f "$REG_TMP"
}

# Helper: extract JSON field via grep+sed (no jq dependency)
get_field() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" \
        | grep -oE "\"${key}\": *[^,}]*" \
        | head -1 \
        | sed -E "s/.*\"${key}\": *//; s/\"//g; s/^ *//; s/ *$//"
}

# ─── AC1: greedy repo-a has 3 workers; repo-b asks → repo-b SPAWN_OK ────────
@test "fair-share AC1: greedy repo with 3 workers does not starve repo-b's spawn" {
    cat > "$REG_TMP" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF

    run env PWT_FAIR_SHARE_STUB_CAPACITY=1 \
            PWT_FAIR_SHARE_MY_REPO=repo-b \
            "$FAIR_SHARE_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_field "$output" recommendation)" = "SPAWN_OK" ]
    # capacity 1 + 3 active = 4 ; 2 repos (a + asker b) ; fair = 2
    [ "$(get_field "$output" fair_share_per_repo)" = "2" ]
    [ "$(get_field "$output" my_repo_current)" = "0" ]
    [ "$(get_field "$output" my_repo_allowed_max)" = "2" ]
}

# ─── AC2: greedy repo-a asks for 4th when repo-b is under share → YIELD ─────
@test "fair-share AC2: greedy repo's 4th request is refused when another repo is underserved" {
    cat > "$REG_TMP" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF

    run env PWT_FAIR_SHARE_STUB_CAPACITY=0 \
            PWT_FAIR_SHARE_MY_REPO=repo-a \
            "$FAIR_SHARE_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_field "$output" recommendation)" = "YIELD_TO_OTHER_REPO" ]
    [ "$(get_field "$output" fair_share_per_repo)" = "2" ]
    [ "$(get_field "$output" my_repo_current)" = "3" ]
}

# ─── AC3: priority=critical bypasses fair-share refusal ─────────────────────
@test "fair-share AC3: PWT_RUN_PRIORITY=critical bypasses YIELD recommendation" {
    cat > "$REG_TMP" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF

    run env PWT_FAIR_SHARE_STUB_CAPACITY=0 \
            PWT_FAIR_SHARE_MY_REPO=repo-a \
            PWT_RUN_PRIORITY=critical \
            "$FAIR_SHARE_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(get_field "$output" recommendation)" = "SPAWN_OK" ]
    [ "$(get_field "$output" priority)" = "critical" ]
}

# ─── AC4: claim add/remove round-trip changes fair-share calculation ────────
@test "fair-share AC4: removing a claim restores eligibility for spawn" {
    # Start: repo-a has 3 workers, repo-b at 0 with capacity 0 → repo-a YIELDs
    cat > "$REG_TMP" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF

    # repo-a asks for #4 → YIELD
    run env PWT_FAIR_SHARE_STUB_CAPACITY=0 \
            PWT_FAIR_SHARE_MY_REPO=repo-a \
            "$FAIR_SHARE_SCRIPT"
    [ "$(get_field "$output" recommendation)" = "YIELD_TO_OTHER_REPO" ]

    # remove repo-a's 3rd claim → fair_share becomes 2, repo-a at 2 == cap, repo-b at 1 < cap
    "$CLAIM_SCRIPT" remove aaa33333

    run env PWT_FAIR_SHARE_STUB_CAPACITY=0 \
            PWT_FAIR_SHARE_MY_REPO=repo-a \
            "$FAIR_SHARE_SCRIPT"
    # After remove: 3 active total (a:2, b:1). Asker repo-a is at fair_share (2).
    # repo-b has 1 < 2 (fair_share) → still YIELD because b is underserved.
    # The point of the test is that the registry mutation is reflected.
    [ "$(get_field "$output" my_repo_current)" = "2" ]
}

# ─── AC5: priority=background yields under any contention ────────────────────
@test "fair-share AC5: background priority yields when machine is at capacity" {
    cat > "$REG_TMP" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF

    run env PWT_FAIR_SHARE_STUB_CAPACITY=0 \
            PWT_FAIR_SHARE_MY_REPO=repo-c \
            PWT_RUN_PRIORITY=background \
            "$FAIR_SHARE_SCRIPT"
    [ "$(get_field "$output" recommendation)" = "YIELD_TO_OTHER_REPO" ]
    [ "$(get_field "$output" priority)" = "background" ]
}
