#!/usr/bin/env bash
# fetch-changelog.sh — fetch Claude Code changelog between two versions.
#
# Tries sources in this order:
#   1. Local mirror at $CLAUDE_PATTERN_CHANGELOG_MIRROR or
#      .claude/state/claude-code-changelog-mirror.md (if present)
#   2. Direct fetch from GitHub via curl (when --curl is passed). Hits
#      $CHANGELOG_URL (default: raw.githubusercontent.com/anthropics/
#      claude-code/main/CHANGELOG.md). Follows redirects (-L), retries once
#      on transient failure with a 2s sleep, exits 2 on hard failure.
#      This is the path the session-start.sh hook uses for zero-LLM
#      automation — curl is bash-native, WebFetch is agent-only.
#   3. Bundled fixture at tests/version-uplift/fixtures/changelog-fixture.md
#      (only when --allow-fixture is passed; used by tests + offline runs)
#
# Design rationale (2026-05-22): the original script declared it
# "intentionally avoids inline WebFetch calls" because WebFetch is an agent
# tool. That assumption needlessly broke the session-start automation chain:
# detect-version.sh would fire, write the pending flag, and then nothing
# could fetch the changelog because no LLM was in the loop. curl is
# available in every shell on every platform Claude Code targets — the
# assumption that we needed an agent to do HTTP was wrong.
#
# Flags:
#   --from=VERSION         Lower bound (exclusive); null means "earliest".
#   --to=VERSION           Upper bound (inclusive); required.
#   --from-file=PATH       Read raw changelog from PATH instead of mirror.
#   --from-stdin           Read raw changelog from stdin.
#   --curl                 Fetch from $CHANGELOG_URL via curl -L (follows
#                          redirects, single retry on transient failure).
#   --curl-url=URL         Override the curl source URL (testing).
#   --allow-fixture        Fall back to bundled fixture when no other source.
#   --output=PATH          Write structured JSON to PATH (default: stdout).
#   --format=json|md       Output format (default json).
#
# Output JSON shape:
#   {
#     "from": "2.1.140" | null,
#     "to": "2.1.148",
#     "source": "mirror" | "file" | "stdin" | "fixture",
#     "versions": [
#       { "version": "2.1.148", "entries": ["...", "..."] },
#       ...
#     ]
#   }
#
# Exit codes:
#   0  success
#   2  no source available
#   3  malformed flag
#   4  parse failure

set -euo pipefail

FROM="null"
TO=""
FROM_FILE=""
FROM_STDIN=0
USE_CURL=0
CURL_URL="https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
ALLOW_FIXTURE=0
OUTPUT=""
FORMAT="json"

for arg in "$@"; do
    case "$arg" in
        --from=*) FROM="${arg#*=}" ;;
        --to=*) TO="${arg#*=}" ;;
        --from-file=*) FROM_FILE="${arg#*=}" ;;
        --from-stdin) FROM_STDIN=1 ;;
        --curl) USE_CURL=1 ;;
        --curl-url=*) CURL_URL="${arg#*=}"; USE_CURL=1 ;;
        --allow-fixture) ALLOW_FIXTURE=1 ;;
        --output=*) OUTPUT="${arg#*=}" ;;
        --format=*) FORMAT="${arg#*=}" ;;
        --help|-h)
            sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "fetch-changelog.sh: unknown arg: $arg" >&2
            exit 3
            ;;
    esac
done

if [ -z "$TO" ]; then
    echo "fetch-changelog.sh: --to=VERSION required" >&2
    exit 3
fi

# --- locate source ---
SOURCE=""
RAW=""

# curl_fetch URL → echoes body on stdout; returns 0 on success, non-zero on
# hard failure. Retries once on transient errors with 2s sleep. Uses -L to
# follow 301/307 redirects. Sets reasonable timeouts so a stuck connection
# can never block session start indefinitely.
curl_fetch() {
    local url="$1"
    local attempt
    for attempt in 1 2; do
        # -fsSL: fail on HTTP error, silent, show errors, follow redirects.
        # --connect-timeout 5: hard-cap the TCP handshake.
        # --max-time 20: hard-cap the whole transfer (changelog is ~50KB).
        if curl -fsSL --connect-timeout 5 --max-time 20 "$url" 2>/dev/null; then
            return 0
        fi
        # Transient — sleep and retry once. Skip sleep after second attempt.
        [ "$attempt" -eq 1 ] && sleep 2
    done
    return 1
}

if [ "$FROM_STDIN" -eq 1 ]; then
    RAW=$(cat)
    SOURCE="stdin"
elif [ -n "$FROM_FILE" ]; then
    if [ ! -f "$FROM_FILE" ]; then
        echo "fetch-changelog.sh: --from-file path does not exist: $FROM_FILE" >&2
        exit 2
    fi
    RAW=$(cat "$FROM_FILE")
    SOURCE="file"
elif [ "$USE_CURL" -eq 1 ]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "fetch-changelog.sh: --curl requested but curl not in PATH" >&2
        exit 2
    fi
    if ! RAW=$(curl_fetch "$CURL_URL"); then
        echo "fetch-changelog.sh: curl fetch failed for $CURL_URL (after retry)" >&2
        exit 2
    fi
    SOURCE="curl"
else
    MIRROR="${CLAUDE_PATTERN_CHANGELOG_MIRROR:-.claude/state/claude-code-changelog-mirror.md}"
    if [ -f "$MIRROR" ]; then
        RAW=$(cat "$MIRROR")
        SOURCE="mirror"
    elif [ "$ALLOW_FIXTURE" -eq 1 ] \
        && [ -f "tests/version-uplift/fixtures/changelog-fixture.md" ]; then
        RAW=$(cat "tests/version-uplift/fixtures/changelog-fixture.md")
        SOURCE="fixture"
    else
        echo "fetch-changelog.sh: no changelog source available" >&2
        echo "  hint: pass --from-file=PATH, --from-stdin, --curl, --allow-fixture," >&2
        echo "        or set \$CLAUDE_PATTERN_CHANGELOG_MIRROR" >&2
        exit 2
    fi
fi

if [ -z "$RAW" ]; then
    echo "fetch-changelog.sh: changelog source is empty" >&2
    exit 4
fi

# --- semver compare helpers ---
# Returns 0 if $1 >= $2, else 1. Handles X.Y.Z only.
semver_ge() {
    local a="$1" b="$2"
    [ "$a" = "$b" ] && return 0
    local highest
    highest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)
    [ "$highest" = "$a" ]
}

# Returns 0 if $1 > $2, else 1.
semver_gt() {
    [ "$1" = "$2" ] && return 1
    semver_ge "$1" "$2"
}

# --- parse raw changelog into version sections ---
# Expected format (matches Anthropic's docs.claude.com style):
#   ## 2.1.148
#   - entry
#   - entry
#
#   ## 2.1.147
#   - entry
#
# We accept "## X.Y.Z" or "## vX.Y.Z" or "### X.Y.Z" headings.
TMPDIR=$(mktemp -d -t uplift-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

CURRENT_VERSION=""
SECTIONS_FILE="$TMPDIR/sections.tsv"
: > "$SECTIONS_FILE"

while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^#{2,3}[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        CURRENT_VERSION="${BASH_REMATCH[1]}"
        continue
    fi
    if [ -n "$CURRENT_VERSION" ]; then
        # Treat any "-", "*", or "+" bullet as an entry.
        if [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]]+(.+)$ ]]; then
            entry="${BASH_REMATCH[1]}"
            # Strip a leading `**...**:` style label if present.
            printf '%s\t%s\n' "$CURRENT_VERSION" "$entry" >> "$SECTIONS_FILE"
        fi
    fi
done <<< "$RAW"

if [ ! -s "$SECTIONS_FILE" ]; then
    echo "fetch-changelog.sh: parsed 0 entries from changelog source" >&2
    exit 4
fi

# --- filter by version range ---
FROM_VAL=""
[ "$FROM" != "null" ] && [ -n "$FROM" ] && FROM_VAL="$FROM"

# Build the set of versions in range.
VERSIONS_FILE="$TMPDIR/versions.txt"
cut -f1 "$SECTIONS_FILE" | sort -uV > "$VERSIONS_FILE"

IN_RANGE_FILE="$TMPDIR/in-range.txt"
: > "$IN_RANGE_FILE"
while IFS= read -r v; do
    # v must be <= TO and (FROM_VAL empty OR v > FROM_VAL)
    if semver_ge "$TO" "$v"; then
        if [ -z "$FROM_VAL" ] || semver_gt "$v" "$FROM_VAL"; then
            echo "$v" >> "$IN_RANGE_FILE"
        fi
    fi
done < "$VERSIONS_FILE"

# Reverse-sort so newest first.
sort -Vr "$IN_RANGE_FILE" > "$TMPDIR/in-range-rev.txt"
mv "$TMPDIR/in-range-rev.txt" "$IN_RANGE_FILE"

# --- emit ---
emit_json() {
    local first_version=1
    printf '{\n'
    if [ "$FROM" = "null" ] || [ -z "$FROM" ]; then
        printf '  "from": null,\n'
    else
        printf '  "from": "%s",\n' "$FROM"
    fi
    printf '  "to": "%s",\n' "$TO"
    printf '  "source": "%s",\n' "$SOURCE"
    printf '  "versions": [\n'
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        if [ "$first_version" -eq 0 ]; then printf ',\n'; fi
        first_version=0
        printf '    {\n'
        printf '      "version": "%s",\n' "$v"
        printf '      "entries": ['
        local first_entry=1
        while IFS=$'\t' read -r ev entry; do
            [ "$ev" = "$v" ] || continue
            if [ "$first_entry" -eq 0 ]; then printf ', '; fi
            first_entry=0
            # JSON-escape: backslash, double-quote, control chars.
            esc=$(printf '%s' "$entry" \
                | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g')
            printf '"%s"' "$esc"
        done < "$SECTIONS_FILE"
        printf ']\n    }'
    done < "$IN_RANGE_FILE"
    printf '\n  ]\n}\n'
}

emit_md() {
    printf '# Changelog %s -> %s (source: %s)\n\n' \
        "${FROM_VAL:-earliest}" "$TO" "$SOURCE"
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        printf '## %s\n\n' "$v"
        while IFS=$'\t' read -r ev entry; do
            [ "$ev" = "$v" ] || continue
            printf -- '- %s\n' "$entry"
        done < "$SECTIONS_FILE"
        printf '\n'
    done < "$IN_RANGE_FILE"
}

if [ -n "$OUTPUT" ]; then
    mkdir -p "$(dirname "$OUTPUT")"
    if [ "$FORMAT" = "md" ]; then
        emit_md > "$OUTPUT"
    else
        emit_json > "$OUTPUT"
    fi
else
    if [ "$FORMAT" = "md" ]; then
        emit_md
    else
        emit_json
    fi
fi
