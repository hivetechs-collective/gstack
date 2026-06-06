#!/usr/bin/env bats
# tests/skill/cases/secret-scan-catalog-skip.bats
#
# The scanner self-excludes its own source file (secret-scan.sh) because that file
# embeds the pattern catalog. shared/secret-safety.md mirrors the SAME catalog,
# regenerated + drift-checked between BEGIN/END AUTO-GENERATED markers. Lines
# inside that block are pattern SHAPES (self-documentation), not live credentials,
# and must be skipped in ALL scan modes — while lines OUTSIDE the block are still
# scanned (a real secret elsewhere in the doc is still caught).
#
# Surfaced 2026-06-02 by adding §REQ-6 to secret-safety.md (credential-wall brief):
# the `azure-conn` row is the one catalog pattern whose "regex" is a pure literal,
# so it matched its own documentation row.
#
# Fixtures assemble the secret SHAPES at runtime so this .bats SOURCE file carries
# no scannable literal (it must itself pass the ship-gate secret scan).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCANNER="$REPO_ROOT/.claude/scripts/secret-scan.sh"

setup() { sandbox; }
teardown() { teardown_sandbox; }

# Build the azure-conn connection-string shape at runtime so the matching literal
# never appears contiguously in this source file (the trailing `=` is supplied via
# the argument, splitting the literal across the format string and the arg).
azure_shape() { printf 'DefaultEndpointsProtocol=https;AccountName%s' "=$1"; }
# Build an AWS access-key shape (`AKIA` + 16 chars) the same way.
aws_shape() { printf 'AKIA%s' "IOSFODNN7EXAMPLE"; }

write_catalog_doc() {
  # $1 = file; writes a doc whose catalog block contains a pattern shape.
  {
    echo "# doc"
    echo '<!-- BEGIN AUTO-GENERATED: secret-patterns -->'
    echo "| \`azure-conn\` | \`$(azure_shape "")\` | rotate |"
    echo '<!-- END AUTO-GENERATED: secret-patterns -->'
  } > "$1"
}

@test "catalog-skip (--paths): a pattern shape INSIDE the catalog block is skipped (exit 0)" {
  write_catalog_doc "$SANDBOX_DIR/catalog.md"
  run "$SCANNER" --paths "$SANDBOX_DIR/catalog.md"
  assert_success
}

@test "catalog-skip (--paths): a real secret OUTSIDE the block is STILL caught (exit 1)" {
  {
    aws_shape; echo
    echo '<!-- BEGIN AUTO-GENERATED: secret-patterns -->'
    echo "| \`azure-conn\` | \`$(azure_shape "")\` | rotate |"
    echo '<!-- END AUTO-GENERATED: secret-patterns -->'
  } > "$SANDBOX_DIR/mixed.md"
  run "$SCANNER" --paths "$SANDBOX_DIR/mixed.md"
  assert_failure
  assert_output_contains "AKIA"
}

@test "catalog-skip (--diff): an added shape INSIDE the block is skipped, OUTSIDE is caught" {
  sandbox_git_init
  printf 'hello\n' > doc.md
  git add -A && git commit -q -m base
  {
    aws_shape; echo
    echo '<!-- BEGIN AUTO-GENERATED: secret-patterns -->'
    echo "| \`azure-conn\` | \`$(azure_shape "live")\` | rotate |"
    echo '<!-- END AUTO-GENERATED: secret-patterns -->'
  } >> doc.md
  run "$SCANNER" --diff "HEAD"
  assert_failure                       # the AWS key outside the block trips it
  assert_output_contains "doc.md:2"    # line 2 = the AWS key (outside)
  assert_output_not_contains "azure-conn"   # the in-block shape was skipped
}

@test "catalog-skip: this test file itself carries no scannable secret literal" {
  run "$SCANNER" --paths "$BATS_TEST_DIRNAME/secret-scan-catalog-skip.bats"
  assert_success
}
