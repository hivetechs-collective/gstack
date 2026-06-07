#!/usr/bin/env bash
# Tests for secret-scan.sh B3 fix: placeholder suppression is TOKEN-ADJACENCY aware,
# not whole-line. A real secret on a line whose only marker is in a distant comment
# must NOT be suppressed; a genuine placeholder (marker inside/adjacent to the token)
# must still be suppressed.
#
# NOTE: realistic secret tokens are built at RUNTIME via string concatenation so
# this source file contains no literal pattern match — otherwise the write-time
# damage-control content scan (B1) and the ship-gate --diff scan would (correctly)
# flag this very test file. Placeholder-shaped tokens are safe as literals.
#
# Coverage:
#   T1  real secret + distant marker on same line  → REPORTED (exit 1)   [the B3 bug]
#   T2  placeholder marker embedded in token        → SUPPRESSED (exit 0)
#   T3  xxxxxxxx-embedded placeholder (openai shape) → SUPPRESSED (exit 0)
#   T4  marker var-name but REAL value              → REPORTED (exit 1)
#   T5  clean file                                   → exit 0
#   T6  --diff mode honors token-adjacency          → REPORTED (exit 1)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SS="$SCRIPT_DIR/secret-scan.sh"

# Runtime-assembled real token (source has no literal AKIA+16 run).
AKIA_REAL="AKIA""Z9Q7W2P1N4K8T6RB"

PASS=0
FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"; PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
    fi
}

run_paths() { local f="$1"; "$SS" --paths "$f" >/dev/null 2>&1; echo $?; }

TMP=$(mktemp -d)

# T1 — real secret with a DISTANT placeholder marker in a trailing comment.
printf 'aws_key = "%s"  # see SAMPLE_ docs elsewhere\n' "$AKIA_REAL" > "$TMP/t1.txt"
assert "T1 real secret + distant marker reported" "1" "$(run_paths "$TMP/t1.txt")"

# T2 — placeholder marker embedded directly in the token.
printf 'aws_key = "AKIAEXAMPLE0000000Z"\n' > "$TMP/t2.txt"
assert "T2 embedded-marker placeholder suppressed" "0" "$(run_paths "$TMP/t2.txt")"

# T3 — token embedding an xxxxxxxx placeholder marker (openai key shape).
printf 'OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' > "$TMP/t3.txt"
assert "T3 xxxxxxxx-embedded placeholder suppressed" "0" "$(run_paths "$TMP/t3.txt")"

# T4 — example-ish var NAME but a real high-entropy value → must still be reported.
printf 'EXAMPLE_KEY=%s\n' "$AKIA_REAL" > "$TMP/t4.txt"
assert "T4 example var-name with real value reported" "1" "$(run_paths "$TMP/t4.txt")"

# T5 — clean file.
printf 'just some text\n' > "$TMP/t5.txt"
assert "T5 clean file exit 0" "0" "$(run_paths "$TMP/t5.txt")"

# T6 — --diff mode: added line carries a real secret + distant marker.
GITDIR=$(mktemp -d)
(
  cd "$GITDIR"
  git init -q
  git config user.email t@t.t; git config user.name t
  printf 'placeholder base\n' > f.txt
  git add f.txt; git commit -qm base
  printf 'token = "%s"  # REDACTED in samples\n' "$AKIA_REAL" >> f.txt
  git add f.txt; git commit -qm add
)
DIFF_RC=$( cd "$GITDIR"; "$SS" --diff "HEAD~1..HEAD" >/dev/null 2>&1; echo $? )
assert "T6 --diff token-adjacency reports real secret" "1" "$DIFF_RC"
rm -rf "$GITDIR"

rm -rf "$TMP"
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
