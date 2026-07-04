#!/usr/bin/env bash
# plan-w-team-reuse-overlap-scan.sh  (M2 — cross-feature / recent-commit overlap)
#
# Lightweight, deterministic, FAIL-OPEN, no-network check run at Step 0. The
# Stage-2 collision gates are intra-run only; nothing checks whether THIS feature
# duplicates a module a prior run / recent commit / sibling spec already added.
# This scan surfaces such overlaps so the lead folds them into the Step-1 Reuse
# Audit (H1). It is ADVISORY — it never blocks (always exits 0).
#
# What it does (all best-effort, fail-open):
#   - greps recent commit subjects (git log) for the given --terms
#   - greps docs/specs/*.md titles/filenames for the given --terms
#   - for each --paths entry, reports the last commit that touched it
#
# Usage:
#   plan-w-team-reuse-overlap-scan.sh --terms "alerting notification" --paths "src/alerts"
#   plan-w-team-reuse-overlap-scan.sh --terms "reuse audit" [--commits 200] [--specs-dir docs/specs]
#
# Flags:
#   --terms   "<space-separated keywords>"   concepts/module nouns to look for
#   --paths   "<space-separated paths>"      module paths this feature will touch
#   --commits <N>                            how many recent commits to scan (default 200)
#   --specs-dir <dir>                        spec directory to scan (default docs/specs)
#
# Exit: ALWAYS 0 (advisory / fail-open). bash 3.2 compatible.

set -u

PROG="plan-w-team-reuse-overlap-scan"
TERMS=""
PATHS=""
COMMITS=200
SPECS_DIR="docs/specs"

while [ $# -gt 0 ]; do
  case "$1" in
    --terms) TERMS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --paths) PATHS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --commits) COMMITS="${2:-200}"; shift; [ $# -gt 0 ] && shift ;;
    --specs-dir) SPECS_DIR="${2:-docs/specs}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32; exit 0 ;;
    *) shift ;;
  esac
done

# Resolve repo root (best-effort; fail-open if not a git repo)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$REPO_ROOT" ]; then
  cd "$REPO_ROOT" 2>/dev/null || true
fi

if [ -z "$TERMS" ] && [ -z "$PATHS" ]; then
  echo "[$PROG] no --terms or --paths given — no overlap signal (advisory, exit 0)"
  exit 0
fi

FOUND=0

# ── 1. recent commit subjects matching a term ────────────────────────────────
if [ -n "$TERMS" ] && command -v git >/dev/null 2>&1 && [ -n "$REPO_ROOT" ]; then
  LOG=$(git log -n "$COMMITS" --pretty='%h %s' 2>/dev/null || echo "")
  if [ -n "$LOG" ]; then
    for t in $TERMS; do
      # skip ultra-short noise tokens
      [ "${#t}" -lt 3 ] && continue
      MATCHES=$(printf '%s\n' "$LOG" | grep -iE "$t" 2>/dev/null | head -3 || true)
      if [ -n "$MATCHES" ]; then
        while IFS= read -r m; do
          [ -z "$m" ] && continue
          echo "overlap(commit): term '$t' → $m"
          FOUND=$((FOUND + 1))
        done <<EOF
$MATCHES
EOF
      fi
    done
  fi
fi

# ── 2. existing specs matching a term (title or filename) ────────────────────
if [ -n "$TERMS" ] && [ -d "$SPECS_DIR" ]; then
  for t in $TERMS; do
    [ "${#t}" -lt 3 ] && continue
    # filename match
    for f in "$SPECS_DIR"/*.md; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      if printf '%s' "$base" | grep -iqE "$t" 2>/dev/null; then
        echo "overlap(spec-name): term '$t' → $f"
        FOUND=$((FOUND + 1))
      elif head -5 "$f" 2>/dev/null | grep -iqE "$t" 2>/dev/null; then
        echo "overlap(spec-title): term '$t' → $f"
        FOUND=$((FOUND + 1))
      fi
    done
  done
fi

# ── 3. paths last touched by a recent commit ─────────────────────────────────
if [ -n "$PATHS" ] && command -v git >/dev/null 2>&1 && [ -n "$REPO_ROOT" ]; then
  for p in $PATHS; do
    LAST=$(git log -n "$COMMITS" --oneline -- "$p" 2>/dev/null | head -1 || true)
    if [ -n "$LAST" ]; then
      echo "overlap(path): '$p' recently touched by → $LAST"
      FOUND=$((FOUND + 1))
    fi
  done
fi

echo ""
if [ "$FOUND" -gt 0 ]; then
  echo "[$PROG] $FOUND overlap signal(s) — fold into the Step-1 Reuse Audit (H1) and decide REUSE/EXTEND/BUILD-NEW for each."
else
  echo "[$PROG] no overlap signal — proceed (advisory)."
fi
exit 0
