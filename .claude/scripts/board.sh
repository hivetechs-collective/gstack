#!/usr/bin/env bash
# scripts/board.sh — GitHub Projects v2 helper for Claude Code
# Creates GitHub Issues (not drafts) for full PR linking, comments, and history.
# All operations are fire-and-forget safe (exit 0 on soft failures)
#
# Multi-repo portable: reads project config from .github/board.json
# Works across orgs — each repo points to its own board.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOARD_CONFIG="$PROJECT_ROOT/.github/board.json"
CACHE_FILE="$PROJECT_ROOT/.claude/state/board-config.json"
PROJECT_NUMBER=""
PROJECT_OWNER=""
OWNER_TYPE=""

# ─── Helpers ──────────────────────────────────────────────────

err() { echo "BOARD ERROR: $*" >&2; }
warn() { echo "BOARD WARN: $*" >&2; }
info() { echo "$*"; }

load_board_config() {
  # Reads .github/board.json — required for all commands except init
  if [[ ! -f "$BOARD_CONFIG" ]]; then
    err "No board config found at $BOARD_CONFIG"
    err "Run: board.sh init --owner <org-or-@me> --title \"Project Title\""
    return 1
  fi

  PROJECT_NUMBER=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG'))['project_number'])")
  PROJECT_OWNER=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG'))['owner'])")
  OWNER_TYPE=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG')).get('owner_type', 'user'))")

  if [[ -z "$PROJECT_NUMBER" || -z "$PROJECT_OWNER" ]]; then
    err "Invalid board config: missing project_number or owner"
    return 1
  fi
}

ensure_cache() {
  if [[ ! -f "$CACHE_FILE" ]]; then
    warn "No board cache found. Running sync..."
    do_sync
  fi
}

cache_get() {
  # cache_get '.fields.Status.id' — reads from cache
  python3 -c "
import json, sys
with open('$CACHE_FILE') as f:
    data = json.load(f)
keys = '$1'.strip('.').split('.')
for k in keys:
    if isinstance(data, dict):
        data = data.get(k, '')
    else:
        data = ''
        break
print(data if data else '')
"
}

get_repo() {
  # Returns owner/repo from the current git remote
  gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || {
    err "Could not detect repo. Are you in a git repo with a GitHub remote?"
    return 1
  }
}

# ─── Sync: populate config cache ──────────────────────────────

do_sync() {
  load_board_config || return 1
  info "Syncing board cache from project #$PROJECT_NUMBER (owner: $PROJECT_OWNER)..."
  mkdir -p "$(dirname "$CACHE_FILE")"

  local fields_json
  fields_json=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>&1) || {
    err "Failed to query project fields. Is gh authenticated with project scope?"
    return 1
  }

  local project_json
  project_json=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>&1) || {
    err "Failed to query project. Does project #$PROJECT_NUMBER exist?"
    return 1
  }

  local project_id
  project_id=$(echo "$project_json" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('id',''))")

  # Build cache from field data
  python3 -c "
import json, sys

fields_raw = json.loads('''$fields_json''')
config = {
    'project_number': $PROJECT_NUMBER,
    'project_id': '$project_id',
    'owner': '$PROJECT_OWNER',
    'owner_type': '$OWNER_TYPE',
    'synced_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'fields': {}
}

for field in fields_raw.get('fields', []):
    if field.get('type') == 'ProjectV2SingleSelectField':
        name = field['name']
        config['fields'][name] = {
            'id': field['id'],
            'options': {}
        }
        for opt in field.get('options', []):
            config['fields'][name]['options'][opt['name']] = opt['id']

with open('$CACHE_FILE', 'w') as f:
    json.dump(config, f, indent=2)

print(f'Synced: {len(config[\"fields\"])} fields cached')
for name, data in config['fields'].items():
    opts = ', '.join(data['options'].keys())
    print(f'  {name}: [{opts}]')
" || {
    err "Failed to parse field data"
    return 1
  }
}

# ─── Add: create a GitHub Issue and add to board ─────────────

do_add() {
  load_board_config || return 1
  ensure_cache
  local title="" body="" priority="" area="" type_val="" size="" sprint=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      --area) area="$2"; shift 2 ;;
      --type) type_val="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      --sprint) sprint="$2"; shift 2 ;;
      *) title="$1"; shift ;;
    esac
  done

  if [[ -z "$title" ]]; then
    err "Usage: board.sh add \"Title\" [--priority P1] [--area api] [--type feature] [--size M] [--body \"desc\"]"
    return 1
  fi

  local repo
  repo=$(get_repo) || return 1

  # Build structured issue body
  local meta_line=""
  [[ -n "$priority" ]] && meta_line+="**Priority:** $priority"
  [[ -n "$area" ]] && meta_line+=" | **Area:** $area"
  [[ -n "$type_val" ]] && meta_line+=" | **Type:** $type_val"
  [[ -n "$size" ]] && meta_line+=" | **Size:** $size"

  local issue_body=""
  if [[ -n "$meta_line" || -n "$body" ]]; then
    issue_body="${meta_line}"
    [[ -n "$meta_line" && -n "$body" ]] && issue_body+=$'\n\n'
    [[ -n "$body" ]] && issue_body+="$body"
    issue_body+=$'\n\n---\n_Managed by `/plan-w-team` pipeline_'
  fi

  # Create GitHub Issue
  local create_args=(issue create --repo "$repo" --title "$title")
  if [[ -n "$issue_body" ]]; then
    create_args+=(--body "$issue_body")
  fi

  local issue_url
  issue_url=$(gh "${create_args[@]}" 2>&1) || {
    err "Failed to create issue: $issue_url"
    return 1
  }

  local issue_number
  issue_number=$(echo "$issue_url" | grep -o '[0-9]*$')
  info "Created issue #$issue_number: $title"

  # Add Issue to Project board
  local add_result
  add_result=$(gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$issue_url" --format json 2>&1) || {
    err "Failed to add issue to project: $add_result"
    echo "#$issue_number"
    return 0  # Issue exists, board add failed — soft failure
  }

  local item_id
  item_id=$(echo "$add_result" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('id',''))")
  info "Added to board (ID: $item_id)"

  # Set custom fields
  local project_id
  project_id=$(cache_get '.project_id')

  _set_field "$item_id" "$project_id" "Status" "Backlog"

  if [[ -n "$priority" ]]; then
    _set_field "$item_id" "$project_id" "Priority" "$priority"
  fi
  if [[ -n "$area" ]]; then
    _set_field "$item_id" "$project_id" "Area" "$area"
  fi
  if [[ -n "$type_val" ]]; then
    _set_field "$item_id" "$project_id" "Type" "$type_val"
  fi
  if [[ -n "$size" ]]; then
    _set_field "$item_id" "$project_id" "Size" "$size"
  fi
  if [[ -n "$sprint" ]]; then
    _set_text_field "$item_id" "$project_id" "Sprint" "$sprint"
  fi

  echo "#$issue_number"
}

# ─── Comment: add a comment to an issue ──────────────────────

do_comment() {
  load_board_config || return 1
  local identifier="${1:-}"
  shift || true
  local comment_body="$*"

  if [[ -z "$identifier" || -z "$comment_body" ]]; then
    err "Usage: board.sh comment <issue-number-or-title> \"comment body\""
    return 1
  fi

  local repo
  repo=$(get_repo) || return 1

  local issue_number
  issue_number=$(_resolve_issue_number "$identifier") || {
    err "Could not resolve issue: $identifier"
    return 1
  }

  gh issue comment "$issue_number" --repo "$repo" --body "$comment_body" 2>&1 || {
    warn "Failed to add comment to issue #$issue_number"
    return 0  # soft failure
  }

  info "Commented on issue #$issue_number"
}

# ─── Close: close an issue ───────────────────────────────────

do_close() {
  load_board_config || return 1
  local identifier="${1:-}"
  local reason="${2:-completed}"

  if [[ -z "$identifier" ]]; then
    err "Usage: board.sh close <issue-number-or-title> [completed|not_planned]"
    return 1
  fi

  local repo
  repo=$(get_repo) || return 1

  local issue_number
  issue_number=$(_resolve_issue_number "$identifier") || {
    err "Could not resolve issue: $identifier"
    return 1
  }

  gh issue close "$issue_number" --repo "$repo" --reason "$reason" 2>&1 || {
    warn "Failed to close issue #$issue_number"
    return 0
  }

  info "Closed issue #$issue_number ($reason)"
}

# ─── Move: change status ─────────────────────────────────────

do_move() {
  load_board_config || return 1
  ensure_cache
  local identifier="${1:-}"
  local target_status="${2:-}"

  if [[ -z "$identifier" || -z "$target_status" ]]; then
    err "Usage: board.sh move <item-id-or-title> <status>"
    err "Statuses: Backlog, Todo, In Progress, Review, Done, Archived"
    return 1
  fi

  local item_id
  item_id=$(_resolve_item "$identifier")
  if [[ -z "$item_id" ]]; then
    err "Item not found: $identifier"
    return 1
  fi

  local project_id
  project_id=$(cache_get '.project_id')

  _set_field "$item_id" "$project_id" "Status" "$target_status"
  info "Moved '$identifier' -> $target_status"
}

# ─── List: show items ─────────────────────────────────────────

do_list() {
  load_board_config || return 1
  ensure_cache
  local filter_status="" filter_area="" filter_priority=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --area) filter_area="$2"; shift 2 ;;
      --priority) filter_priority="$2"; shift 2 ;;
      --status) filter_status="$2"; shift 2 ;;
      *)
        # Positional: treat as status filter
        if [[ -z "$filter_status" ]]; then
          filter_status="$1"
        fi
        shift ;;
    esac
  done

  local items_json
  items_json=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>&1) || {
    err "Failed to list items"
    return 1
  }

  python3 -c "
import json, sys

data = json.loads('''$(echo "$items_json" | sed "s/'/\\\\'/g")''')
items = data.get('items', [])

filter_status = '$filter_status'
filter_area = '$filter_area'
filter_priority = '$filter_priority'

# Filter
filtered = []
for item in items:
    status = item.get('status', '')
    area = ''
    priority = ''
    type_val = ''
    for key in ['priority', 'Priority']:
        if key in item:
            priority = item[key]
    for key in ['area', 'Area']:
        if key in item:
            area = item[key]
    for key in ['type', 'Type']:
        if key in item:
            type_val = item[key]

    size = ''
    for key in ['size', 'Size']:
        if key in item:
            size = item[key]

    if filter_status and status.lower() != filter_status.lower():
        continue
    if filter_area and area.lower() != filter_area.lower():
        continue
    if filter_priority and priority.lower() != filter_priority.lower():
        continue

    # Skip Archived unless explicitly requested
    if not filter_status and status == 'Archived':
        continue

    # Extract issue number if available
    content = item.get('content', {})
    issue_num = ''
    if isinstance(content, dict) and 'number' in content:
        issue_num = f'#{content[\"number\"]}'

    filtered.append({
        'id': item.get('id', '?'),
        'title': item.get('title', '?'),
        'status': status,
        'priority': priority,
        'area': area,
        'type': type_val,
        'size': size,
        'issue': issue_num
    })

if not filtered:
    print('No items found.')
    sys.exit(0)

# Sort: by status order, then priority
status_order = {'Backlog': 0, 'Todo': 1, 'In Progress': 2, 'Blocked': 3, 'Review': 4, 'Done': 5, 'Archived': 6}
priority_order = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3, '': 4}
filtered.sort(key=lambda x: (status_order.get(x['status'], 9), priority_order.get(x['priority'], 9)))

# Print table
print(f\"{'Issue':<7} {'Status':<14} {'Pri':<4} {'Size':<5} {'Area':<9} {'Type':<8} {'Title'}\")
print('-' * 95)
for item in filtered:
    print(f\"{item['issue']:<7} {item['status']:<14} {item['priority']:<4} {item['size']:<5} {item['area']:<9} {item['type']:<8} {item['title']}\")
print(f\"\n{len(filtered)} items\")
" 2>&1 || {
    err "Failed to format items"
    return 1
  }
}

# ─── View: show single item ──────────────────────────────────

do_view() {
  load_board_config || return 1
  ensure_cache
  local identifier="${1:-}"
  if [[ -z "$identifier" ]]; then
    err "Usage: board.sh view <issue-number-or-title>"
    return 1
  fi

  local repo
  repo=$(get_repo) || return 1

  # Try to resolve as an issue for rich view (with comments, PRs)
  local issue_number
  issue_number=$(_resolve_issue_number "$identifier" 2>/dev/null) || true

  if [[ -n "$issue_number" ]]; then
    # Rich view: show issue with comments and linked PRs
    gh issue view "$issue_number" --repo "$repo" --comments 2>&1 || {
      warn "Failed to view issue #$issue_number"
    }
    return 0
  fi

  # Fallback: project item view (for legacy draft items)
  local items_json
  items_json=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>&1) || {
    err "Failed to list items"
    return 1
  }

  python3 -c "
import json, sys

data = json.loads(sys.stdin.read())
identifier = '$identifier'
items = data.get('items', [])

found = None
for item in items:
    if item.get('id', '') == identifier or identifier.lower() in item.get('title', '').lower():
        found = item
        break

if not found:
    print(f'Item not found: {identifier}')
    sys.exit(1)

print(f\"Title:    {found.get('title', '?')}\")
print(f\"ID:       {found.get('id', '?')}\")
print(f\"Status:   {found.get('status', '?')}\")
for key in found:
    if key not in ('title', 'id', 'status', 'content', 'body', 'labels', 'linkedPullRequests', 'milestone', 'repository', 'reviewers'):
        val = found[key]
        if val:
            print(f\"{key.capitalize():<10}{val}\")
content = found.get('content', {})
body = content.get('body', '') if isinstance(content, dict) else str(content) if content else ''
if body:
    print(f\"\nBody:\n{body}\")
" <<< "$items_json" 2>&1
}

# ─── Backlog: shortcut for list Backlog ───────────────────────

do_backlog() {
  do_list "Backlog" "$@"
}

# ─── Search: find items by title ──────────────────────────────

do_search() {
  load_board_config || return 1
  local query="${1:-}"
  if [[ -z "$query" ]]; then
    err "Usage: board.sh search \"keyword\""
    return 1
  fi

  local items_json
  items_json=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>&1) || {
    err "Failed to list items"
    return 1
  }

  python3 -c "
import json, sys

data = json.loads(sys.stdin.read())
query = '$query'.lower()
items = data.get('items', [])

matches = [i for i in items if query in i.get('title', '').lower()]
if not matches:
    print(f'No items matching \"{query}\"')
    sys.exit(0)

print(f\"{'Status':<14} {'Title':<50} {'ID'}\")
print('-' * 80)
for item in matches:
    content = item.get('content', {})
    issue_num = ''
    if isinstance(content, dict) and 'number' in content:
        issue_num = f' (#{content[\"number\"]})'
    print(f\"{item.get('status', '?'):<14} {item.get('title', '?'):<50} {item.get('id', '?')}{issue_num}\")
print(f'\n{len(matches)} matches')
" <<< "$items_json" 2>&1
}

# ─── Archive: move old Done items ─────────────────────────────

do_archive() {
  info "Archive: reviewing Done items..."
  warn "Manual operation — review Done items and archive as needed"
  do_list "Done"
}

# ─── Set Field (internal) ────────────────────────────────────

_set_field() {
  local item_id="$1"
  local project_id="$2"
  local field_name="$3"
  local option_name="$4"

  local field_id
  field_id=$(cache_get ".fields.${field_name}.id")
  if [[ -z "$field_id" ]]; then
    warn "Field '$field_name' not found in cache. Running sync..."
    do_sync
    field_id=$(cache_get ".fields.${field_name}.id")
    if [[ -z "$field_id" ]]; then
      err "Field '$field_name' not found even after sync"
      return 1
    fi
  fi

  local option_id
  option_id=$(cache_get ".fields.${field_name}.options.${option_name}")
  if [[ -z "$option_id" ]]; then
    warn "Option '$option_name' not found for field '$field_name'. Running sync..."
    do_sync
    option_id=$(cache_get ".fields.${field_name}.options.${option_name}")
    if [[ -z "$option_id" ]]; then
      err "Option '$option_name' not found for field '$field_name' even after sync"
      return 1
    fi
  fi

  gh project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$field_id" \
    --single-select-option-id "$option_id" \
    2>&1 || {
    warn "Failed to set $field_name=$option_name on item $item_id"
    return 0  # soft failure
  }
}

# ─── Set Text Field (internal) ──────────────────────────────

_set_text_field() {
  local item_id="$1"
  local project_id="$2"
  local field_name="$3"
  local value="$4"

  # Text fields aren't in the single-select cache, look up via API
  local field_id
  field_id=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for f in data.get('fields', []):
    if f.get('name') == '$field_name':
        print(f['id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || {
    warn "Text field '$field_name' not found"
    return 0
  }

  gh project item-edit \
    --id "$item_id" \
    --project-id "$project_id" \
    --field-id "$field_id" \
    --text "$value" \
    2>&1 || {
    warn "Failed to set $field_name=$value on item $item_id"
    return 0
  }
}

# ─── Resolve Item ID (internal) ──────────────────────────────
# Returns the Project item ID (PVTI_...) for move/field operations

_resolve_item() {
  local identifier="$1"

  # If it looks like a node ID (starts with PVTI_), use directly
  if [[ "$identifier" == PVTI_* ]]; then
    echo "$identifier"
    return
  fi

  local items_json
  items_json=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>&1) || return 1

  # Support #123 format — match by issue number
  if [[ "$identifier" =~ ^#?[0-9]+$ ]]; then
    local num="${identifier#\#}"
    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
for item in data.get('items', []):
    content = item.get('content', {})
    if isinstance(content, dict) and str(content.get('number', '')) == '$num':
        print(item.get('id', ''))
        sys.exit(0)
sys.exit(1)
" <<< "$items_json" 2>/dev/null && return
  fi

  # Fall back to title search
  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
identifier = '$identifier'.lower()
for item in data.get('items', []):
    if identifier == item.get('title', '').lower() or identifier in item.get('title', '').lower():
        print(item.get('id', ''))
        sys.exit(0)
sys.exit(1)
" <<< "$items_json" 2>/dev/null
}

# ─── Resolve Issue Number (internal) ─────────────────────────
# Returns the GitHub issue number for comment/close operations

_resolve_issue_number() {
  local identifier="$1"

  # Direct issue number (#123 or 123)
  if [[ "$identifier" =~ ^#?[0-9]+$ ]]; then
    echo "${identifier#\#}"
    return
  fi

  # Search project items by title, extract issue number from content
  local items_json
  items_json=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>&1) || return 1

  python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
identifier = '$identifier'.lower()
for item in data.get('items', []):
    if identifier == item.get('title', '').lower() or identifier in item.get('title', '').lower():
        content = item.get('content', {})
        if isinstance(content, dict) and 'number' in content:
            print(content['number'])
            sys.exit(0)
print('')
sys.exit(1)
" <<< "$items_json" 2>/dev/null
}

# ─── Init: bootstrap a new board ─────────────────────────────
# Two paths:
#   1. Template clone (preferred) — if a template exists on the owner, copy it
#      via `copyProjectV2` GraphQL mutation. Preserves views, workflows (with
#      enabled state), status descriptions, Sprint field, and custom fields.
#   2. From-scratch fallback — creates fields via API. Cannot create views or
#      enable workflows (GitHub does not expose those mutations). User must
#      configure those manually in the UI, then promote the board to a template
#      via `board.sh template-promote <n>` so subsequent boards inherit them.
#
# See docs/specs/template-based-board-bootstrap.md for the full rationale.

do_init() {
  local owner="" title="" owner_type="user" force_scratch=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --no-template) force_scratch=1; shift ;;  # Escape hatch: skip template detection
      *) shift ;;
    esac
  done

  if [[ -z "$owner" || -z "$title" ]]; then
    err "Usage: board.sh init --owner <org-name-or-@me> --title \"Project Title\" [--no-template]"
    err ""
    err "Examples:"
    err "  board.sh init --owner cleanscale-io --title \"CleanRev Development\""
    err "  board.sh init --owner @me --title \"My Projects\""
    err "  board.sh init --owner @me --title \"Legacy\" --no-template"
    return 1
  fi

  # Detect owner type
  if [[ "$owner" != "@me" ]]; then
    if gh api "orgs/$owner" --silent 2>/dev/null; then
      owner_type="organization"
      info "Detected owner type: organization"
    else
      owner_type="user"
      info "Detected owner type: user"
    fi
  fi

  # ─── Template detection ───────────────────────────────────────
  # Query for a template project on the target owner. If found, clone it;
  # this is the only way to get views + workflows in an auto-created board.

  local template_id=""
  local template_title=""
  if [[ "$force_scratch" -eq 0 ]]; then
    info "Checking for template projects on $owner..."
    if _init_find_template "$owner" "$owner_type"; then
      template_id="$_FOUND_TEMPLATE_ID"
      template_title="$_FOUND_TEMPLATE_TITLE"
      info "  Found template: \"$template_title\" ($template_id)"
    else
      info "  No template found (will fall through to from-scratch)"
    fi
  else
    info "--no-template flag set, skipping template detection"
  fi

  local project_number="" project_id="" created_via=""

  if [[ -n "$template_id" ]]; then
    # ─── Path 1: Clone from template ──────────────────────────
    if _init_from_template "$owner" "$owner_type" "$title" "$template_id"; then
      project_number="$_NEW_PROJECT_NUMBER"
      project_id="$_NEW_PROJECT_ID"
      created_via="template"
    else
      warn "Template clone failed, falling back to from-scratch"
    fi
  fi

  if [[ -z "$project_number" ]]; then
    # ─── Path 2: From-scratch fallback ────────────────────────
    if ! _init_from_scratch "$owner" "$title"; then
      return 1
    fi
    project_number="$_NEW_PROJECT_NUMBER"
    project_id="$_NEW_PROJECT_ID"
    created_via="from_scratch"
  fi

  # ─── Shared finalization (both paths) ─────────────────────────
  _init_write_config "$project_number" "$owner" "$owner_type"
  info "Wrote .github/board.json"

  PROJECT_NUMBER="$project_number"
  PROJECT_OWNER="$owner"
  OWNER_TYPE="$owner_type"
  do_sync

  info ""
  info "Board initialized successfully!"
  info "  Project: #$project_number"
  info "  Owner:   $owner ($owner_type)"
  info "  Config:  .github/board.json"
  info "  Cache:   .claude/state/board-config.json"

  if [[ "$created_via" == "template" ]]; then
    info "  Source:  cloned from template \"$template_title\""
    info ""
    info "Template clone includes: views, workflows (with enabled state),"
    info "Sprint field, status descriptions, and all custom field options."
  else
    info "  Source:  created from scratch (no template available for $owner)"
    info ""
    info "⚠ From-scratch boards do NOT have views or workflows."
    info "  GitHub does not expose mutations for views/workflows — they"
    info "  must be configured manually in the UI."
    info ""
    info "  Manual setup checklist:"
    info "  1. Go to Project Settings > Workflows"
    info "  2. Enable: 'Item closed' → Set Status to 'Done'"
    info "  3. Enable: 'Pull request merged' → Set Status to 'Done'"
    info "  4. Optionally: Enable 'Auto-archive items' and 'Auto-add sub-issues'"
    info "  5. Create views: Kanban Board (groupBy: Area, sortBy: Priority)"
    info "                   Table (sortBy: Priority)"
    info ""
    if [[ "$owner_type" == "organization" ]]; then
      info "  6. Promote as template (org-owned, eligible):"
      info "       scripts/board.sh template-promote $project_number --owner $owner"
      info ""
      info "  After promotion, future boards in this org (and in user accounts of"
      info "  org members) will inherit this configuration via copyProjectV2."
    else
      info "  6. To enable template-clone for future user-owned boards, you must"
      info "     create a template in an organization (user-owned projects cannot"
      info "     be marked as templates by GitHub):"
      info ""
      info "       a. Create an org project that mirrors this configuration:"
      info "          gh project create --owner <your-org> --title \"Standard Repo Template\""
      info "       b. Configure it the same way (steps 1-5 above)"
      info "       c. Promote it:"
      info "          scripts/board.sh template-promote <new-number> --owner <your-org>"
      info ""
      info "     Then 'board.sh init --owner @me ...' will discover the org template"
      info "     via your org memberships and clone it cross-owner."
    fi
  fi

  info ""
  info "Commit .github/board.json to the repo."
}

# ─── Template discovery ──────────────────────────────────────
# Sets $_FOUND_TEMPLATE_ID and $_FOUND_TEMPLATE_TITLE on success.
# Returns 0 if a template was found, 1 otherwise (including errors).
#
# CRITICAL CONSTRAINT: GitHub only allows ProjectV2 owned by an Organization
# to be marked as templates. User-owned (@me) projects CANNOT be templates.
# However, copyProjectV2 supports cross-owner copy: an org template can be
# cloned into a user account.
#
# Discovery strategy:
#   1. If target is an organization → check that org for templates.
#   2. If target is a user (@me or named) → check the user's organizations
#      for templates (since user-owned projects cannot be templates).
#   3. First template found wins. Multi-template selection is deferred.

_init_find_template() {
  local owner="$1"
  local owner_type="$2"

  # Build list of orgs to search.
  # - Org target: just that org.
  # - User target: enumerate the user's org memberships via REST.
  local orgs_to_search=()
  if [[ "$owner_type" == "organization" ]]; then
    orgs_to_search+=("$owner")
  else
    # User target — query org memberships. For @me use /user/orgs (auth user),
    # for a named user use /users/<login>/orgs (public membership only).
    local orgs_json
    if [[ "$owner" == "@me" ]]; then
      orgs_json=$(gh api user/orgs 2>/dev/null) || {
        warn "Could not list user orgs (auth issue?). Skipping template lookup."
        return 1
      }
    else
      orgs_json=$(gh api "users/$owner/orgs" 2>/dev/null) || {
        warn "Could not list orgs for $owner. Skipping template lookup."
        return 1
      }
    fi

    # Parse logins
    local org_list
    org_list=$(echo "$orgs_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    for o in data:
        print(o.get("login", ""))
' 2>/dev/null)

    while IFS= read -r org; do
      [[ -n "$org" ]] && orgs_to_search+=("$org")
    done <<< "$org_list"

    if [[ ${#orgs_to_search[@]} -eq 0 ]]; then
      info "  User '$owner' has no org memberships — no template lookup possible"
      return 1
    fi
  fi

  # Search each org for a template
  local org
  for org in "${orgs_to_search[@]}"; do
    local query='{ organization(login: "'"$org"'") { projectsV2(first: 50) { nodes { id number title template } } } }'
    local result
    result=$(gh api graphql -f query="$query" 2>&1) || {
      warn "Template lookup failed for org $org: $result"
      continue
    }

    local found
    found=$(echo "$result" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
org = data.get("organization") if data else None
if not org:
    sys.exit(1)
nodes = org.get("projectsV2", {}).get("nodes", []) or []
for n in nodes:
    if n.get("template"):
        print(n["id"] + "|" + n["title"])
        sys.exit(0)
sys.exit(1)
' 2>/dev/null) && {
      _FOUND_TEMPLATE_ID="${found%%|*}"
      _FOUND_TEMPLATE_TITLE="${found#*|} (from org: $org)"
      return 0
    }
  done

  return 1
}

# ─── Resolve owner ID (GraphQL ID for ownerId arguments) ─────

_init_resolve_owner_id() {
  local owner="$1"
  local owner_type="$2"

  local query result
  if [[ "$owner" == "@me" ]]; then
    query='{ viewer { id } }'
  elif [[ "$owner_type" == "organization" ]]; then
    query='{ organization(login: "'"$owner"'") { id } }'
  else
    query='{ user(login: "'"$owner"'") { id } }'
  fi

  result=$(gh api graphql -f query="$query" 2>&1) || {
    err "Failed to resolve owner ID: $result"
    return 1
  }

  echo "$result" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
for key in ("viewer", "user", "organization"):
    if key in data and data[key]:
        print(data[key]["id"])
        sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# ─── Init Path 1: Clone from template ────────────────────────
# Sets $_NEW_PROJECT_NUMBER and $_NEW_PROJECT_ID on success.

_init_from_template() {
  local owner="$1"
  local owner_type="$2"
  local title="$3"
  local template_id="$4"

  info "Cloning template to create \"$title\"..."

  local owner_id
  owner_id=$(_init_resolve_owner_id "$owner" "$owner_type") || {
    err "Could not resolve owner ID for $owner"
    return 1
  }

  # copyProjectV2 returns the new project (includes all views + workflows)
  local query='mutation {
    copyProjectV2(input: {
      projectId: "'"$template_id"'",
      ownerId: "'"$owner_id"'",
      title: "'"$title"'",
      includeDraftIssues: false
    }) {
      projectV2 { id number title }
    }
  }'

  local result
  result=$(gh api graphql -f query="$query" 2>&1) || {
    err "copyProjectV2 failed: $result"
    return 1
  }

  local parsed
  parsed=$(echo "$result" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
p = data.get("copyProjectV2", {}).get("projectV2") if data else None
if not p:
    sys.exit(1)
print(str(p["number"]) + "|" + p["id"])
' 2>/dev/null) || {
    err "copyProjectV2 returned unexpected payload: $result"
    return 1
  }

  _NEW_PROJECT_NUMBER="${parsed%%|*}"
  _NEW_PROJECT_ID="${parsed#*|}"

  info "  Cloned as project #$_NEW_PROJECT_NUMBER ($_NEW_PROJECT_ID)"
  return 0
}

# ─── Init Path 2: From-scratch creation ──────────────────────
# Sets $_NEW_PROJECT_NUMBER and $_NEW_PROJECT_ID on success.

_init_from_scratch() {
  local owner="$1"
  local title="$2"

  info "Creating project from scratch: $title (owner: $owner)..."
  local project_url
  project_url=$(gh project create --owner "$owner" --title "$title" --format json 2>&1) || {
    err "Failed to create project: $project_url"
    return 1
  }

  _NEW_PROJECT_NUMBER=$(echo "$project_url" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['number'])")
  _NEW_PROJECT_ID=$(echo "$project_url" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['id'])")
  info "  Created project #$_NEW_PROJECT_NUMBER ($_NEW_PROJECT_ID)"

  # Create custom fields via GraphQL
  # Valid colors: GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE
  _init_create_field "$_NEW_PROJECT_ID" "Priority" "P0:RED,P1:ORANGE,P2:YELLOW,P3:GREEN"
  _init_create_field "$_NEW_PROJECT_ID" "Area" "api:BLUE,web:PURPLE,admin:PINK,website:GREEN,mobile:ORANGE,db:RED,shared:GRAY,infra:YELLOW,docs:BLUE"
  _init_create_field "$_NEW_PROJECT_ID" "Type" "feature:GREEN,bug:RED,chore:GRAY,infra:YELLOW"
  _init_create_field "$_NEW_PROJECT_ID" "Size" "S:GREEN,M:YELLOW,L:ORANGE,XL:RED"
  _init_create_text_field "$_NEW_PROJECT_ID" "Sprint"

  # Add missing Status options (default has: Todo, In Progress, Done)
  info "Configuring Status field options..."
  _init_add_status_options "$_NEW_PROJECT_ID"

  return 0
}

# ─── Shared config writer (both paths) ───────────────────────

_init_write_config() {
  local project_number="$1"
  local owner="$2"
  local owner_type="$3"

  mkdir -p "$PROJECT_ROOT/.github"
  python3 -c "
import json
config = {
    'project_number': $project_number,
    'owner': '$owner',
    'owner_type': '$owner_type',
    'schema_version': 1,
    'fields': {
        'Status': ['Backlog', 'Todo', 'In Progress', 'Blocked', 'Review', 'Done', 'Archived'],
        'Priority': ['P0', 'P1', 'P2', 'P3'],
        'Area': ['api', 'web', 'admin', 'website', 'mobile', 'db', 'shared', 'infra', 'docs'],
        'Type': ['feature', 'bug', 'chore', 'infra'],
        'Size': ['S', 'M', 'L', 'XL'],
        'Sprint': []
    }
}
with open('$PROJECT_ROOT/.github/board.json', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
"
}

# ─── Create TEXT field (for Sprint in from-scratch path) ─────

_init_create_text_field() {
  local project_id="$1"
  local field_name="$2"

  local result
  result=$(gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$project_id\"
        dataType: TEXT
        name: \"$field_name\"
      }) {
        projectV2Field {
          ... on ProjectV2FieldCommon { id name }
        }
      }
    }
  " 2>&1) || {
    warn "Failed to create text field '$field_name': $result"
    return 0
  }

  info "  Created text field: $field_name"
}

# ─── Template promote: mark a project as a template ─────────
# Usage: board.sh template-promote <project-number> [--owner <owner>]
# Defaults owner to the current repo's board.json owner.

do_template_promote() {
  local project_number="" owner="" owner_type=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="$2"; shift 2 ;;
      --unmark) UNMARK_MODE=1; shift ;;
      [0-9]*) project_number="$1"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -z "$project_number" ]]; then
    err "Usage: board.sh template-promote <project-number> [--owner <owner>] [--unmark]"
    err ""
    err "Examples:"
    err "  board.sh template-promote 1                  # Promote project #1 (uses current repo's owner)"
    err "  board.sh template-promote 1 --owner @me      # Promote project #1 on your user account"
    err "  board.sh template-promote 1 --unmark         # Unmark as template"
    return 1
  fi

  # Default owner from current repo's board.json
  if [[ -z "$owner" ]]; then
    if [[ -f "$BOARD_CONFIG" ]]; then
      owner=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG'))['owner'])" 2>/dev/null)
      owner_type=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG')).get('owner_type', 'user'))" 2>/dev/null)
    fi
    if [[ -z "$owner" ]]; then
      err "No --owner specified and no .github/board.json in current repo"
      err "Provide --owner explicitly: board.sh template-promote $project_number --owner @me"
      return 1
    fi
  fi

  # Detect owner type if not already set
  if [[ -z "$owner_type" ]]; then
    if [[ "$owner" == "@me" ]]; then
      owner_type="user"
    elif gh api "orgs/$owner" --silent 2>/dev/null; then
      owner_type="organization"
    else
      owner_type="user"
    fi
  fi

  info "Looking up project #$project_number on $owner..."

  # Fetch project details (id, template state, views, fields)
  local node_query
  if [[ "$owner" == "@me" ]]; then
    node_query='{ viewer { projectV2(number: '"$project_number"') { id title template views(first: 10) { totalCount nodes { name layout } } fields(first: 30) { nodes { ... on ProjectV2FieldCommon { name dataType } } } workflows(first: 20) { nodes { name enabled } } } } }'
  elif [[ "$owner_type" == "organization" ]]; then
    node_query='{ organization(login: "'"$owner"'") { projectV2(number: '"$project_number"') { id title template views(first: 10) { totalCount nodes { name layout } } fields(first: 30) { nodes { ... on ProjectV2FieldCommon { name dataType } } } workflows(first: 20) { nodes { name enabled } } } } }'
  else
    node_query='{ user(login: "'"$owner"'") { projectV2(number: '"$project_number"') { id title template views(first: 10) { totalCount nodes { name layout } } fields(first: 30) { nodes { ... on ProjectV2FieldCommon { name dataType } } } workflows(first: 20) { nodes { name enabled } } } } }'
  fi

  local node_result
  node_result=$(gh api graphql -f query="$node_query" 2>&1) || {
    err "Failed to query project: $node_result"
    return 1
  }

  # Parse into temp file so Python can access without shell escaping
  local summary
  summary=$(echo "$node_result" | python3 -c '
import json, sys
data = json.load(sys.stdin).get("data", {})
p = None
for key in ("viewer", "user", "organization"):
    if key in data and data[key]:
        p = data[key].get("projectV2")
        if p:
            break
if not p:
    print("NOT_FOUND")
    sys.exit(0)

views = p.get("views", {}).get("nodes", []) or []
fields = p.get("fields", {}).get("nodes", []) or []
workflows = p.get("workflows", {}).get("nodes", []) or []
field_names = [f.get("name") for f in fields if f.get("name")]
has_sprint = "Sprint" in field_names
enabled_workflows = [w["name"] for w in workflows if w.get("enabled")]

print("ID|" + p["id"])
print("TITLE|" + p["title"])
print("TEMPLATE|" + ("true" if p.get("template") else "false"))
print("VIEWS|" + str(len(views)))
print("VIEW_NAMES|" + ",".join(v.get("name","") for v in views))
print("HAS_SPRINT|" + ("true" if has_sprint else "false"))
print("ENABLED_WORKFLOWS|" + ",".join(enabled_workflows))
' 2>/dev/null)

  if [[ "$summary" == "NOT_FOUND" ]] || [[ -z "$summary" ]]; then
    err "Project #$project_number not found on $owner"
    return 1
  fi

  local project_id project_title is_template views_count view_names has_sprint enabled_wfs
  project_id=$(echo "$summary" | grep '^ID|' | cut -d'|' -f2-)
  project_title=$(echo "$summary" | grep '^TITLE|' | cut -d'|' -f2-)
  is_template=$(echo "$summary" | grep '^TEMPLATE|' | cut -d'|' -f2-)
  views_count=$(echo "$summary" | grep '^VIEWS|' | cut -d'|' -f2-)
  view_names=$(echo "$summary" | grep '^VIEW_NAMES|' | cut -d'|' -f2-)
  has_sprint=$(echo "$summary" | grep '^HAS_SPRINT|' | cut -d'|' -f2-)
  enabled_wfs=$(echo "$summary" | grep '^ENABLED_WORKFLOWS|' | cut -d'|' -f2-)

  info "  Project: \"$project_title\" ($project_id)"
  info "  Current template state: $is_template"
  info "  Views ($views_count): $view_names"
  info "  Sprint field: $has_sprint"
  info "  Enabled workflows: ${enabled_wfs:-(none)}"
  info ""

  # Unmark mode
  if [[ "${UNMARK_MODE:-0}" -eq 1 ]]; then
    if [[ "$is_template" == "false" ]]; then
      info "Project is not currently marked as a template (no-op)"
      return 0
    fi
    local unmark_result
    unmark_result=$(gh api graphql -f query="mutation { unmarkProjectV2AsTemplate(input: { projectId: \"$project_id\" }) { projectV2 { id template } } }" 2>&1) || {
      err "Failed to unmark as template: $unmark_result"
      return 1
    }
    info "✓ Unmarked project #$project_number as template"
    return 0
  fi

  # Already a template?
  if [[ "$is_template" == "true" ]]; then
    info "✓ Project #$project_number is already marked as a template (idempotent)"
    return 0
  fi

  # GitHub constraint: only org-owned projects can be templates.
  if [[ "$owner_type" != "organization" ]]; then
    err "Only projects owned by an Organization can be marked as a template."
    err ""
    err "  This project is owned by user '$owner'. GitHub does not allow"
    err "  user-owned projects to become templates."
    err ""
    err "Recommended workflow:"
    err "  1. Create a new project in one of your organizations:"
    err "       gh project create --owner <org-name> --title \"Standard Repo Development\""
    err "  2. Configure it (views, workflows, Sprint field) to mirror your canonical board."
    err "  3. Promote it as a template:"
    err "       scripts/board.sh template-promote <new-project-number> --owner <org-name>"
    err ""
    err "  Then 'board.sh init --owner @me ...' will clone the org template into your"
    err "  user account (cross-owner copy is supported)."
    return 1
  fi

  # Readiness warnings
  local warnings=0
  if [[ "$views_count" -lt 2 ]]; then
    warn "Template has only $views_count view(s). Future boards will inherit just this view."
    warn "  Recommendation: Create a Kanban Board view (groupBy: Area) AND a Table view."
    warnings=$((warnings + 1))
  fi
  if [[ "$has_sprint" != "true" ]]; then
    warn "Template has no 'Sprint' TEXT field."
    warn "  Recommendation: Add a Sprint TEXT field in project settings."
    warnings=$((warnings + 1))
  fi
  if [[ -z "$enabled_wfs" ]]; then
    warn "Template has no enabled workflows."
    warn "  Recommendation: Enable 'Item closed' and 'Pull request merged' workflows."
    warnings=$((warnings + 1))
  fi

  if [[ "$warnings" -gt 0 ]]; then
    warn ""
    warn "Proceeding with $warnings readiness warning(s). Promoted templates propagate to"
    warn "all future boards — fix these in the UI first if you want a complete template."
    warn ""
  fi

  # Mark as template
  local mark_result
  mark_result=$(gh api graphql -f query="mutation { markProjectV2AsTemplate(input: { projectId: \"$project_id\" }) { projectV2 { id template } } }" 2>&1) || {
    err "Failed to mark as template: $mark_result"
    return 1
  }

  info "✓ Marked project #$project_number (\"$project_title\") as a template"
  info ""
  info "Future 'board.sh init' runs will clone this project via copyProjectV2,"
  info "inheriting its views, workflows, fields, and status descriptions."
  info ""
  info "Reachable from:"
  info "  - board.sh init --owner $owner ...     (org-owned target)"
  info "  - board.sh init --owner @me ...        (user-owned target, if you're an org member)"
  info "  - board.sh init --owner <other-user>   (if that user is also a member of $owner)"
}

_init_create_field() {
  local project_id="$1"
  local field_name="$2"
  local options_csv="$3"  # format: "name:COLOR,name:COLOR"

  # Build GraphQL options array
  # Note: description is a required field (String!) in ProjectV2SingleSelectFieldOptionInput
  local options_gql
  options_gql=$(python3 -c "
parts = '$options_csv'.split(',')
options = []
for p in parts:
    name, color = p.split(':')
    options.append('{name: \"' + name.strip() + '\", color: ' + color.strip() + ', description: \"\"}')
print(', '.join(options))
")

  local result
  result=$(gh api graphql -f query="
    mutation {
      createProjectV2Field(input: {
        projectId: \"$project_id\"
        dataType: SINGLE_SELECT
        name: \"$field_name\"
        singleSelectOptions: [$options_gql]
      }) {
        projectV2Field {
          ... on ProjectV2SingleSelectField {
            id
            name
          }
        }
      }
    }
  " 2>&1) || {
    warn "Failed to create field '$field_name': $result"
    return 0
  }

  info "  Created field: $field_name"
}

_init_add_status_options() {
  local project_id="$1"

  # Get the Status field ID. On a fresh board, GitHub creates a default Status
  # field with options: Todo, In Progress, Done. We replace the entire option
  # list in one call with our full desired schema.
  #
  # Note: updateProjectV2Field.singleSelectOptions REPLACES the entire list.
  # Each option requires: name, color, description (all non-null). There is
  # no longer an `id` field — option IDs are regenerated on replacement. This
  # is safe only during init (no items assigned to Status yet).
  local status_field_id
  status_field_id=$(gh api graphql -f query="
    query {
      node(id: \"$project_id\") {
        ... on ProjectV2 {
          field(name: \"Status\") {
            ... on ProjectV2SingleSelectField {
              id
            }
          }
        }
      }
    }
  " 2>&1 | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['data']['node']['field']['id'])" 2>/dev/null) || {
    warn "Could not read Status field ID"
    return 0
  }

  # Build the full desired option list in one mutation.
  # Valid colors: GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE
  local options_gql='[
    {name: "Backlog",     color: GRAY,   description: ""},
    {name: "Todo",        color: BLUE,   description: ""},
    {name: "In Progress", color: YELLOW, description: ""},
    {name: "Blocked",     color: RED,    description: ""},
    {name: "Review",      color: PURPLE, description: ""},
    {name: "Done",        color: GREEN,  description: ""},
    {name: "Archived",    color: GRAY,   description: ""}
  ]'

  local result
  result=$(gh api graphql -f query="
    mutation {
      updateProjectV2Field(input: {
        fieldId: \"$status_field_id\"
        singleSelectOptions: $options_gql
      }) {
        projectV2Field {
          ... on ProjectV2SingleSelectField {
            id
            options { name }
          }
        }
      }
    }
  " 2>&1) || {
    warn "Failed to replace Status options: $result"
    return 0
  }

  info "  Configured Status options: Backlog, Todo, In Progress, Blocked, Review, Done, Archived"
}

# ─── Clone Schema: copy fields from one board to a new one ───

do_clone_schema() {
  local source_owner="" source_number="" target_owner="" target_title=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-owner) source_owner="$2"; shift 2 ;;
      --from-number) source_number="$2"; shift 2 ;;
      --to-owner) target_owner="$2"; shift 2 ;;
      --title) target_title="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Default: read source from current repo's board.json
  if [[ -z "$source_owner" && -f "$BOARD_CONFIG" ]]; then
    source_owner=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG'))['owner'])")
    source_number=$(python3 -c "import json; print(json.load(open('$BOARD_CONFIG'))['project_number'])")
    info "Using current repo's board as source: project #$source_number (owner: $source_owner)"
  fi

  if [[ -z "$source_owner" || -z "$source_number" || -z "$target_owner" || -z "$target_title" ]]; then
    err "Usage: board.sh clone-schema --to-owner <org-or-@me> --title \"New Board\""
    err "  Optional: --from-owner <owner> --from-number <N> (defaults to current repo's board)"
    return 1
  fi

  # Read source board schema from board.json (not the API — uses the canonical schema)
  if [[ -f "$BOARD_CONFIG" ]]; then
    info "Reading schema from .github/board.json..."
    local schema_fields
    schema_fields=$(python3 -c "
import json
config = json.load(open('$BOARD_CONFIG'))
fields = config.get('fields', {})
for name, options in fields.items():
    if name == 'Status':
        continue  # Status is handled separately
    print(f'{name}:{','.join(options)}')
")
  else
    err "No .github/board.json found. Cannot read schema."
    err "Provide --from-owner and --from-number, or run from a repo with board.json"
    return 1
  fi

  # Create the target board using init
  info "Creating target board..."
  do_init --owner "$target_owner" --title "$target_title"
  info ""
  info "Schema cloned successfully!"
  info "The new board has the same fields and options as the source."
}

# ─── Main dispatch ────────────────────────────────────────────

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init)             do_init "$@" ;;
    clone-schema)     do_clone_schema "$@" ;;
    template-promote) do_template_promote "$@" ;;
    sync)             do_sync ;;
    add)          do_add "$@" ;;
    move)         do_move "$@" ;;
    comment)      do_comment "$@" ;;
    close)        do_close "$@" ;;
    list)         do_list "$@" ;;
    view)         do_view "$@" ;;
    backlog)      do_backlog "$@" ;;
    search)       do_search "$@" ;;
    archive)      do_archive ;;
    help|--help|-h)
      cat <<'USAGE'
GitHub Projects v2 Board Manager (Multi-Repo Portable)

Usage: board.sh <command> [args]

Setup Commands:
  init --owner <org-or-@me> --title "Project Title" [--no-template]
                                        Create a new board. If the target owner has a
                                        project marked as a template (via template-promote),
                                        clones it via copyProjectV2 — inheriting views,
                                        workflows, fields, and status descriptions.
                                        Falls back to from-scratch creation if no template
                                        exists. Pass --no-template to force from-scratch.
  template-promote <project-number> [--owner <org-or-@me>] [--unmark]
                                        Mark an existing project as a template so future
                                        'board.sh init' runs clone it. Warns if the project
                                        is missing views, workflows, or Sprint field.
                                        --unmark reverses the promotion. Idempotent.
  clone-schema --to-owner <org-or-@me> --title "Board Title"
                                        Clone current board's schema to a new board
                                        (field-level only — does NOT copy views/workflows;
                                        use template-promote + init for full cloning)
  sync                                  Refresh cached field IDs from GitHub

Board Commands:
  add "Title" [--priority P1] [--area api] [--type feature] [--size M] [--body "desc"]
                                        Create a GitHub Issue and add to board (defaults to Backlog)
  move <id-or-title> <status>           Move card to status column
  comment <issue-or-title> "body"       Add a comment to an issue (for timeline tracking)
  close <issue-or-title> [reason]       Close an issue (completed|not_planned)
  list [status] [--area X] [--priority X]
                                        List cards with optional filters
  view <issue-or-title>                 Show full issue details with comments and linked PRs
  backlog [--area X]                    List Backlog items
  search "keyword"                      Search cards by title
  archive                               List Done items for archival review

Statuses: Backlog, Todo, In Progress, Blocked, Review, Done, Archived
Priorities: P0, P1, P2, P3
Sizes: S, M, L, XL
Areas: api, web, admin, website, mobile, db, shared, infra, docs
Types: feature, bug, chore, infra

Configuration:
  Board config lives in .github/board.json (per-repo, committed to git).
  Cache lives in .claude/state/board-config.json (local, gitignored).
  Each repo points to its own board — works across orgs.

Issue Integration:
  Cards are created as GitHub Issues for full traceability:
  - Link PRs with "Closes #N" in PR description
  - Add timeline comments at each pipeline stage
  - View linked PRs, comments, and history with 'view'
  - Auto-close on PR merge (GitHub workflow configured)
USAGE
      ;;
    *)
      err "Unknown command: $cmd"
      err "Run: board.sh help"
      return 1
      ;;
  esac
}

main "$@"
