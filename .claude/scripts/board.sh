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

# ─── Init: bootstrap a new board with standard schema ────────

do_init() {
  local owner="" title="" owner_type="user"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$owner" || -z "$title" ]]; then
    err "Usage: board.sh init --owner <org-name-or-@me> --title \"Project Title\""
    err ""
    err "Examples:"
    err "  board.sh init --owner cleanscale-io --title \"CleanRev Development\""
    err "  board.sh init --owner @me --title \"My Projects\""
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

  # Create project
  info "Creating project: $title (owner: $owner)..."
  local project_url
  project_url=$(gh project create --owner "$owner" --title "$title" --format json 2>&1) || {
    err "Failed to create project: $project_url"
    return 1
  }

  local project_number project_id
  project_number=$(echo "$project_url" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['number'])")
  project_id=$(echo "$project_url" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['id'])")
  info "Created project #$project_number (ID: $project_id)"

  # Create custom fields via GraphQL
  # Note: TEAL is not a valid color — valid enum values are GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE
  _init_create_field "$project_id" "Priority" "P0:RED,P1:ORANGE,P2:YELLOW,P3:GREEN"
  _init_create_field "$project_id" "Area" "api:BLUE,web:PURPLE,admin:PINK,website:GREEN,mobile:ORANGE,db:RED,shared:GRAY,infra:YELLOW,docs:BLUE"
  _init_create_field "$project_id" "Type" "feature:GREEN,bug:RED,chore:GRAY,infra:YELLOW"
  _init_create_field "$project_id" "Size" "S:GREEN,M:YELLOW,L:ORANGE,XL:RED"

  # Add missing Status options (default has: Todo, In Progress, Done)
  info "Configuring Status field options..."
  _init_add_status_options "$project_id"

  # Write .github/board.json
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
        'Size': ['S', 'M', 'L', 'XL']
    }
}
with open('$PROJECT_ROOT/.github/board.json', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
"
  info "Wrote .github/board.json"

  # Sync cache
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
  info ""
  info "Manual steps remaining:"
  info "  1. Go to Project Settings > Workflows"
  info "  2. Enable: 'Item closed' → Set Status to 'Done'"
  info "  3. Enable: 'Pull request merged' → Set Status to 'Done'"
  info "  4. Optionally: Enable 'Auto-add to project' for this repo"
  info ""
  info "Commit .github/board.json to the repo."
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
    init)         do_init "$@" ;;
    clone-schema) do_clone_schema "$@" ;;
    sync)         do_sync ;;
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
  init --owner <org-or-@me> --title "Project Title"
                                        Create a new board with standard schema
  clone-schema --to-owner <org-or-@me> --title "Board Title"
                                        Clone current board's schema to a new board
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
