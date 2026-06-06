#!/usr/bin/env bats
# tests/skill/cases/sync-rsync-checksum.bats
#
# Guards the fix for the rsync quick-check silent-skip bug.
#
# rsync's default quick-check transfers a file only when size OR mtime differ.
# The 7-byte plan-w-team VERSION marker is identical in size across releases
# (`1.28.0\n` vs `1.29.0\n`), so when a prior sync left the destination with a
# matching mtime, rsync SKIPPED the transfer despite changed content — a consumer
# silently kept a stale VERSION while its larger skill files updated (observed
# 2026-06-03 on mac-mini cleanscale: split 1.29.0-skill / 1.28.0-marker state).
#
# Fix: every content-bearing rsync in sync-to-project.sh carries `--checksum`
# (content-based comparison). This test (1) asserts the flag is present on every
# rsync site, and (2) demonstrates empirically that --checksum is REQUIRED — a
# same-size, same-mtime, changed-content file is skipped without it and copied
# with it. See project_sync_rsync_quickcheck_skips_version (memory).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SYNC="$SCRIPTS_DIR/sync-to-project.sh"

@test "every rsync invocation in sync-to-project.sh uses --checksum" {
  [ -f "$SYNC" ] || skip "sync-to-project.sh not found"
  # Each line that starts an rsync command must include --checksum.
  local bad=""
  while IFS= read -r line; do
    printf '%s' "$line" | grep -q -- '--checksum' || bad="$bad
  $line"
  done < <(grep -nE '^\s*rsync ' "$SYNC")
  [ -z "$bad" ] || { printf 'rsync site(s) missing --checksum:%s\n' "$bad" >&2; false; }
}

@test "--checksum is REQUIRED: same-size+mtime, changed content is skipped without it" {
  require_cmd rsync
  local t; t="$(mktemp -d "${BATS_TMPDIR:-/tmp}/rsync-cs-XXXXXX")"
  mkdir -p "$t/src" "$t/dst"
  printf '1.29.0\n' > "$t/src/VERSION"      # new, 7 bytes
  printf '1.28.0\n' > "$t/dst/VERSION"      # stale, 7 bytes (same size)
  touch -t 202606030030.01 "$t/src/VERSION" "$t/dst/VERSION"  # identical mtime

  # Without --checksum: quick-check (size+mtime) skips → dst stays stale.
  rsync -a "$t/src/VERSION" "$t/dst/VERSION" >/dev/null 2>&1
  [ "$(cat "$t/dst/VERSION")" = "1.28.0" ]   # demonstrates the bug exists

  # With --checksum: content differs → transferred.
  printf '1.28.0\n' > "$t/dst/VERSION"
  touch -t 202606030030.01 "$t/src/VERSION" "$t/dst/VERSION"
  rsync -a --checksum "$t/src/VERSION" "$t/dst/VERSION" >/dev/null 2>&1
  [ "$(cat "$t/dst/VERSION")" = "1.29.0" ]   # demonstrates --checksum fixes it

  rm -rf "$t"
}
