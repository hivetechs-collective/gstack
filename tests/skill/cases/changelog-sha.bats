#!/usr/bin/env bats
# tests/skill/cases/changelog-sha.bats
#
# P14 root-cause guard for CHANGELOG SHA drift.
#
# The re-audit (round 2, §3.3) found the CHANGELOG entry for 1.22.1 cited the
# wrong commit, and the very next bump (1.26.1) reproduced the bug — because a
# commit can never contain its own SHA, the author reflexively cites the CURRENT
# HEAD (the PRIOR version's commit) when writing the entry. That off-by-one is
# invisible to a human eye and recurred three times.
#
# This lint makes it impossible to ship: for every CHANGELOG entry that cites a
# resolvable SHA, `git show <sha>:.../VERSION` MUST equal the entry's own
# version. The off-by-one fails immediately (the prior commit's VERSION is the
# prior version). The single newest entry may carry the literal token `pending`
# until the next bump backfills it with its own shipping commit — see
# shared/versioning.md "CHANGELOG SHA backfill convention".
#
# Audit: P14 (docs/operations/pwt-principles-reaudit-2026-06-02-round2.md).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

CHANGELOG="$COMMANDS_DIR/CHANGELOG.md"
VERSION_PATH=".claude/commands/plan-w-team/VERSION"

setup() {
  require_cmd git
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skip "REPO_ROOT is not a git checkout"
  [ -f "$CHANGELOG" ] || skip "CHANGELOG not found"
}

@test "P14: every CHANGELOG entry's cited SHA shipped that exact version (no off-by-one)" {
  local fails="" checked=0 line ver sha vatcommit
  while IFS= read -r line; do
    # Header form: ## [1.26.2] — 2026-06-02 (51e6b52)  |  (pending)  |  (no sha)
    ver="$(printf '%s\n' "$line" | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')"
    [ -n "$ver" ] || continue

    # Pull the parenthetical. No "(...)" at all → legacy entry, not checked.
    sha="$(printf '%s\n' "$line" | sed -nE 's/.*\(([0-9a-fA-F]{7,40}|pending)\).*/\1/p')"
    [ -n "$sha" ] || continue

    # The newest entry may legitimately be (pending) — a commit can't cite itself.
    [ "$sha" = "pending" ] && continue

    # Unresolvable SHA (squashed / pre-VERSION-file / shallow clone) → tolerate.
    git -C "$REPO_ROOT" cat-file -e "${sha}^{commit}" 2>/dev/null || continue
    vatcommit="$(git -C "$REPO_ROOT" show "${sha}:${VERSION_PATH}" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$vatcommit" ] || continue

    checked=$((checked + 1))
    if [ "$vatcommit" != "$ver" ]; then
      fails="$fails
  - [$ver] cites $sha, but VERSION at that commit is $vatcommit (off-by-one)"
    fi
  done < <(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG")

  if [ -n "$fails" ]; then
    printf 'CHANGELOG SHA drift detected:%s\n' "$fails" >&2
    printf '(checked %d resolvable entries)\n' "$checked" >&2
    return 1
  fi
  # Sanity: we should have verified at least one entry against real git history.
  [ "$checked" -ge 1 ] || skip "no resolvable SHA-citing entries to verify"
}

@test "P14: at most one entry may carry the (pending) placeholder" {
  local pending
  pending="$(grep -Ec '^## \[[0-9]+\.[0-9]+\.[0-9]+\].*\(pending\)' "$CHANGELOG" || true)"
  [ "$pending" -le 1 ] || {
    printf 'found %s (pending) entries — only the newest may be pending; backfill the rest\n' "$pending" >&2
    return 1
  }
}
