#!/usr/bin/env bats
# tests/skill/cases/access-control-content-scan.bats
#
# Behavioral coverage for the P9c deterministic detection floor
# (.claude/scripts/access-control-content-scan.sh). Unlike the 1.22.0
# markdown-presence .bats, this pipes REAL fixture diffs through the scanner and
# asserts true-positives (CS-1..CS-4), a clean negative, the CS-4 tenant-predicate
# suppression, and the fail-toward-review-required error path.
#
# Audit: P9c (docs/operations/pwt-principles-enforcement-audit-2026-06-02.md).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT="$SCRIPTS_DIR/access-control-content-scan.sh"

setup() {
  TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/acscan-XXXXXX")"
  SD="$TMP/state"
  mkdir -p "$SD"
}
teardown() { rm -rf "$TMP"; }

suspects() { cat "$SD/plan-w-team-content-signal-suspects-t.txt"; }
run_scan() { run "$SCRIPT" --slug t --diff-file "$TMP/d.diff" --state-dir "$SD" --quiet; }

@test "CS-1 privilege-bearing field write is flagged (exit 3)" {
  printf '+++ b/api/qa-sim.ts\n+  user.platformRole = "PLATFORM_ADMIN"\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 3 ]
  suspects | grep -q '^CS-1'
}

@test "CS-2 request-body spread into ORM update is flagged (exit 3)" {
  printf '+++ b/api/jobs.ts\n+  await db.update(jobs).set({ ...req.body })\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 3 ]
  suspects | grep -q '^CS-2'
}

@test "CS-3 QA/bypass-token-gated handler is flagged (exit 3)" {
  printf '+++ b/api/qa-sim.ts\n+  if (req.headers.authorization === process.env.QA_SIM_TOKEN) {\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 3 ]
  suspects | grep -q '^CS-3'
}

@test "CS-4 where-by-id WITHOUT a tenant predicate is flagged (exit 3)" {
  printf '+++ b/api/jobs.ts\n+  const row = await db.select().from(jobs).where(eq(jobs.id, input.id))\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 3 ]
  suspects | grep -q '^CS-4'
}

@test "CS-4 where-by-id WITH a tenant predicate is NOT flagged (clean, exit 0)" {
  printf '+++ b/api/jobs.ts\n+  .where(and(eq(jobs.id, input.id), eq(jobs.tenantId, ctx.tenantId)))\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 0 ]
}

@test "a clean diff (no access-control signals) returns exit 0 with empty suspects" {
  printf '+++ b/src/util/format.ts\n+export const titleCase = (s: string) => s.toUpperCase()\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 0 ]
  [ ! -s "$SD/plan-w-team-content-signal-suspects-t.txt" ]
}

@test "an unreadable diff-file fails TOWARD review-required (exit 2)" {
  run "$SCRIPT" --slug t --diff-file "$TMP/does-not-exist.diff" --state-dir "$SD" --quiet
  [ "$status" -eq 2 ]
}

@test "CS-4 Drizzle relational 'where:' by-id form (no tenant predicate) is flagged (round-2 §3.5)" {
  printf '+++ b/api/jobs.ts\n+  const row = await db.query.jobs.findFirst({ where: eq(jobs.id, input.id) })\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 3 ]
  suspects | grep -q '^CS-4'
}

@test "CS-4 Drizzle relational 'where:' WITH a tenant predicate is NOT flagged (clean)" {
  printf '+++ b/api/jobs.ts\n+    where: and(eq(jobs.id, input.id), eq(jobs.tenantId, ctx.tenantId))\n' > "$TMP/d.diff"
  run_scan
  [ "$status" -eq 0 ]
}
