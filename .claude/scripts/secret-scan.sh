#!/usr/bin/env bash
# Shared secret scanner. Single source of truth for pre-commit, ship-gate, and sync.
#
# Modes (exactly one required):
#   --staged              Scan git-staged content (filter: ACMR)
#   --paths FILE...       Scan specific files on disk
#   --diff RANGE          Scan added lines (+) in a git range (e.g. origin/main..HEAD)
#
# Options:
#   --json                Emit newline-delimited JSON findings (default: human-readable)
#   --max-filesize BYTES  Skip files larger than this (default: 1048576)
#   --allow FILE          Suppress findings listed in FILE (format: path:line:pattern,
#                         one per line; "#" starts a comment; blanks ignored)
#   --help                Show this help
#
# Exit codes:
#   0  No live secrets found
#   1  Live secret(s) found
#   2  Bad arguments or internal error

set -u
set -o pipefail

usage() {
  sed -n '2,19p' "$0" | sed -E 's|^#[[:space:]]?||'
}

MODE=""
PATHS=()
DIFF_RANGE=""
JSON_OUT=false
MAX_FILESIZE=1048576
ALLOW_FILE=""
ALLOW_KEYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged"; shift ;;
    --paths)
      MODE="paths"; shift
      while [[ $# -gt 0 && "$1" != --* ]]; do PATHS+=("$1"); shift; done
      ;;
    --diff)
      [[ $# -ge 2 ]] || { echo "--diff requires a range argument" >&2; exit 2; }
      MODE="diff"; DIFF_RANGE="$2"; shift 2
      ;;
    --json) JSON_OUT=true; shift ;;
    --max-filesize)
      [[ $# -ge 2 ]] || { echo "--max-filesize requires a byte count" >&2; exit 2; }
      MAX_FILESIZE="$2"; shift 2
      ;;
    --allow)
      [[ $# -ge 2 ]] || { echo "--allow requires a file path" >&2; exit 2; }
      ALLOW_FILE="$2"; shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -z "$MODE" ]] && { usage >&2; exit 2; }

# Load allow-file entries (path:line:pattern-name). Comments and blanks ignored.
# Each non-blank line up to the first "#" becomes an exact-match key compared
# against the same "file|line|pattern" tuple emit_finding builds.
if [[ -n "$ALLOW_FILE" ]]; then
  if [[ ! -f "$ALLOW_FILE" ]]; then
    echo "--allow file not found: $ALLOW_FILE" >&2
    exit 2
  fi
  while IFS= read -r raw; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    key=$(printf '%s' "$entry" | awk -F: '{printf "%s|%s|%s", $1, $2, $3}')
    ALLOW_KEYS+=("$key")
  done < "$ALLOW_FILE"
fi

# Pattern catalog. Each entry is "NAME|REGEX|REMEDIATION".
# Order matters only for reporting; dedup happens by (file:line:token).
PATTERNS=(
  'aws|AKIA[A-Z0-9]{16}|Revoke at AWS IAM console; rotate access keys'
  'github-token|gh[pousr]_[a-zA-Z0-9_]{36,}|Revoke at github.com/settings/tokens'
  'anthropic|sk-ant-[a-zA-Z0-9_-]{20,}|Revoke at console.anthropic.com/settings/keys'
  'openai-proj|sk-proj-[A-Za-z0-9_-]{20,}|Revoke at platform.openai.com/api-keys'
  'openai|sk-[A-Za-z0-9]{48,}|Revoke at platform.openai.com/api-keys'
  'stripe-live-secret|sk_live_[a-zA-Z0-9]{20,}|Roll at dashboard.stripe.com/apikeys'
  'stripe-test-secret|sk_test_[a-zA-Z0-9]{20,}|Roll at dashboard.stripe.com/test/apikeys'
  'stripe-live-pub|pk_live_[a-zA-Z0-9]{20,}|Stripe publishable key — confirm intent before committing'
  'slack|xox[baprs]-[A-Za-z0-9-]{10,}|Revoke at api.slack.com/apps'
  'gitlab-pat|glpat-[A-Za-z0-9_-]{20,}|Revoke at gitlab.com/-/profile/personal_access_tokens'
  'azure-conn|DefaultEndpointsProtocol=https;AccountName=|Rotate Azure storage account keys'
  'azure-accountkey|AccountKey=[A-Za-z0-9+/=]{40,}|Rotate Azure storage account keys'
  'paddle-live|pdl_live_apikey_[a-zA-Z0-9]{20,}|Revoke at vendors.paddle.com/authentication-v2'
  'paddle-sandbox|pdl_sdbx_apikey_[a-zA-Z0-9]{20,}|Revoke at sandbox-vendors.paddle.com/authentication-v2'
  'resend|re_[A-Za-z0-9]{20,}|Revoke at resend.com/api-keys'
  'smtp2go|api-[a-f0-9]{32}|Revoke at app.smtp2go.com/settings/'
  'cloudflare-token|cfut_[A-Za-z0-9]{20,}|Roll at dash.cloudflare.com/profile/api-tokens (committed 2026-05-25 in cleanscale #465 — scanner had no CF pattern)'
  'jwt|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|JWT in code — if live session/signing token, rotate issuer secret'
  'private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----|Rotate private key; revoke if used in production'
)

# Placeholder markers. If a matched LINE contains any of these, the match is
# classified as a placeholder/template and NOT reported as a live secret.
# Rationale: .env.example files and redacted templates intentionally embed
# pattern-shaped strings as instructions to the user.
PLACEHOLDER_MARKERS=(
  'YOUR_'
  'TODO_'
  'REPLACE_'
  'FIXME_'
  'CHANGE_'
  'SET_'
  'PLACEHOLDER'
  'GENERATE_'
  'NEED_'
  'STORED_IN_'
  'RETRIEVE_'
  'OPTIONAL_'
  'EXAMPLE_'
  'SAMPLE_'
  'REDACTED'
  'xxxxxxxx'
  'XXXXXXXX'
  '<your-'
  '<YOUR_'
)

# Returns 0 if the line should be suppressed as a placeholder.
#
# NOTE (B3, 1.33.0): this whole-line check is RETAINED only as a cheap pre-filter
# for the diff-mode fast path (a line with NO marker anywhere cannot be a
# placeholder, so we can skip the per-token work). It is NOT authoritative for
# suppression — the authoritative, token-adjacency-aware decision is
# is_placeholder_token() below. The old design suppressed an ENTIRE line if any
# marker appeared ANYWHERE on it, so a real secret on a line that merely also
# contained `EXAMPLE_`/`SAMPLE_`/`REDACTED` (e.g. in a trailing comment) was
# silently dropped in both enforcing gates. See shared/secret-safety.md and the
# adversarial-audit brief gap B3.
is_placeholder_line() {
  local line="$1"
  local marker
  for marker in "${PLACEHOLDER_MARKERS[@]}"; do
    case "$line" in
      *"$marker"*) return 0 ;;
    esac
  done
  return 1
}

# Returns 0 if the MATCHED TOKEN (not merely the line) is a placeholder. B3 fix:
# require a placeholder marker to be ADJACENT TO or CONTAINED WITHIN the matched
# token, rather than appearing anywhere on the line. "Adjacent" = the marker's
# nearest occurrence is separated from the token by at most PLACEHOLDER_GAP
# non-alphanumeric separator characters (`=`, `:`, `"`, `_`, `-`, `<`, space, …);
# "contained" = the token itself embeds the marker (e.g. `sk-ant-EXAMPLE_xxxx`,
# `AKIAEXAMPLE0000000000`). A real high-entropy secret on a line whose ONLY marker
# is in a distant comment is therefore NOT suppressed. bash 3.2 safe (parameter
# expansion + integer math only; no `declare -A`, no regex with dynamic patterns).
PLACEHOLDER_GAP="${SECRET_SCAN_PLACEHOLDER_GAP:-3}"
is_placeholder_token() {
  local line="$1" token="$2" marker
  [ -z "$token" ] && return 1
  # (a) token contains the marker → genuine placeholder (overlap).
  for marker in "${PLACEHOLDER_MARKERS[@]}"; do
    case "$token" in *"$marker"*) return 0 ;; esac
  done
  # (b) adjacency by character distance. Locate the token (first occurrence).
  local pre="${line%%"$token"*}"
  # No occurrence (token came from a transformed copy) → cannot judge adjacency;
  # treat as NOT a placeholder (fail-safe toward reporting).
  [ "$pre" = "$line" ] && return 1
  local tok_start=${#pre}
  local tok_end=$(( tok_start + ${#token} ))
  for marker in "${PLACEHOLDER_MARKERS[@]}"; do
    local mpre="${line%%"$marker"*}"
    [ "$mpre" = "$line" ] && continue   # marker absent
    local m_start=${#mpre}
    local m_end=$(( m_start + ${#marker} ))
    local gap
    if [ "$m_end" -le "$tok_start" ]; then
      gap=$(( tok_start - m_end ))          # marker before token
    elif [ "$m_start" -ge "$tok_end" ]; then
      gap=$(( m_start - tok_end ))          # marker after token
    else
      return 0                              # overlap → placeholder
    fi
    [ "$gap" -le "$PLACEHOLDER_GAP" ] && return 0
  done
  return 1
}

# Redact a matched token for human output (show first 6 + last 4 chars, or all
# if shorter than 12). Never echoes secrets at full length.
redact() {
  local token="$1"
  local len=${#token}
  if (( len <= 12 )); then
    printf '%s' "$token"
  else
    printf '%s...%s' "${token:0:6}" "${token: -4}"
  fi
}

FINDINGS_COUNT=0
declare -a SEEN_KEYS=()

# Emit a finding. Dedup by "label|line|name". Suppresses entries listed in
# the allow-file (loaded at startup); same key shape as the dedup key.
emit_finding() {
  local label="$1" linenum="$2" name="$3" token="$4" remediation="$5"
  local key="${label}|${linenum}|${name}"
  local existing
  for existing in "${ALLOW_KEYS[@]:-}"; do
    [[ "$existing" == "$key" ]] && return 0
  done
  for existing in "${SEEN_KEYS[@]:-}"; do
    [[ "$existing" == "$key" ]] && return 0
  done
  SEEN_KEYS+=("$key")
  FINDINGS_COUNT=$((FINDINGS_COUNT + 1))
  local redacted
  redacted=$(redact "$token")
  if [[ "$JSON_OUT" == true ]]; then
    printf '{"file":"%s","line":%s,"pattern":"%s","preview":"%s","remediation":"%s"}\n' \
      "$label" "$linenum" "$name" "$redacted" "$remediation"
  else
    printf '[secret-scan] LIVE SECRET: %s:%s\n  pattern: %s\n  preview: %s\n  remediation: %s\n' \
      "$label" "$linenum" "$name" "$redacted" "$remediation" >&2
  fi
}

# Scan a block of text (passed via stdin) labeled for reporting. Runs each
# pattern via grep -nE and suppresses placeholder-marked lines.
scan_text() {
  local label="$1"
  local text="$2"
  # Self-documentation skip: lines inside an auto-generated secret-pattern catalog
  # block are the scanner's OWN published pattern SHAPES, not live credentials.
  # The scanner already self-excludes its source file (secret-scan.sh) for exactly
  # this reason (see should_skip_file); shared/secret-safety.md embeds the SAME
  # catalog, regenerated + drift-checked between these markers by secret-doc-sync.sh.
  # A secret scanner must not flag its own documentation of what secrets look like.
  # We skip ONLY the marked block; any line outside it is still scanned, so a real
  # secret pasted elsewhere in the doc is still caught. (Empty when no markers.)
  local catalog_lines
  catalog_lines=$(printf '%s\n' "$text" | awk '
    /BEGIN AUTO-GENERATED: secret-patterns/ { inblk=1 }
    { if (inblk) print NR }
    /END AUTO-GENERATED: secret-patterns/ { inblk=0 }
  ')
  local entry name regex remediation
  for entry in "${PATTERNS[@]}"; do
    name="${entry%%|*}"
    local rest="${entry#*|}"
    regex="${rest%%|*}"
    remediation="${rest#*|}"
    local matches
    matches=$(printf '%s\n' "$text" | grep -nE "$regex" 2>/dev/null || true)
    [[ -z "$matches" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local linenum="${line%%:*}"
      local content="${line#*:}"
      # Skip matches inside the auto-generated catalog block (self-documentation).
      if [[ -n "$catalog_lines" ]] && printf '%s\n' "$catalog_lines" | grep -qxF "$linenum"; then
        continue
      fi
      local token
      token=$(printf '%s' "$content" | grep -oE "$regex" | head -1)
      [[ -z "$token" ]] && continue
      # B3: suppress ONLY when the marker is adjacent to / inside the token,
      # not merely somewhere on the line.
      is_placeholder_token "$content" "$token" && continue
      emit_finding "$label" "$linenum" "$name" "$token" "$remediation"
    done <<< "$matches"
  done
}

# Skip binary/oversized files. Uses `file` for type sniffing and `wc -c` for size.
should_skip_file() {
  local f="$1"
  [[ ! -f "$f" ]] && return 0
  local size
  size=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
  (( size > MAX_FILESIZE )) && return 0
  # Self-reference: the scanner's own source embeds the pattern catalog and
  # would recursively match every live-shape regex. Skip.
  case "$f" in
    *.claude/scripts/secret-scan.sh) return 0 ;;
  esac
  # Rudimentary binary check: grep -Iq treats binary as no-match; invert for skip.
  if ! grep -Iq '' "$f" 2>/dev/null; then
    return 0
  fi
  return 1
}

case "$MODE" in
  staged)
    # git returns ACMR staged files; read each via `git show :FILE`
    STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
    [[ -z "$STAGED" ]] && exit 0
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      case "$file" in *.claude/scripts/secret-scan.sh) continue ;; esac
      content=$(git show ":$file" 2>/dev/null || true)
      [[ -z "$content" ]] && continue
      [[ ${#content} -gt $MAX_FILESIZE ]] && continue
      scan_text "$file" "$content"
    done <<< "$STAGED"
    ;;
  paths)
    (( ${#PATHS[@]} == 0 )) && { echo "--paths requires at least one file" >&2; exit 2; }
    for file in "${PATHS[@]}"; do
      should_skip_file "$file" && continue
      content=$(cat "$file" 2>/dev/null || true)
      scan_text "$file" "$content"
    done
    ;;
  diff)
    # Scan only added lines (+) from the diff, not context or removals.
    # Strip the leading + before matching so patterns don't need to handle it.
    DIFF=$(git diff "$DIFF_RANGE" 2>/dev/null || true)
    [[ -z "$DIFF" ]] && exit 0
    # Parse diff: track current file from +++ lines, current line from @@ hunks,
    # scan '+' lines. Skip '+++ ' header.
    current_file=""
    current_line=0
    in_catalog=0
    while IFS= read -r raw; do
      # Track auto-generated catalog markers across the diff stream (markers are
      # typically unchanged context lines). A '+' line inside the block is the
      # scanner's own published pattern SHAPE, not a live secret — skip it, exactly
      # as scan_text does for --staged/--paths. BEGIN/END live on distinct lines and
      # the marker lines themselves never carry a secret shape, so order is safe.
      case "$raw" in
        *"BEGIN AUTO-GENERATED: secret-patterns"*) in_catalog=1 ;;
        *"END AUTO-GENERATED: secret-patterns"*)   in_catalog=0 ;;
      esac
      case "$raw" in
        '+++ '*)
          current_file="${raw#+++ }"
          current_file="${current_file#b/}"
          in_catalog=0
          continue
          ;;
        '--- '*) continue ;;
        '@@ '*)
          # @@ -OLD +NEW_START,NEW_LEN @@
          hunk="${raw#@@ }"
          hunk="${hunk%% @@*}"
          new_part="${hunk##*+}"
          current_line="${new_part%%,*}"
          continue
          ;;
        '+'*)
          case "$current_file" in *.claude/scripts/secret-scan.sh) current_line=$((current_line + 1)); continue ;; esac
          # Inside the auto-generated catalog block: self-documentation, not a leak.
          if [[ "$in_catalog" == 1 ]]; then current_line=$((current_line + 1)); continue; fi
          added="${raw#+}"
          for entry in "${PATTERNS[@]}"; do
            name="${entry%%|*}"
            rest="${entry#*|}"
            regex="${rest%%|*}"
            remediation="${rest#*|}"
            token=$(printf '%s' "$added" | grep -oE "$regex" 2>/dev/null | head -1 || true)
            [[ -z "$token" ]] && continue
            # B3: token-adjacency placeholder check (not whole-line) — a real
            # secret on a line whose only marker is in a distant comment is NOT
            # suppressed; matches scan_text() behavior for --staged/--paths.
            is_placeholder_token "$added" "$token" && continue
            emit_finding "$current_file" "$current_line" "$name" "$token" "$remediation"
          done
          current_line=$((current_line + 1))
          ;;
        ' '*) current_line=$((current_line + 1)) ;;
        *) : ;;
      esac
    done <<< "$DIFF"
    ;;
esac

if (( FINDINGS_COUNT > 0 )); then
  [[ "$JSON_OUT" != true ]] && echo "[secret-scan] Found $FINDINGS_COUNT live secret(s). Commit blocked." >&2
  exit 1
fi

[[ "$JSON_OUT" != true ]] && echo "[secret-scan] Clean." >&2
exit 0
