# Agent Metadata Validation Checklist

**Version**: 1.0.0 **Last Updated**: 2025-11-25 **Reference**:
AGENT_METADATA_SPECIFICATION.md

---

## Quick Validation Summary

Use this checklist to validate agent metadata compliance. Each agent MUST pass
all Required checks and SHOULD pass all Recommended checks.

---

## Pre-Validation: File Structure

```
[ ] File is located in correct directory:
    - .claude/agents/coordination/
    - .claude/agents/implementation/
    - .claude/agents/research-planning/
    - .claude/agents/hive/

[ ] Filename matches agent name (agent-name.md)

[ ] File starts with YAML frontmatter (--- delimiters)

[ ] YAML syntax is valid (no parsing errors)
```

---

## Required Fields Checklist

### name

```
[ ] Field is present
[ ] Value is kebab-case (lowercase, hyphens only)
[ ] Value matches filename (without .md extension)
[ ] No spaces, underscores, or uppercase letters

Examples:
  PASS: database-expert
  PASS: react-typescript-specialist
  FAIL: Database Expert (spaces)
  FAIL: database_expert (underscore)
  FAIL: DatabaseExpert (camelCase)
```

### version

```
[ ] Field is present
[ ] Value follows semantic versioning (MAJOR.MINOR.PATCH)
[ ] All three components present
[ ] No "v" prefix

Examples:
  PASS: 1.0.0
  PASS: 2.1.3
  PASS: 1.12.0
  FAIL: 1.0 (missing patch)
  FAIL: v1.0.0 (has prefix)
  FAIL: 1 (incomplete)
```

### description

```
[ ] Field is present
[ ] Contains "Use this agent when..." clause
[ ] Lists agent specializations/capabilities
[ ] Contains at least one <example> block
[ ] Example has Context, user prompt, assistant response
[ ] Example has <commentary> explaining when to use

Structure check:
  [ ] Activation trigger present
  [ ] Capabilities listed
  [ ] Example block present
  [ ] Commentary present
```

### color

```
[ ] Field is present
[ ] Value is lowercase
[ ] Value is from canonical list:
    - red, blue, green, purple, cyan
    - yellow, orange, magenta, pink, black

Examples:
  PASS: blue
  PASS: cyan
  FAIL: Blue (capitalized)
  FAIL: BLUE (uppercase)
  FAIL: #0000FF (hex code)
```

---

## Recommended Fields Checklist

### model

```
[ ] Field is present (or intentionally omitted)
[ ] Value is "inherit" OR valid model name
[ ] If specific model, uses current format:
    - claude-sonnet-4-6
    - claude-haiku-4-5
    - claude-opus-4-6
[ ] Does NOT use deprecated formats:
    - claude-3-5-sonnet-20241022
    - claude-3-haiku-20240307

Recommendation: Use "inherit" unless specific model required
```

### sdk_features

```
[ ] Field is present (or intentionally omitted)
[ ] Value is YAML array format: [item1, item2, item3]
[ ] Values are from canonical list:
    - subagents
    - sessions
    - cost_tracking
    - tool_restrictions
    - lifecycle_hooks
    - todo_coordination
[ ] NOT using deprecated nested object format:
    sdk_features:
      context_management: [...]  # DEPRECATED

Examples:
  PASS: sdk_features: [subagents, sessions, cost_tracking]
  PASS: sdk_features: [sessions, tool_restrictions]
  FAIL: sdk_features:
          context_management:
            - smart-chaining    # DEPRECATED
```

### cost_optimization

```
[ ] Field is present (or intentionally omitted)
[ ] Value is boolean: true or false
[ ] NOT using deprecated nested object format:
    cost_optimization:
      strategy: "..."  # DEPRECATED

Examples:
  PASS: cost_optimization: true
  PASS: cost_optimization: false
  FAIL: cost_optimization:
          strategy: "Use Haiku..."  # DEPRECATED
```

### session_aware

```
[ ] Field is present (or intentionally omitted)
[ ] Value is boolean: true or false

Examples:
  PASS: session_aware: true
  PASS: session_aware: false
```

### last_updated

```
[ ] Field is present
[ ] Value is ISO 8601 date format: YYYY-MM-DD
[ ] Date is recent (within last 6 months for active agents)

Examples:
  PASS: last_updated: 2025-11-25
  PASS: last_updated: 2025-10-20
  FAIL: last_updated: 11/25/2025 (wrong format)
  FAIL: last_updated: Nov 25, 2025 (wrong format)
```

---

## Optional Fields Checklist

### category

```
[ ] If present, value is kebab-case
[ ] Value matches one of:
    - coordination
    - implementation
    - research-planning
    - hive
[ ] Value aligns with file location (or documented reason for difference)
```

### tools

```
[ ] If present, value is array of tool names OR "*"
[ ] Tool names use canonical capitalization:
    - Read, Write, Edit, Bash
    - Grep, Glob
    - WebFetch, WebSearch
    - TodoWrite
[ ] Wildcard is quoted: "*"

Examples:
  PASS: tools: [Read, Write, Edit, Bash]
  PASS: tools: [Read, Grep, Glob]
  PASS: tools: "*"
  FAIL: tools: [read, write] (lowercase)
  FAIL: tools: * (unquoted wildcard)
```

### supports_subagent_creation

```
[ ] If present, value is boolean: true or false
```

### supports_parallel_execution

```
[ ] If present, value is boolean: true or false
```

### sdk_self_aware

```
[ ] If present, value is boolean: true or false
[ ] Only used for SDK-related agents (e.g., claude-sdk-expert)
```

---

## Deprecated Fields Checklist (Should NOT Exist)

```
[ ] No x- prefixed fields (x-color, x-version, etc.)
[ ] No sdk_utilization field
[ ] No tool_restrictions field (use tools instead)
[ ] No nested cost_optimization object
[ ] No nested sdk_features object
```

---

## Field Order Check (Recommended)

```
[ ] Identity fields first (name, version, description, color)
[ ] Execution fields second (model, sdk_features, cost_optimization, session_aware)
[ ] Capability fields third (category, tools, supports_*)
[ ] Metadata fields last (last_updated)
```

---

## Validation Script Template

```bash
#!/bin/bash
# Agent Metadata Validator
# Usage: ./validate-agent.sh path/to/agent.md

AGENT_FILE="$1"

echo "=== Validating: $AGENT_FILE ==="

# Check file exists
if [ ! -f "$AGENT_FILE" ]; then
    echo "FAIL: File does not exist"
    exit 1
fi

# Extract frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/p' "$AGENT_FILE" | tail -n +2 | head -n -1)

# Check required fields
echo "--- Required Fields ---"

# name
NAME=$(echo "$FRONTMATTER" | grep -E "^name:" | cut -d: -f2 | xargs)
if [ -z "$NAME" ]; then
    echo "FAIL: name field missing"
else
    if [[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "PASS: name = $NAME"
    else
        echo "FAIL: name not kebab-case: $NAME"
    fi
fi

# version
VERSION=$(echo "$FRONTMATTER" | grep -E "^version:" | cut -d: -f2 | xargs)
if [ -z "$VERSION" ]; then
    echo "FAIL: version field missing"
else
    if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "PASS: version = $VERSION"
    else
        echo "FAIL: version not semver: $VERSION"
    fi
fi

# description
DESC=$(echo "$FRONTMATTER" | grep -E "^description:")
if [ -z "$DESC" ]; then
    echo "FAIL: description field missing"
else
    if echo "$DESC" | grep -q "Use this agent"; then
        echo "PASS: description has activation trigger"
    else
        echo "WARN: description missing 'Use this agent when...' clause"
    fi
    if echo "$DESC" | grep -q "<example>"; then
        echo "PASS: description has example block"
    else
        echo "WARN: description missing <example> block"
    fi
fi

# color
COLOR=$(echo "$FRONTMATTER" | grep -E "^color:" | cut -d: -f2 | xargs)
if [ -z "$COLOR" ]; then
    echo "FAIL: color field missing"
else
    VALID_COLORS="red blue green purple cyan yellow orange magenta pink black"
    if echo "$VALID_COLORS" | grep -qw "$COLOR"; then
        echo "PASS: color = $COLOR"
    else
        echo "FAIL: color not in canonical list: $COLOR"
    fi
fi

# Check deprecated fields
echo "--- Deprecated Fields ---"

if echo "$FRONTMATTER" | grep -qE "^x-"; then
    echo "FAIL: x- prefixed fields found (deprecated)"
else
    echo "PASS: no x- prefixed fields"
fi

if echo "$FRONTMATTER" | grep -qE "^sdk_utilization:"; then
    echo "FAIL: sdk_utilization field found (deprecated)"
else
    echo "PASS: no sdk_utilization field"
fi

if echo "$FRONTMATTER" | grep -qE "^tool_restrictions:"; then
    echo "FAIL: tool_restrictions field found (deprecated)"
else
    echo "PASS: no tool_restrictions field"
fi

echo "=== Validation Complete ==="
```

---

## Batch Validation Command

To validate all agents in the repository:

```bash
# Find all agent files and validate
find .claude/agents -name "*.md" -type f | while read file; do
    echo "Validating: $file"
    # Run validation checks (see script above)
done

# Quick check for missing required fields
echo "=== Missing version field ==="
grep -L "^version:" .claude/agents/**/*.md 2>/dev/null

echo "=== Missing description field ==="
grep -L "^description:" .claude/agents/**/*.md 2>/dev/null

echo "=== Deprecated x- fields ==="
grep -l "^x-" .claude/agents/**/*.md 2>/dev/null

echo "=== Non-standard sdk_features (nested) ==="
grep -l "sdk_features:" .claude/agents/**/*.md 2>/dev/null | \
  xargs grep -l "context_management:\|reasoning:\|memory:" 2>/dev/null
```

---

## Common Issues and Fixes

### Issue: Missing `version` field

```yaml
# Before
name: my-agent
description: ...

# After
name: my-agent
version: 1.0.0
description: ...
```

### Issue: Nested `sdk_features`

```yaml
# Before (deprecated)
sdk_features:
  context_management:
    - smart-chaining
  reasoning:
    - sequential-thinking

# After (canonical)
sdk_features: [sessions, cost_tracking]
```

### Issue: Nested `cost_optimization`

```yaml
# Before (deprecated)
cost_optimization:
  strategy: "Use Haiku for simple queries..."

# After (canonical)
cost_optimization: true
# Move strategy documentation to agent body
```

### Issue: `x-` prefixed fields

```yaml
# Before (deprecated)
x-color: blue
x-version: 1.0.0

# After (canonical)
color: blue
version: 1.0.0
```

### Issue: Uppercase color

```yaml
# Before
color: Blue
color: CYAN

# After
color: blue
color: cyan
```

### Issue: Incomplete version

```yaml
# Before
version: 1.0
version: v1.0.0

# After
version: 1.0.0
```

---

## Compliance Levels

### Level 1: Minimum Compliance (Required)

- All required fields present and valid
- No deprecated field formats
- YAML parses without errors

### Level 2: Recommended Compliance

- Level 1 + all recommended fields
- `sdk_features` in canonical array format
- `cost_optimization` as boolean
- `last_updated` within 6 months

### Level 3: Full Compliance

- Level 2 + correct field ordering
- Comprehensive description with multiple examples
- All applicable optional fields populated
- Documentation cross-references up to date

---

## Reporting Template

```markdown
# Agent Metadata Compliance Report

**Date**: YYYY-MM-DD **Agents Validated**: XX **Compliance Summary**:

- Level 1 (Minimum): XX/XX (XX%)
- Level 2 (Recommended): XX/XX (XX%)
- Level 3 (Full): XX/XX (XX%)

## Non-Compliant Agents

| Agent      | Issue               | Severity    | Fix Required       |
| ---------- | ------------------- | ----------- | ------------------ |
| agent-name | Missing version     | Required    | Add version: 1.0.0 |
| agent-name | Nested sdk_features | Recommended | Convert to array   |

## Action Items

1. [ ] Fix required field issues (X agents)
2. [ ] Migrate deprecated formats (X agents)
3. [ ] Update last_updated dates (X agents)
4. [ ] Review description examples (X agents)
```

---

## Changelog

### v1.0.0 (2025-11-25)

- Initial checklist
- Required, recommended, optional field validation
- Deprecated field detection
- Validation script template
- Batch validation commands
- Common issues and fixes
