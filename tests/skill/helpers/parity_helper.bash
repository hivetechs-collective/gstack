# parity_helper.bash — byte-parity assertions for the Governor Contract (BRIEF §3, P0).
#
# The P0 guarantee: with no governor, /plan-w-team behaves byte-for-byte as before. This
# helper captures a golden from the PRE-CHANGE code and byte-compares later runs against it.
#
#   assert_parity <name> <cmd...>
#     Runs <cmd> UNGOVERNED (env -u PWT_GOVERNOR; the sandbox has no manifest), normalizes
#     volatile fields (sandbox paths, /Users/<u>/, ISO timestamps, UUIDs, labelled pids) to
#     placeholders, and byte-compares against tests/skill/parity/<name>.golden.
#
#   Golden capture / regeneration is EXPLICIT ONLY: PWT_PARITY_UPDATE=1 writes the golden and
#   shows up as a reviewed diff — never silent. A ship-gate check (governor-parity.bats) asserts
#   goldens predate the first consumer edit and that PWT_PARITY_UPDATE appears in no run commit.
#
# Phases 2-3 reuse this helper unchanged (brief §3) — that is why it is phase-1 scope.

PARITY_DIR="${PARITY_DIR:-${BATS_TEST_DIRNAME:-.}/../parity}"

# stdin → normalized stdout. Kept MINIMAL: every normalized field is a place drift can hide.
__parity_normalize() {
  local sb="${SANDBOX_DIR:-__no_sandbox_dir__}"
  sed -E \
    -e "s#${sb}#<SANDBOX>#g" \
    -e 's#/Users/[^/[:space:]]+/#/Users/<U>/#g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z/<TS>/g' \
    -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<UUID>/g' \
    -e 's/("pid"[[:space:]]*:[[:space:]]*)[0-9]+/\1<PID>/g' \
    -e 's/([Pp][Ii][Dd][=:][[:space:]]*)[0-9]+/\1<PID>/g'
}

# Capture combined stdout+stderr so "no new stderr line ungoverned" is part of the golden.
assert_parity() {
  local name="$1"; shift
  local golden="$PARITY_DIR/$name.golden"
  local actual
  actual=$(env -u PWT_GOVERNOR "$@" 2>&1 | __parity_normalize)

  if [ "${PWT_PARITY_UPDATE:-}" = "1" ]; then
    mkdir -p "$PARITY_DIR"
    printf '%s\n' "$actual" > "$golden"
    printf '# parity golden captured: %s\n' "$golden" >&2
    return 0
  fi

  if [ ! -f "$golden" ]; then
    printf 'MISSING GOLDEN %s — capture it from the base commit via PWT_PARITY_UPDATE=1\n' "$golden" >&2
    return 1
  fi

  local expected; expected=$(cat "$golden")
  if [ "$actual" != "$expected" ]; then
    printf 'PARITY MISMATCH (%s): ungoverned output drifted from the pre-change golden\n' "$name" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
  return 0
}

# assert_parity_string <name> <string>: same golden mechanism for a captured string (e.g. the
# LAUNCH_ENV built by a function) rather than a command's stdout.
assert_parity_string() {
  local name="$1" s="$2"
  local golden="$PARITY_DIR/$name.golden"
  local actual; actual=$(printf '%s' "$s" | __parity_normalize)
  if [ "${PWT_PARITY_UPDATE:-}" = "1" ]; then
    mkdir -p "$PARITY_DIR"; printf '%s\n' "$actual" > "$golden"; return 0
  fi
  [ -f "$golden" ] || { printf 'MISSING GOLDEN %s\n' "$golden" >&2; return 1; }
  local expected; expected=$(cat "$golden")
  if [ "$actual" != "$expected" ]; then
    printf 'PARITY MISMATCH (%s)\n' "$name" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
  return 0
}
