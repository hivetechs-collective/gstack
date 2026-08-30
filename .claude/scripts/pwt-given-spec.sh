#!/usr/bin/env bash
# pwt-given-spec.sh — Governor Contract phase 3 (C6): validate + install a governor-supplied spec.
#
# The sanctioned GIVEN-SPEC entry. A governor (Shipyard's CE) or an operator supplies a pre-written,
# judge-attested spec at an arbitrary path; `pwt-goal.sh --spec <path>` calls this helper, which:
#   1. GROUNDING-THEATER guard — the source must be a REGULAR, NON-SYMLINK file of real size
#      (a symlink could smuggle a file from outside the repo or be swapped after the check; a stub
#      satisfies "--spec was passed" while grounding nothing).
#   2. SLUG — derive from the basename and require it to already be a clean slug ([a-z0-9-]); a
#      basename that would be REWRITTEN by __pwt_safe_slug is refused, because then the installed
#      path (docs/specs/<slug>.md) and the router's specd lookup would diverge (sysarch #10b).
#   3. FRESHNESS — plan-w-team-grounding-gate.sh --check --spec <src> --phase review. A PRESENT gate
#      that FAILS refuses loudly. The outcome recorded is TRUTHFUL: pass | skipped:binary-absent |
#      disabled:killswitch — a missing binary or the grounding kill switch is a host/infra decision
#      the GOVERNOR cannot set, so it fail-opens WITHOUT ever claiming `pass` (security #5/#8).
#   4. INSTALL IN-TREE + PROVENANCE — copy the validated source to docs/specs/<slug>.md and append
#      the provenance block to that COPY (never the external source → no out-of-tree write / TOCTOU,
#      security #4). Refuse a silent overwrite of a DIFFERING existing spec. Write a sidecar.
#
# WHY A SEPARATE SCRIPT (not inlined into pwt-goal.sh): (a) one testable chokepoint; (b) a
# governance-tagged surface small enough to file-glob — pwt-goal.sh is too large to tag without
# firing DO-NOT-MERGE on every unrelated edit (security #6). Registered in shared/governance-tags.md.
#
# Usage:  pwt-given-spec.sh validate --spec <path> [--governor <name>] [--min-bytes N]
#   On success: prints exactly `slug=<slug>` and `freshness=<outcome>` (two lines) on stdout,
#   installs docs/specs/<slug>.md + the sidecar, exit 0.
#   On failure: loud stderr, exit 8 (PWT_SPEC_INVALID).
#
# Exit: 0 ok · 2 usage · 8 PWT_SPEC_INVALID. (3/4/5/6/7 are booked in pwt-goal.sh's exit-code
#       registry; 8 is the given-spec refusal — see the registry comment in pwt-goal.sh.)

set -u

SPEC_PATH=""
GOVERNOR=""
MIN_BYTES="${PWT_GIVEN_SPEC_MIN_BYTES:-500}"
SUB="${1:-}"
[ -n "$SUB" ] && shift || true

while [ $# -gt 0 ]; do
    case "$1" in
        --spec)      SPEC_PATH="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --governor)  GOVERNOR="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --min-bytes) MIN_BYTES="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        -h|--help)   SUB="help"; shift ;;
        *)           shift ;;
    esac
done

case "$SUB" in
    validate) : ;;
    help|"") echo "usage: pwt-given-spec.sh validate --spec <path> [--governor <name>] [--min-bytes N]" >&2
             [ "$SUB" = "help" ] && exit 0 || exit 2 ;;
    *) echo "pwt-given-spec: unknown subcommand '$SUB'" >&2; exit 2 ;;
esac

__refuse() { echo "✗ --spec refused (PWT_SPEC_INVALID): $1" >&2; exit 8; }

[ -n "$SPEC_PATH" ] || __refuse "no --spec path given"

# ── (1) grounding-theater guard ──────────────────────────────────────────────
if [ -L "$SPEC_PATH" ]; then
    __refuse "$SPEC_PATH is a symlink — pass the real file path (a symlink can point outside the repo or be swapped after this check)"
fi
[ -f "$SPEC_PATH" ] || __refuse "$SPEC_PATH is not a regular file (missing, or a directory/device)"
__gs_bytes=$(wc -c < "$SPEC_PATH" 2>/dev/null | tr -d ' ')
[ -n "$__gs_bytes" ] || __gs_bytes=0
case "$MIN_BYTES" in *[!0-9]*|"") MIN_BYTES=500 ;; esac
if [ "$__gs_bytes" -lt "$MIN_BYTES" ]; then
    __refuse "$SPEC_PATH is ${__gs_bytes} bytes — a spec under ${MIN_BYTES} bytes cannot carry a grounding ledger + AC contract (grounding theater)"
fi

# ── (2) slug from basename, must already be a clean slug ─────────────────────
__gs_base=$(basename "$SPEC_PATH")
case "$__gs_base" in
    *.md) SLUG="${__gs_base%.md}" ;;
    *) __refuse "$SPEC_PATH is not a .md file — a spec must be docs/specs/<slug>.md" ;;
esac
case "$SLUG" in
    ""|*[!a-z0-9-]*|-*|*-) __refuse "spec basename '$SLUG' is not a clean slug ([a-z0-9-], no leading/trailing '-') — the installed docs/specs/<slug>.md must match the router's specd lookup" ;;
esac

# ── repo root (main checkout wins) ───────────────────────────────────────────
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE%/}"
else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
fi
DEST="$REPO_ROOT/docs/specs/${SLUG}.md"

# ── (3) freshness gate — TRUTHFUL outcome ────────────────────────────────────
GATE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-w-team-grounding-gate.sh"
FRESHNESS="pass"
if [ "${PLAN_W_TEAM_DISABLE_GROUNDING:-0}" = "1" ]; then
    FRESHNESS="disabled:killswitch"
elif [ ! -x "$GATE" ]; then
    FRESHNESS="skipped:binary-absent"
else
    if "$GATE" --check --spec "$SPEC_PATH" --phase review >/dev/null 2>&1; then
        FRESHNESS="pass"
    else
        __refuse "$SPEC_PATH failed the grounding freshness gate (--phase review: missing/blank/uncovered ledger or a surviving ASSUMED row)"
    fi
fi

# ── (4) install in-tree + provenance (to the COPY) + sidecar ─────────────────
mkdir -p "$REPO_ROOT/docs/specs" 2>/dev/null || true
if [ -e "$DEST" ] && ! cmp -s "$SPEC_PATH" "$DEST"; then
    # An existing DIFFERING spec at the destination — refuse a silent overwrite. (A byte-identical
    # existing copy is fine: it means this spec is already installed; re-run is idempotent.)
    if ! grep -q "pwt-given-spec:" "$DEST" 2>/dev/null; then
        __refuse "docs/specs/${SLUG}.md already exists and differs from the supplied spec — refusing a silent overwrite"
    fi
fi
cp "$SPEC_PATH" "$DEST" 2>/dev/null || __refuse "could not install spec to docs/specs/${SLUG}.md"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GOV_LABEL="${GOVERNOR:-operator}"
# Provenance block appended to the COPY (idempotent: only once).
if ! grep -q "pwt-given-spec:" "$DEST" 2>/dev/null; then
    {
        printf '\n<!-- pwt-given-spec: installed by pwt-given-spec.sh -->\n'
        printf '> **Given-spec provenance:** supplied by governor '\''%s'\'' · source %s · freshness-gate=%s · validated_at %s\n' \
            "$GOV_LABEL" "$SPEC_PATH" "$FRESHNESS" "$TS"
    } >> "$DEST" 2>/dev/null || true
fi

# Machine-readable sidecar (dual-seeded to the main state dir; audit-trail).
STATE_DIR="$REPO_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg slug "$SLUG" --arg src "$SPEC_PATH" --arg gov "$GOV_LABEL" \
           --arg fg "$FRESHNESS" --arg ts "$TS" --arg dest "docs/specs/${SLUG}.md" \
        '{slug:$slug, source:$src, governor:$gov, freshness_gate:$fg, installed:$dest, validated_at:$ts}' \
        > "$STATE_DIR/plan-w-team-given-spec-${SLUG}.json" 2>/dev/null || true
fi

printf 'slug=%s\n' "$SLUG"
printf 'freshness=%s\n' "$FRESHNESS"
exit 0
