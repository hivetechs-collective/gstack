#!/usr/bin/env bash
# plan-w-team-render-artifact.sh
#
# Reusable, self-contained-HTML renderer substrate for /plan-w-team visual
# artifacts. ONE script renders four artifact "kinds" from existing pipeline
# telemetry into a single portable .html file:
#
#   --kind completion   retro run-report (from plan-w-team-completion-<SLUG>.json)
#   --kind comparison   design/approach side-by-side (Hook 2, scope/spec)
#   --kind review       review-findings walkthrough (Hook 3, Step 5)
#   --kind dashboard    live-supervision dashboard  (Hook 4, supervisor-protocol)
#
# HARD REQUIREMENTS (see docs/specs/weave-visual-artifacts-*.md):
#   - Output is ONE self-contained .html: inline <style> + inline <script> +
#     inline SVG / data: only. ZERO external requests (no <link>, no src=,
#     no @import, no http(s):// asset URL). Mirrors the Artifact CSP.
#   - Design tokens: built-in defaults, overridable from a repo CLAUDE.md
#     "## Design system" block, then $PWT_DESIGN_TOKENS_FILE.
#   - FAIL-OPEN: any internal error logs to stderr and exits 0. The renderer
#     can NEVER block its caller. A leaky page is discarded, not emitted.
#   - bash 3.2 compatible (no associative arrays, no mapfile). jq optional
#     (pure-shell degraded fallback for the completion kind).
#
# Usage:
#   plan-w-team-render-artifact.sh --kind <completion|comparison|review|dashboard> \
#       --data <input.json> --out <output.html> [--title <title>]
#
# This script is plan-agnostic and headless-safe. It does NOT use the Artifact
# tool (Max-gated); it is a plain file Write.

set -uo pipefail

# ----------------------------------------------------------------------------
# Fail-open scaffolding: every early return is exit 0. The ONLY non-zero exit
# is a caller-bug usage error before any rendering intent is established.
# ----------------------------------------------------------------------------
log() { printf '[render-artifact] %s\n' "$*" >&2; }

KIND=""
DATA=""
OUT=""
TITLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)  KIND="${2:-}"; shift 2 || { log "missing value for --kind"; exit 0; } ;;
    --data)  DATA="${2:-}"; shift 2 || { log "missing value for --data"; exit 0; } ;;
    --out)   OUT="${2:-}";  shift 2 || { log "missing value for --out"; exit 0; } ;;
    --title) TITLE="${2:-}"; shift 2 || { log "missing value for --title"; exit 0; } ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) log "unknown arg: $1 (ignored)"; shift ;;
  esac
done

# --out is the only structurally-required arg. Without it we have nowhere to
# write — fail-open (exit 0), do nothing.
if [ -z "$OUT" ]; then
  log "no --out given; nothing to render (fail-open)"
  exit 0
fi

case "$KIND" in
  completion|comparison|review|dashboard) : ;;
  "")  log "no --kind given; fail-open"; exit 0 ;;
  *)   log "unknown --kind '$KIND'; fail-open"; exit 0 ;;
esac

# Read the input JSON if present. Missing/empty/unreadable → degraded render
# with placeholders (still a valid page), never an error.
DATA_RAW=""
if [ -n "$DATA" ] && [ -f "$DATA" ] && [ -r "$DATA" ]; then
  DATA_RAW="$(cat "$DATA" 2>/dev/null || true)"
else
  [ -n "$DATA" ] && log "data file '$DATA' missing/unreadable; rendering placeholders"
fi

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi

# If we have jq and data, validate it parses. Invalid JSON → treat as empty.
if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
  if ! printf '%s' "$DATA_RAW" | jq -e . >/dev/null 2>&1; then
    log "data is not valid JSON; rendering placeholders"
    DATA_RAW=""
  fi
fi

[ -z "$TITLE" ] && TITLE="plan-w-team — $KIND"

# ----------------------------------------------------------------------------
# Escape + neutralize. Used for ALL interpolated data so no data value can:
#   (a) inject markup/script (HTML-escape & < > ")
#   (b) introduce a forbidden external-request token in the literal output
#       (http://, https://, src=, @import, <link → already covered by < escape).
# Neutralization is the LAST step so the &-introducing entities are not
# re-escaped. Browser renders &#47; as '/', &#61; as '=', &#64; as '@' — the
# displayed text is identical; only the literal substring is broken up.
# ----------------------------------------------------------------------------
esc() {
  # shellcheck disable=SC2001
  # NOTE: the http(s):// neutralizers use '|' as the sed delimiter because the
  # replacement text contains '#' (e.g. &#47;) — using '#' as the delimiter
  # would terminate the expression early. '|' appears in neither pattern nor
  # replacement, so it is a safe delimiter here.
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' \
          -e 's/</\&lt;/g' \
          -e 's/>/\&gt;/g' \
          -e 's/"/\&quot;/g' \
          -e 's|https://|https:\&#47;\&#47;|g' \
          -e 's|http://|http:\&#47;\&#47;|g' \
          -e 's/src=/src\&#61;/g' \
          -e 's/@import/\&#64;import/g'
}

# ----------------------------------------------------------------------------
# Design tokens. Flat "key=value" lines; last match wins (defaults first, then
# overrides appended). bash-3.2-safe (no associative arrays).
# ----------------------------------------------------------------------------
__tok_defaults() {
  cat <<'EOF'
color-bg=#0f1115
color-surface=#171a21
color-border=#262b34
color-fg=#e6e8eb
color-muted=#9aa4b2
color-primary=#4f8cff
color-ok=#3fb950
color-warn=#d29922
color-err=#f85149
font-sans=-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif
font-mono=ui-monospace,SFMono-Regular,Menlo,Consolas,monospace
radius=10px
space=16px
maxwidth=1040px
EOF
}

# Parse a "## Design system" block out of a markdown file (CLAUDE.md or theme).
# Lines of the form: `- key: value`  (key is kebab [a-z0-9-]).
__tok_from_md() {
  local f="$1"
  [ -f "$f" ] && [ -r "$f" ] || return 0
  awk '
    /^##[[:space:]]+[Dd]esign[[:space:]]+[Ss]ystem[[:space:]]*$/ { flag=1; next }
    /^##[[:space:]]/ { if (flag) flag=0 }
    flag {
      line=$0
      sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
      if (line ~ /^[a-z0-9-]+[[:space:]]*:[[:space:]]*.+/) {
        key=line; sub(/[[:space:]]*:.*$/, "", key)
        val=line; sub(/^[a-z0-9-]+[[:space:]]*:[[:space:]]*/, "", val)
        print key "=" val
      }
    }
  ' "$f" 2>/dev/null || true
}

# Build the resolved token table once (defaults + CLAUDE.md + override file).
TOKENS="$(__tok_defaults)"
if [ -f "CLAUDE.md" ]; then
  EXTRA="$(__tok_from_md "CLAUDE.md")"
  [ -n "$EXTRA" ] && TOKENS="$TOKENS
$EXTRA"
fi
if [ -n "${PWT_DESIGN_TOKENS_FILE:-}" ] && [ -f "${PWT_DESIGN_TOKENS_FILE}" ]; then
  EXTRA="$(__tok_from_md "${PWT_DESIGN_TOKENS_FILE}")"
  [ -n "$EXTRA" ] && TOKENS="$TOKENS
$EXTRA"
fi

# tok <key> → resolved value (last match wins). Values are sanitized: strip
# < > (CSS context can't break out of <style>) and collapse newlines.
tok() {
  local key="$1" v
  v="$(printf '%s\n' "$TOKENS" | grep -E "^${key}=" | tail -1 | cut -d= -f2- | tr -d '<>' | tr '\n' ' ')"
  printf '%s' "$v"
}

# ----------------------------------------------------------------------------
# JSON field helpers (jq when present).
# ----------------------------------------------------------------------------
j() {  # j '<jq filter>' [default]
  local filter="$1" def="${2:-}"
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    local out
    out="$(printf '%s' "$DATA_RAW" | jq -r "$filter // empty" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$def"; fi
  else
    printf '%s' "$def"
  fi
}

# ----------------------------------------------------------------------------
# Shared HTML shell. Tokens become CSS custom properties. No external refs.
# ----------------------------------------------------------------------------
emit_head() {
  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="plan-w-team-render-artifact.sh">
<title>$(esc "$TITLE")</title>
<style>
:root{
 --bg:$(tok color-bg);--surface:$(tok color-surface);--border:$(tok color-border);
 --fg:$(tok color-fg);--muted:$(tok color-muted);--primary:$(tok color-primary);
 --ok:$(tok color-ok);--warn:$(tok color-warn);--err:$(tok color-err);
 --font-sans:$(tok font-sans);--font-mono:$(tok font-mono);
 --radius:$(tok radius);--space:$(tok space);--maxwidth:$(tok maxwidth);
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--font-sans);
 line-height:1.5;-webkit-font-smoothing:antialiased}
.wrap{max-width:var(--maxwidth);margin:0 auto;padding:calc(var(--space)*2) var(--space)}
header.r{border-bottom:1px solid var(--border);padding-bottom:var(--space);margin-bottom:calc(var(--space)*1.5)}
h1{font-size:1.5rem;margin:0 0 .25rem}
h2{font-size:1.05rem;margin:calc(var(--space)*1.5) 0 .5rem;color:var(--fg)}
.meta{color:var(--muted);font-size:.85rem;display:flex;flex-wrap:wrap;gap:.75rem}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);
 padding:var(--space);margin:.5rem 0}
.grid{display:grid;gap:var(--space)}
.grid.cols{grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.badge{display:inline-block;padding:.15rem .55rem;border-radius:999px;font-size:.78rem;
 font-weight:600;border:1px solid var(--border)}
.badge.ok{background:rgba(63,185,80,.15);color:var(--ok);border-color:var(--ok)}
.badge.warn{background:rgba(210,153,34,.15);color:var(--warn);border-color:var(--warn)}
.badge.err{background:rgba(248,81,73,.15);color:var(--err);border-color:var(--err)}
.badge.muted{color:var(--muted)}
.kpi{font-size:1.6rem;font-weight:700}
.kpi small{display:block;font-size:.72rem;font-weight:500;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
ul.tight{margin:.25rem 0;padding-left:1.2rem}
ul.tight li{margin:.1rem 0}
code,.mono{font-family:var(--font-mono);font-size:.85em}
.timeline{list-style:none;margin:0;padding:0}
.timeline li{position:relative;padding:.35rem 0 .35rem 1.25rem;border-left:2px solid var(--border)}
.timeline li::before{content:"";position:absolute;left:-5px;top:.6rem;width:8px;height:8px;
 border-radius:50%;background:var(--primary)}
.sev-critical{color:var(--err);font-weight:700}
.sev-high{color:var(--err)}
.sev-medium{color:var(--warn)}
.sev-low,.sev-info{color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:.88rem}
th,td{text-align:left;padding:.4rem .5rem;border-bottom:1px solid var(--border);vertical-align:top}
th{color:var(--muted);font-weight:600}
pre{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:.6rem;overflow:auto;font-family:var(--font-mono);font-size:.8rem}
footer.r{margin-top:calc(var(--space)*2);padding-top:var(--space);border-top:1px solid var(--border);
 color:var(--muted);font-size:.78rem}
.cmp{display:grid;gap:var(--space);grid-template-columns:repeat(auto-fit,minmax(260px,1fr))}
</style>
</head>
<body>
<div class="wrap">
HTML
}

emit_foot() {
  cat <<HTML
<footer class="r">
Generated by <code>.claude/scripts/plan-w-team-render-artifact.sh</code> · kind=<code>$(esc "$KIND")</code> · self-contained (no external requests) · $(esc "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
</footer>
</div>
<script>
/* Inline-only behavior: collapsible sections. No external resources. */
(function(){
  var hs=document.querySelectorAll('h2[data-toggle]');
  for(var i=0;i<hs.length;i++){
    hs[i].style.cursor='pointer';
    hs[i].addEventListener('click',function(){
      var n=this.nextElementSibling;
      if(n){n.style.display=(n.style.display==='none'?'':'none');}
    });
  }
})();
</script>
</body>
</html>
HTML
}

# ----------------------------------------------------------------------------
# Body builders, one per kind. All fields optional → placeholders if absent.
# ----------------------------------------------------------------------------
badge_for_holistic() {
  case "$1" in
    PASS) printf '<span class="badge ok">HOLISTIC_CHECK PASS</span>' ;;
    FAIL) printf '<span class="badge err">HOLISTIC_CHECK FAIL</span>' ;;
    SKIPPED) printf '<span class="badge muted">HOLISTIC_CHECK SKIPPED</span>' ;;
    *) printf '<span class="badge warn">HOLISTIC_CHECK UNKNOWN</span>' ;;
  esac
}

body_completion() {
  local slug gen skillv specp elapsed hc declared_n passed_n failed_n missing_n
  slug="$(esc "$(j '.slug' "$TITLE")")"
  gen="$(esc "$(j '.generated_at' '—')")"
  skillv="$(esc "$(j '.skill_version' '—')")"
  specp="$(esc "$(j '.spec_path' '—')")"
  elapsed="$(esc "$(j '.duration.elapsed_seconds' '—')")"
  hc="$(j '.ac_rollup.holistic_check' 'UNKNOWN')"
  declared_n="$(j '.ac_rollup.declared | length' '0')"
  passed_n="$(j '.ac_rollup.passed | length' '0')"
  failed_n="$(j '.ac_rollup.failed | length' '0')"
  missing_n="$(j '.ac_rollup.missing | length' '0')"

  cat <<HTML
<header class="r">
<h1>plan-w-team run report</h1>
<div class="meta">
 <span><code>$slug</code></span>
 <span>generated $gen</span>
 <span>skill v$skillv</span>
 <span>spec <code>$specp</code></span>
 <span>elapsed ${elapsed}s</span>
</div>
<div style="margin-top:.6rem">$(badge_for_holistic "$hc")</div>
</header>

<section class="grid cols">
 <div class="card"><div class="kpi">$declared_n<small>AC declared</small></div></div>
 <div class="card"><div class="kpi" style="color:var(--ok)">$passed_n<small>AC passed</small></div></div>
 <div class="card"><div class="kpi" style="color:var(--err)">$failed_n<small>AC failed</small></div></div>
 <div class="card"><div class="kpi" style="color:var(--warn)">$missing_n<small>AC missing</small></div></div>
</section>
HTML

  # AC lists
  echo '<h2 data-toggle>Acceptance Criteria</h2><div class="card">'
  _ac_list() {
    local path="$1" label="$2" cls="$3" line
    echo "<strong class=\"$cls\">$label</strong><ul class=\"tight\">"
    if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
      printf '%s' "$DATA_RAW" | jq -r "$path[]? // empty" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && printf '<li>%s</li>\n' "$(esc "$line")"
      done
    fi
    echo '</ul>'
  }
  _ac_list '.ac_rollup.passed'  'Passed'  'sev-info'
  _ac_list '.ac_rollup.failed'  'Failed'  'sev-high'
  _ac_list '.ac_rollup.missing' 'Missing' 'sev-medium'
  echo '</div>'

  # Stage timeline
  echo '<h2 data-toggle>Stage timeline</h2><div class="card"><ul class="timeline">'
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    printf '%s' "$DATA_RAW" | jq -r '.stages[]? | (.label // .) | tostring' 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && printf '<li>%s</li>\n' "$(esc "$line")"
    done
  fi
  echo '</ul></div>'

  # Git activity
  local files_changed ins dels diffsum base head
  files_changed="$(esc "$(j '.git.files_changed' '0')")"
  ins="$(esc "$(j '.git.insertions' '0')")"
  dels="$(esc "$(j '.git.deletions' '0')")"
  diffsum="$(esc "$(j '.git.diff_stat_summary' '—')")"
  base="$(esc "$(j '.git.base_commit' '—')")"
  head="$(esc "$(j '.git.head_commit' '—')")"
  cat <<HTML
<h2 data-toggle>Git activity</h2>
<div class="card">
 <div class="meta"><span>files changed: $files_changed</span><span style="color:var(--ok)">+$ins</span><span style="color:var(--err)">-$dels</span></div>
 <p class="mono">$diffsum</p>
 <div class="meta"><span>base <code>$base</code></span><span>head <code>$head</code></span></div>
 <ul class="tight">
HTML
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    printf '%s' "$DATA_RAW" | jq -r '.git.commits[]? | "\(.hash // "?") \(.subject // "")"' 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && printf '<li><code>%s</code></li>\n' "$(esc "$line")"
    done
  fi
  echo '</ul></div>'

  # Tests + ship verdict
  local tcount ship_v ship_e
  tcount="$(esc "$(j '.tests.added_or_modified_files' '0')")"
  ship_v="$(j '.ship.verdict' 'UNKNOWN')"
  ship_e="$(esc "$(j '.ship.evidence_line' '—')")"
  local ship_cls="warn"
  case "$ship_v" in PASS) ship_cls="ok" ;; FAIL) ship_cls="err" ;; esac
  cat <<HTML
<h2 data-toggle>Tests &amp; ship</h2>
<div class="card">
 <p>Test files added/modified: <strong>$tcount</strong></p>
 <p>Ship verdict: <span class="badge $ship_cls">$(esc "$ship_v")</span></p>
 <p class="mono">$ship_e</p>
</div>
HTML
}

body_comparison() {
  local title; title="$(esc "$(j '.title' "$TITLE")")"
  cat <<HTML
<header class="r"><h1>$title</h1>
<div class="meta"><span>design / approach comparison</span></div></header>
<section class="cmp">
HTML
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    local n i
    n="$(printf '%s' "$DATA_RAW" | jq -r '.options | length' 2>/dev/null || echo 0)"
    [ -z "$n" ] && n=0
    i=0
    while [ "$i" -lt "$n" ]; do
      local name notes
      name="$(esc "$(printf '%s' "$DATA_RAW" | jq -r ".options[$i].name // \"option $i\"" 2>/dev/null)")"
      notes="$(esc "$(printf '%s' "$DATA_RAW" | jq -r ".options[$i].notes // \"\"" 2>/dev/null)")"
      echo "<div class=\"card\"><h2>$name</h2>"
      [ -n "$notes" ] && echo "<p class=\"meta\">$notes</p>"
      echo '<strong class="sev-info">Pros</strong><ul class="tight">'
      printf '%s' "$DATA_RAW" | jq -r ".options[$i].pros[]? // empty" 2>/dev/null | while IFS= read -r p; do
        [ -n "$p" ] && printf '<li>%s</li>\n' "$(esc "$p")"
      done
      echo '</ul><strong class="sev-medium">Cons</strong><ul class="tight">'
      printf '%s' "$DATA_RAW" | jq -r ".options[$i].cons[]? // empty" 2>/dev/null | while IFS= read -r c; do
        [ -n "$c" ] && printf '<li>%s</li>\n' "$(esc "$c")"
      done
      echo '</ul></div>'
      i=$((i+1))
    done
  fi
  echo '</section>'
  [ "$HAVE_JQ" != "1" ] && echo '<div class="card">jq unavailable — comparison data not rendered (fail-open).</div>'
}

body_review() {
  local title; title="$(esc "$(j '.title' "$TITLE")")"
  cat <<HTML
<header class="r"><h1>$title</h1>
<div class="meta"><span>review findings walkthrough</span></div></header>
<table><thead><tr><th>Severity</th><th>Location</th><th>Finding</th></tr></thead><tbody>
HTML
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    local n i
    n="$(printf '%s' "$DATA_RAW" | jq -r '.findings | length' 2>/dev/null || echo 0)"
    [ -z "$n" ] && n=0
    i=0
    while [ "$i" -lt "$n" ]; do
      local sev loc note exc
      sev="$(printf '%s' "$DATA_RAW" | jq -r ".findings[$i].severity // \"info\"" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
      loc="$(esc "$(printf '%s' "$DATA_RAW" | jq -r ".findings[$i].file // \"—\"" 2>/dev/null):$(printf '%s' "$DATA_RAW" | jq -r ".findings[$i].line // \"\"" 2>/dev/null)")"
      note="$(esc "$(printf '%s' "$DATA_RAW" | jq -r ".findings[$i].note // \"\"" 2>/dev/null)")"
      exc="$(esc "$(printf '%s' "$DATA_RAW" | jq -r ".findings[$i].excerpt // \"\"" 2>/dev/null)")"
      printf '<tr><td><span class="sev-%s">%s</span></td><td class="mono">%s</td><td>%s' \
        "$(esc "$sev")" "$(esc "$sev")" "$loc" "$note"
      [ -n "$exc" ] && printf '<pre>%s</pre>' "$exc"
      printf '</td></tr>\n'
      i=$((i+1))
    done
  fi
  echo '</tbody></table>'
  [ "$HAVE_JQ" != "1" ] && echo '<div class="card">jq unavailable — findings not rendered (fail-open).</div>'
}

body_dashboard() {
  local slug term goal_state
  slug="$(esc "$(j '.slug' "$TITLE")")"
  term="$(j '.terminal_state' 'running')"
  cat <<HTML
<header class="r"><h1>live supervision</h1>
<div class="meta"><span><code>$slug</code></span><span>state: $(esc "${term:-running}")</span></div></header>
<section class="grid cols">
 <div class="card"><div class="kpi">$(esc "$(j '.progress.tasks_done' '—')")<small>tasks done</small></div></div>
 <div class="card"><div class="kpi">$(esc "$(j '.progress.tasks_total' '—')")<small>tasks total</small></div></div>
 <div class="card"><div class="kpi">$(esc "$(j '.fleet | length' '0')")<small>fleet events</small></div></div>
 <div class="card"><div class="kpi">$(esc "$(j '.stages | length' '0')")<small>stages seen</small></div></div>
</section>
<h2 data-toggle>Stage timeline</h2><div class="card"><ul class="timeline">
HTML
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    printf '%s' "$DATA_RAW" | jq -r '.stages[]? | (.stage // .label // .) | tostring' 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && printf '<li>%s</li>\n' "$(esc "$line")"
    done
  fi
  echo '</ul></div>'
  echo '<h2 data-toggle>Fleet</h2><div class="card"><ul class="tight">'
  if [ "$HAVE_JQ" = "1" ] && [ -n "$DATA_RAW" ]; then
    printf '%s' "$DATA_RAW" | jq -r '.fleet[]? | "\(.event // "?") \(.agent_type // .agent_id // "")"' 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] && printf '<li class="mono">%s</li>\n' "$(esc "$line")"
    done
  fi
  echo '</ul></div>'
}

# ----------------------------------------------------------------------------
# Render to a temp file, run the self-containment self-check, then atomically
# move into place. A leaky page (template bug) is DISCARDED, never emitted.
# ----------------------------------------------------------------------------
TMP="$(mktemp "${TMPDIR:-/tmp}/pwt-render.XXXXXX" 2>/dev/null || echo "${OUT}.tmp.$$")"

{
  emit_head
  case "$KIND" in
    completion) body_completion ;;
    comparison) body_comparison ;;
    review)     body_review ;;
    dashboard)  body_dashboard ;;
  esac
  emit_foot
} > "$TMP" 2>/dev/null || {
  log "render failed mid-build; discarding partial output (fail-open)"
  rm -f "$TMP" 2>/dev/null || true
  exit 0
}

# Self-containment check: the finished page must contain NO external-request
# construct. Data is already neutralized by esc(); a hit here means a template
# bug. Discard rather than emit a leaky page.
if grep -Eq 'https?://|<link|src=|@import' "$TMP" 2>/dev/null; then
  log "self-containment check FAILED (external-request token in output) — discarding (fail-open)"
  rm -f "$TMP" 2>/dev/null || true
  exit 0
fi

# Move into place. mkdir the parent if needed (best-effort).
OUT_DIR="$(dirname "$OUT")"
[ -d "$OUT_DIR" ] || mkdir -p "$OUT_DIR" 2>/dev/null || true
if mv "$TMP" "$OUT" 2>/dev/null; then
  log "rendered $KIND → $OUT"
else
  log "could not write $OUT (fail-open); cleaning up"
  rm -f "$TMP" 2>/dev/null || true
fi

exit 0
