# Skill Template v2.1.0

**Last Updated**: 2026-01-08
**Claude Code Version**: v2.1.0+
**Purpose**: Standard template for all skill definitions with full v2.1.0 feature support

---

## Template: Standard Skill (Inline Context)

```yaml
---
# ============================================================================
# IDENTITY (Required)
# ============================================================================
name: skill-name
description: |
  Precise description of what this skill does AND when Claude should activate it.
  Include activation triggers and use cases. Claude uses this to decide when to
  auto-invoke the skill.
version: 1.0.0

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
# YAML list format (preferred in v2.1.0)
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob

# ============================================================================
# MODEL CONFIGURATION
# ============================================================================
# Options: opus, sonnet, haiku, inherit (uses session model)
model: inherit

# ============================================================================
# EXECUTION CONTEXT (New in v2.1.0)
# ============================================================================
# Options:
# - inline: Runs in main conversation context (default)
# - fork: Runs in isolated sub-agent context
context: inline

# Agent type for execution (new in v2.1.0)
# Only used when context: fork
# agent: explorer  # Use built-in or custom agent

# ============================================================================
# VISIBILITY CONFIGURATION (New in v2.1.0)
# ============================================================================
# Show in slash command menu (default: true for skills in /skills/)
user-invocable: true

# Prevent automatic model-invoked discovery
disable-model-invocation: false

# ============================================================================
# HOOKS CONFIGURATION (New in v2.1.0)
# ============================================================================
# Skill-scoped hooks for workflow automation
hooks:
  # Validate before tool execution
  # - type: PreToolUse
  #   matcher: Write
  #   command: ".claude/hooks/validate-write.sh"

  # Process output after execution
  # - type: PostToolUse
  #   command: ".claude/hooks/log-skill-output.sh"

  # Verify skill completion
  # - type: Stop
  #   prompt: "Verify skill completed successfully"
  #   model: haiku  # Cheap verification

# ============================================================================
# DEPRECATED (but still supported)
# ============================================================================
# when_to_use: ""  # Appends to description - use sparingly, prefer description
---

# Skill Name

## Overview

Brief description of what this skill provides and when it activates.

## When to Use

This skill activates when:
- Trigger condition 1
- Trigger condition 2
- Trigger condition 3

## Instructions

Step-by-step guidance for Claude when this skill is active:

### Step 1: [First Action]

Detailed instructions for the first step.

### Step 2: [Second Action]

Detailed instructions for the second step.

### Step 3: [Verification]

How to verify the skill completed successfully.

## Examples

### Example 1: [Common Use Case]

**User Request**: "[example request that triggers this skill]"

**Expected Behavior**:
```
[What Claude should do when this skill activates]
```

### Example 2: [Complex Use Case]

**User Request**: "[complex example]"

**Expected Behavior**:
```
[Detailed expected behavior]
```

## Reference Files

When needed, load additional context:

```bash
# Load detailed reference
cat reference/detailed-guide.md

# Load templates
cat templates/example-template.md
```

## Anti-Patterns

Do NOT:
- Anti-pattern 1
- Anti-pattern 2
- Anti-pattern 3

## Related Skills

- `related-skill-1`: When to use instead
- `related-skill-2`: Complementary use
```

---

## Template: Forked Context Skill (Isolated Execution)

```yaml
---
# ============================================================================
# IDENTITY
# ============================================================================
name: codebase-analysis
description: |
  Deep analysis of codebase structure when user needs comprehensive overview,
  architecture understanding, or dependency mapping. Runs in isolated context
  to prevent context pollution.
version: 1.0.0

# ============================================================================
# TOOL CONFIGURATION - READ ONLY
# ============================================================================
allowed-tools:
  - Read
  - Grep
  - Glob

# ============================================================================
# MODEL CONFIGURATION
# ============================================================================
model: haiku  # Cost-effective for exploration

# ============================================================================
# FORKED CONTEXT (New in v2.1.0)
# ============================================================================
context: fork  # Runs in isolated sub-agent context
agent: explorer  # Uses built-in Explore agent

# ============================================================================
# VISIBILITY
# ============================================================================
user-invocable: true
disable-model-invocation: false

# ============================================================================
# HOOKS
# ============================================================================
hooks:
  - type: Stop
    prompt: "Summarize findings in structured format"
    model: haiku
---

# Codebase Analysis (Forked)

## Overview

Performs deep codebase analysis in isolated context. Only results return to main
conversation, preventing context pollution from large file reads.

## Benefits of Forked Context

1. **Context Isolation**: Large operations don't consume main context
2. **Parallel Execution**: Can run alongside other operations
3. **Clean Results**: Only summary returns to parent

## When to Use

- Analyzing large codebases (1000+ files)
- Understanding project architecture
- Mapping dependencies
- Finding patterns across codebase

## Instructions

### Analysis Workflow

1. **Scan Structure**: Use Glob to map file structure
2. **Identify Patterns**: Search for key patterns with Grep
3. **Read Key Files**: Read configuration and entry points
4. **Summarize**: Return structured analysis

### Output Format

```markdown
## Codebase Analysis

### Structure
- Total files: [count]
- Languages: [list]
- Entry points: [list]

### Architecture
- Pattern: [monolith/microservices/monorepo]
- Key directories: [list]

### Dependencies
- Package manager: [npm/pnpm/yarn]
- Key dependencies: [list]

### Recommendations
- [recommendation 1]
- [recommendation 2]
```

## Example

**User**: "Analyze this codebase structure"

**Skill Executes** (in forked context):
1. Scans file structure
2. Identifies patterns
3. Reads key files
4. Returns summary only

**Returns to Main**:
```markdown
## Codebase Analysis

### Structure
- Total files: 847
- Languages: TypeScript (92%), CSS (5%), JSON (3%)
- Entry points: src/index.ts, src/main.tsx

[... rest of summary ...]
```
```

---

## Template: Hooks-Enabled Skill

```yaml
---
# ============================================================================
# IDENTITY
# ============================================================================
name: secure-code-generator
description: |
  Generate code with built-in security validation. Automatically validates
  generated code for security vulnerabilities before writing. Use when
  generating any code that handles user input, authentication, or sensitive data.
version: 1.0.0

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob

# ============================================================================
# MODEL CONFIGURATION
# ============================================================================
model: opus  # Complex reasoning for security

# ============================================================================
# CONTEXT
# ============================================================================
context: inline

# ============================================================================
# VISIBILITY
# ============================================================================
user-invocable: true

# ============================================================================
# HOOKS - SECURITY VALIDATION (New in v2.1.0)
# ============================================================================
hooks:
  # Validate code before writing
  - type: PreToolUse
    matcher: Write
    command: ".claude/hooks/security-scan.sh"

  # Log all code generation
  - type: PostToolUse
    command: ".claude/hooks/log-code-generation.sh"
    once: true  # Only log once per session

  # Final security verification
  - type: Stop
    prompt: |
      Verify the generated code:
      1. No hardcoded secrets
      2. Input validation implemented
      3. SQL injection prevention
      4. XSS prevention
      5. Proper error handling
    model: sonnet  # Thorough verification
---

# Secure Code Generator

## Overview

Generates code with built-in security validation via hooks. Every write
operation is scanned for vulnerabilities before execution.

## Hook Workflow

```
User Request
    ↓
Generate Code
    ↓
PreToolUse Hook (security-scan.sh)
    ├─ Pass → Write file
    └─ Fail → Block write, report issue
    ↓
PostToolUse Hook (log-code-generation.sh)
    ↓
Stop Hook (security verification prompt)
    ↓
Complete
```

## Security Checks

### PreToolUse: security-scan.sh

Scans for:
- Hardcoded secrets
- SQL injection vectors
- XSS vulnerabilities
- Command injection
- Path traversal

### Stop: Verification Prompt

Verifies:
- Input validation
- Output encoding
- Authentication checks
- Error handling
- Logging

## Usage

Simply request code generation - security validation happens automatically:

**User**: "Create a login form handler"

**Skill**:
1. Generates secure code
2. Runs security scan (PreToolUse)
3. Writes if scan passes
4. Logs generation (PostToolUse)
5. Final verification (Stop)
```

---

## Template: Slash Command Skill

```yaml
---
# ============================================================================
# IDENTITY
# ============================================================================
name: code-review
description: |
  Comprehensive code review focusing on security, performance, and best practices.
  Invoked via /code-review or automatically when reviewing PRs.
version: 1.0.0

# ============================================================================
# TOOL CONFIGURATION - READ ONLY
# ============================================================================
allowed-tools:
  - Read
  - Grep
  - Glob

# ============================================================================
# MODEL CONFIGURATION
# ============================================================================
model: opus  # Thorough analysis requires best model

# ============================================================================
# VISIBILITY - SLASH COMMAND
# ============================================================================
user-invocable: true  # Shows as /code-review
disable-model-invocation: false  # Also auto-activates

# Argument hint for slash command
# argument-hint: <file-or-directory>
---

# Code Review Skill

## Overview

Performs comprehensive code review when invoked via `/code-review` or when
Claude detects code review context.

## Activation

### Manual (Slash Command)
```
/code-review src/auth/
/code-review src/utils/helpers.ts
```

### Automatic (Model-Invoked)
- "Review this code"
- "Check this PR"
- "Audit this module"

## Review Categories

### 1. Security
- [ ] Input validation
- [ ] SQL injection prevention
- [ ] XSS prevention
- [ ] Authentication/authorization
- [ ] Secrets management

### 2. Performance
- [ ] Algorithm complexity
- [ ] Database query optimization
- [ ] Memory usage
- [ ] Caching opportunities

### 3. Code Quality
- [ ] Readability
- [ ] Maintainability
- [ ] Error handling
- [ ] Test coverage

### 4. Best Practices
- [ ] Language idioms
- [ ] Framework patterns
- [ ] Documentation
- [ ] Type safety

## Output Format

```markdown
## Code Review: [file/directory]

### Critical Issues
- [Issue]: [Description] @ [file:line]
  - Fix: [Recommendation]

### High Priority
- [Issue]: [Description]

### Medium Priority
- [Issue]: [Description]

### Suggestions
- [Enhancement idea]

### Summary
- Files reviewed: [count]
- Issues found: [count by severity]
- Recommendation: [approve/request changes]
```
```

---

## Skill Directory Structure

### Minimal Skill
```
skill-name/
└── SKILL.md
```

### Standard Skill
```
skill-name/
├── SKILL.md (2-5k tokens)
├── reference.md (detailed docs)
└── templates/
    └── example.md
```

### Enterprise Skill
```
skill-name/
├── SKILL.md (2-5k tokens)
├── reference/
│   ├── guide.md
│   └── api.md
├── templates/
│   ├── template-1.md
│   └── template-2.md
├── scripts/
│   ├── validate.sh
│   └── generate.py
└── examples/
    ├── simple.md
    └── complex.md
```

---

## Frontmatter Field Reference

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Unique skill identifier |
| `description` | string | What skill does + activation triggers |

### Recommended Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | string | 1.0.0 | Semantic version |
| `allowed-tools` | list | all | Tools skill can use |
| `model` | enum | inherit | opus, sonnet, haiku, inherit |

### v2.1.0 Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `context` | enum | inline | inline, fork |
| `agent` | string | - | Agent type for fork context |
| `user-invocable` | bool | true | Show in slash menu |
| `disable-model-invocation` | bool | false | Prevent auto-discovery |
| `hooks` | list | - | Skill-scoped hooks |

### Hook Configuration

| Field | Type | Description |
|-------|------|-------------|
| `hooks[].type` | enum | PreToolUse, PostToolUse, Stop |
| `hooks[].matcher` | string | Tool name for PreToolUse |
| `hooks[].command` | string | Shell script path |
| `hooks[].prompt` | string | For Stop hooks |
| `hooks[].model` | enum | Model for prompt-based hooks |
| `hooks[].once` | bool | Run only once per session |

---

## How to Use Skills

### 1. Automatic Activation (Model-Invoked)

Skills activate automatically when Claude detects matching context:

```
User: "Review this code for security issues"

Claude (internal):
1. Scans skill descriptions
2. Matches "code-review" skill
3. Loads skill instructions
4. Applies expertise

Claude: "Using Skill: code-review
I'll perform a comprehensive security review..."
```

### 2. Manual Invocation (Slash Command)

Skills with `user-invocable: true` appear in slash menu:

```
/code-review src/auth/
/codebase-analysis
/secure-code-generator
```

### 3. Via Agent Skills Field

Agents can auto-load skills:

```yaml
# In agent definition
skills:
  - code-review
  - security-audit
```

### 4. Programmatic Loading

Ask Claude to use specific skills:

```
User: "Use the code-review skill to analyze this module"
```

---

## Migration Checklist

When updating existing skills to v2.1.0:

- [ ] Convert `allowed-tools` to YAML list format
- [ ] Add `version` field
- [ ] Add `model` field (or use `inherit`)
- [ ] Consider `context: fork` for large operations
- [ ] Add `user-invocable` field
- [ ] Add `hooks` for workflow automation
- [ ] Update description with clear activation triggers
- [ ] Add examples section
- [ ] Structure for progressive disclosure
