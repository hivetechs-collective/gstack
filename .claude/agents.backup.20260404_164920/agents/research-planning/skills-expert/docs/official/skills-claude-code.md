# Skills in Claude Code

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/docs/claude-code/skills **Category**: Agent Skills /
Claude Code CLI

## Overview

Agent Skills extend Claude's capabilities in Claude Code by packaging expertise
into discoverable, modular capabilities. Each Skill consists of a `SKILL.md`
file with instructions plus optional supporting files.

## Key Distinction: Skills vs. Slash Commands

**Skills are model-invoked**—Claude autonomously decides when to use them based
on request context and Skill descriptions.

**Slash commands are user-invoked**—explicitly triggered by typing `/command`.

This fundamental difference means Skills activate automatically when relevant,
while slash commands require manual execution.

## Skill Storage Locations

### Personal Skills (Individual Use)

**Location**: `~/.claude/skills/skill-name/`

**Best for**:

- Individual workflows
- Experimental capabilities
- Personal tools
- Cross-project utilities

**Characteristics**:

- Available across all projects
- Not committed to version control
- Private to your machine

### Project Skills (Team-Shared)

**Location**: `.claude/skills/skill-name/` within project

**Best for**:

- Team conventions
- Project-specific expertise
- Shared utilities
- Standardized workflows

**Characteristics**:

- Committed to git
- Shared with entire team
- Project-scoped activation

### Plugin Skills

**Source**: Bundled with Claude Code plugins

**Characteristics**:

- Automatically available when plugins are installed
- Maintained by plugin authors
- Discoverable through plugin marketplace

## Creating a Skill

### SKILL.md Structure

The required file uses YAML frontmatter with Markdown content:

```yaml
---
name: Skill Name
description: What it does and when Claude should use it
---

# Skill Name

## Instructions
Step-by-step guidance for Claude

## Examples
Concrete usage examples
```

### Critical: The Description Field

The description field is **critical**—it should specify both:

1. **Functionality**: What the Skill does
2. **Activation triggers**: When Claude should use it

**Good description**:

```yaml
description:
  Generate TypeScript API clients from OpenAPI specs when the user needs to
  integrate with REST APIs
```

**Poor description**:

```yaml
description: API client generator
```

### Supporting Files

Optional files alongside SKILL.md:

- **Documentation files**: `reference.md`, `examples.md`
- **Scripts and utilities**: `scripts/` directory
- **Templates**: `templates/` directory
- **Data files**: JSON, YAML, etc.

Reference these from SKILL.md using relative paths. Claude loads additional
files only when needed.

**Example SKILL.md with supporting files**:

````markdown
---
name: Brand Guidelines
description: Apply company brand guidelines to all design and documentation work
---

# Brand Guidelines

## Instructions

When creating any visual or written content:

1. Review the brand standards in `reference.md`
2. Use color codes from `colors.json`
3. Apply logo guidelines from `logo-guidelines.md`
4. Follow typography rules from `typography.md`

## Color Palette

Load colors from `colors.json`:

```bash
cat colors.json
```
````

## Logo Usage

Reference `logo-guidelines.md` for:

- Minimum size requirements
- Clear space rules
- Prohibited modifications

````

## Tool Access Restrictions

Use the `allowed-tools` frontmatter field to limit Claude's tool access:

```yaml
---
name: Safe File Reader
description: Read-only file access for analyzing codebases
allowed-tools: Read, Grep, Glob
---
````

This restricts Claude to specified tools without requiring permission requests.
Useful for:

- **Read-only workflows**: Analysis, review, documentation
- **Security-sensitive operations**: Prevent accidental modifications
- **Sandboxed environments**: Limit tool surface area

**Available tools**:

- `Read` - Read file contents
- `Write` - Write/modify files
- `Edit` - Edit file contents
- `Grep` - Search file contents
- `Glob` - Search file paths
- `Bash` - Execute bash commands
- `WebFetch` - Fetch web content
- `WebSearch` - Search the web

## Discovery and Management

### View Available Skills

Ask Claude directly:

```
What Skills are available?
```

Or check filesystem directories:

```bash
ls ~/.claude/skills/
ls .claude/skills/
```

### Test a Skill

Ask questions matching the Skill's description. Claude autonomously activates
relevant Skills.

**Example**:

```
Create a branded PowerPoint presentation for Q4 results
```

If you have a "Brand Guidelines" Skill, Claude will load it automatically.

### Verify Skill Loading

Claude will indicate when Skills are loaded:

```
Using Skills: Brand Guidelines, PowerPoint Creator
```

## Example Skills

### 1. Code Review Skill

**Location**: `~/.claude/skills/code-review/SKILL.md`

````yaml
---
name: Code Review
description: Perform comprehensive code reviews focusing on security, performance, and best practices
allowed-tools: Read, Grep, Glob
---

# Code Review Skill

## Instructions

When reviewing code:

1. **Security Analysis**
   - SQL injection vulnerabilities
   - XSS prevention
   - Authentication/authorization flaws
   - Secrets in code

2. **Performance Review**
   - Algorithm complexity
   - Database query efficiency
   - Memory leaks
   - Unnecessary re-renders (React)

3. **Best Practices**
   - Error handling
   - Code organization
   - Test coverage
   - Documentation

4. **Output Format**
   - Severity: Critical, High, Medium, Low
   - Location: File and line number
   - Issue description
   - Recommended fix

## Example

```markdown
### Critical: SQL Injection Vulnerability

**File**: `src/database/users.ts:45`

**Issue**: Direct string concatenation in SQL query
```sql
const query = `SELECT * FROM users WHERE email = '${email}'`;
````

**Fix**: Use parameterized queries

```typescript
const query = 'SELECT * FROM users WHERE email = ?';
db.query(query, [email]);
```

```

```

### 2. Documentation Generator

**Location**: `.claude/skills/docs-generator/SKILL.md`

````yaml
---
name: Documentation Generator
description: Generate comprehensive technical documentation from code, including API docs, architecture diagrams, and usage examples
allowed-tools: Read, Grep, Glob, Write
---

# Documentation Generator

## Instructions

When generating documentation:

1. **API Documentation**
   - Extract function signatures
   - Document parameters and return types
   - Provide usage examples
   - Note error conditions

2. **Architecture Documentation**
   - Generate Mermaid diagrams
   - Document data flow
   - Explain design decisions

3. **User Guides**
   - Step-by-step tutorials
   - Common use cases
   - Troubleshooting section

## Supporting Files

- `templates/api-template.md` - API documentation template
- `templates/architecture-template.md` - Architecture doc template
- `examples/` - Example documentation outputs

## Usage

Load appropriate template:
```bash
cat templates/api-template.md
````

Generate documentation and save to `docs/` directory.

````

### 3. Test Generator

**Location**: `~/.claude/skills/test-generator/SKILL.md`

```yaml
---
name: Test Generator
description: Generate comprehensive test suites for TypeScript/JavaScript code, including unit tests, integration tests, and edge cases
allowed-tools: Read, Grep, Write
---

# Test Generator Skill

## Instructions

When generating tests:

1. **Unit Tests**
   - Test all public functions
   - Cover edge cases
   - Test error conditions
   - Mock external dependencies

2. **Integration Tests**
   - Test API endpoints
   - Test database interactions
   - Test file operations

3. **Test Structure**
   - Use descriptive test names
   - Follow AAA pattern (Arrange, Act, Assert)
   - Include setup and teardown
   - Group related tests

## Frameworks

- **Jest**: Primary testing framework
- **React Testing Library**: For React components
- **Supertest**: For API testing

## Example

```typescript
describe('UserService', () => {
  describe('createUser', () => {
    it('should create a user with valid data', async () => {
      // Arrange
      const userData = { email: 'test@example.com', name: 'Test' };

      // Act
      const user = await userService.createUser(userData);

      // Assert
      expect(user).toHaveProperty('id');
      expect(user.email).toBe(userData.email);
    });

    it('should throw error for duplicate email', async () => {
      // Arrange
      const userData = { email: 'existing@example.com', name: 'Test' };

      // Act & Assert
      await expect(userService.createUser(userData))
        .rejects.toThrow('Email already exists');
    });
  });
});
````

````

## Advanced Patterns

### Progressive Disclosure

Structure large Skills with primary instructions in SKILL.md and detailed references in supporting files:

**SKILL.md**:
```markdown
---
name: Enterprise Architecture
description: Design enterprise-scale architectures following company standards
---

# Enterprise Architecture

## Quick Start

1. Review high-level patterns in this file
2. Load specific patterns from `patterns/` as needed
3. Reference `reference.md` for detailed guidelines

## Patterns

- **Microservices**: `patterns/microservices.md`
- **Event-Driven**: `patterns/event-driven.md`
- **API Gateway**: `patterns/api-gateway.md`

## Usage

For microservices design:
```bash
cat patterns/microservices.md
````

```

### Multi-File Skills

**Directory structure**:
```

.claude/skills/api-integration/ ├── SKILL.md ├── reference.md ├── templates/ │
├── rest-client.ts │ └── graphql-client.ts └── examples/ ├── github-api.ts └──
stripe-api.ts

````

**SKILL.md references**:
```markdown
Use templates:
```bash
cat templates/rest-client.ts
````

See examples:

```bash
cat examples/github-api.ts
```

````

## Best Practices

### 1. Descriptive Names

Use clear, specific names that indicate both capability and use case:

**Good**: `TypeScript API Client Generator`
**Poor**: `API Tool`

### 2. Precise Descriptions

Include activation triggers in descriptions:

**Good**: `Generate comprehensive test suites when the user needs tests for TypeScript/JavaScript code`
**Poor**: `Test generator`

### 3. Focused Skills

Create focused Skills for specific tasks rather than monolithic "do everything" Skills:

**Good**:
- `React Component Generator`
- `API Documentation Generator`
- `Database Migration Creator`

**Poor**:
- `Full Stack Developer Skill`

### 4. Tool Restrictions

Use `allowed-tools` to enforce constraints:

```yaml
# Read-only analysis
allowed-tools: Read, Grep, Glob

# Full development
allowed-tools: Read, Write, Edit, Bash, Grep, Glob

# Documentation only
allowed-tools: Read, Write, Grep, Glob
````

### 5. Version Control

Commit project Skills to git:

```bash
git add .claude/skills/
git commit -m "feat: add code review Skill for team standards"
```

### 6. Documentation

Include comprehensive examples in SKILL.md:

```markdown
## Examples

### Example 1: Simple Use Case

User: "Review the authentication module" Output: [detailed review]

### Example 2: Complex Use Case

User: "Review the entire API for security issues" Output: [comprehensive
security audit]
```

## Integration with Agent SDK

Skills in Claude Code can integrate with the Universal Agent SDK for advanced
workflows:

### Session Management

Skills can use SDK sessions for persistent context:

```yaml
---
name: Project Analyzer
description: Analyze project architecture and maintain context across multiple analysis sessions
---

# Project Analyzer

## Instructions

Use SDK session management for multi-turn analysis:

1. Initial scan stores project structure in session
2. Subsequent queries reuse cached analysis
3. Session persists across Claude Code restarts
```

### Cost Tracking

Monitor token usage when using expensive Skills:

```yaml
---
name: Comprehensive Code Review
description: Deep code analysis with cost tracking for large codebases
---

# Comprehensive Code Review

## Instructions

Enable cost tracking for large reviews:

1. Estimate token usage before starting
2. Warn user if review exceeds budget threshold
3. Offer incremental review option for cost control
```

## Plugin Integration

Install Skills from the plugin marketplace:

```bash
# Install anthropics/skills plugin
/plugin marketplace add anthropics/skills

# List installed Skills
/plugin list
```

Plugin Skills appear alongside personal and project Skills.

## Troubleshooting

### Skill Not Activating

1. **Check description**: Ensure it matches your request context
2. **Verify file location**: `~/.claude/skills/` or `.claude/skills/`
3. **Validate YAML frontmatter**: Name and description required
4. **Test explicitly**: "Use the [Skill Name] skill to..."

### File Not Loading

1. **Check file paths**: Use relative paths from SKILL.md location
2. **Verify file exists**: `ls .claude/skills/skill-name/`
3. **Review permissions**: Ensure files are readable

### Tool Restrictions Not Working

1. **Verify `allowed-tools` syntax**: YAML array format
2. **Check tool names**: Must match exactly (case-sensitive)
3. **Test with explicit request**: "Use only Read tool to analyze this file"

## Related Documentation

- [Skills API Guide](skills-api-guide.md) - Using Skills via API
- [Skills User Guide](skills-user-guide.md) - Getting started with Skills
- [What Are Skills](skills-what-are-skills.md) - Concepts and overview
- [Skills Engineering Blog](skills-engineering-blog.md) - Technical architecture
- [Skills Examples](skills-github-examples.md) - Community examples

## See Also

- [Slash Commands](slash-commands.md) - User-invoked commands
- [Agent SDK Overview](overview.md) - Complete SDK architecture
- [Custom Tools](custom-tools.md) - Building custom agent tools
