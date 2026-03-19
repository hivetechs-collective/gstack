---
description: Auto-populate CLAUDE.md with project context from codebase scan. Creates a "memory bank" of project knowledge for efficient agent operation.
argument-hint: [--update] [--dry-run]
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# /init - Project Context Initialization

Automatically scan the codebase and populate CLAUDE.md with comprehensive project context. This creates a "memory bank" that persists across sessions.

## Purpose

- **Fresh projects**: Generate initial CLAUDE.md with detected patterns
- **Existing projects**: Update CLAUDE.md with current state (use `--update`)
- **Session start**: Ensure context is accurate and complete

---

## Execution Steps

### Step 1: Detect Project Type and Tech Stack

Scan for configuration files to identify the project:

```bash
# Check for package managers and languages
ls -la package.json 2>/dev/null && echo "NODE_PROJECT"
ls -la Cargo.toml 2>/dev/null && echo "RUST_PROJECT"
ls -la go.mod 2>/dev/null && echo "GO_PROJECT"
ls -la pyproject.toml requirements.txt 2>/dev/null && echo "PYTHON_PROJECT"
ls -la pnpm-lock.yaml 2>/dev/null && echo "PNPM"
ls -la yarn.lock 2>/dev/null && echo "YARN"
ls -la bun.lockb 2>/dev/null && echo "BUN"
ls -la package-lock.json 2>/dev/null && echo "NPM"
```

**Record findings:**

- Primary language(s)
- Package manager
- Monorepo detection (turbo.json, nx.json, lerna.json, pnpm-workspace.yaml)

### Step 2: Scan Project Structure

```bash
# Get directory structure (depth 3, ignore node_modules etc)
find . -type d -maxdepth 3 \
  -not -path "*/node_modules/*" \
  -not -path "*/.git/*" \
  -not -path "*/dist/*" \
  -not -path "*/.next/*" \
  -not -path "*/coverage/*" \
  -not -path "*/.expo/*" \
  | head -50
```

**Identify key directories:**

- `src/`, `app/`, `apps/`, `packages/` - Source code
- `docs/`, `documentation/` - Documentation
- `tests/`, `__tests__/`, `spec/` - Testing
- `scripts/`, `tools/` - Tooling
- `.claude/` - Claude Code configuration
- `prisma/`, `drizzle/`, `migrations/` - Database

### Step 3: Detect Frameworks and Libraries

**For Node.js projects, read package.json:**

```
Read package.json
```

**Identify key dependencies:**

- **Frontend**: React, Vue, Svelte, Angular, Next.js, Remix, Astro
- **Backend**: Express, Fastify, Hono, NestJS, tRPC
- **Database**: Prisma, Drizzle, TypeORM, Mongoose, Kysely
- **Testing**: Jest, Vitest, Playwright, Cypress
- **Styling**: Tailwind, styled-components, CSS Modules
- **State**: Redux, Zustand, Jotai, TanStack Query

**For Rust projects, read Cargo.toml:**

```
Read Cargo.toml
```

### Step 4: Detect Configuration Patterns

```bash
# Find configuration files
ls -la tsconfig*.json 2>/dev/null
ls -la .eslintrc* eslint.config.* 2>/dev/null
ls -la .prettierrc* prettier.config.* 2>/dev/null
ls -la vitest.config.* jest.config.* 2>/dev/null
ls -la tailwind.config.* 2>/dev/null
ls -la next.config.* 2>/dev/null
ls -la wrangler.toml 2>/dev/null  # Cloudflare Workers
ls -la vercel.json netlify.toml 2>/dev/null  # Deployment
ls -la docker-compose*.yml Dockerfile 2>/dev/null  # Docker
ls -la .github/workflows/*.yml 2>/dev/null  # CI/CD
```

### Step 5: Detect Database and API Patterns

```bash
# Database schemas
ls -la prisma/schema.prisma 2>/dev/null
ls -la drizzle/*.ts 2>/dev/null
ls -la src/db/*.sql 2>/dev/null
ls -la migrations/ 2>/dev/null

# API patterns
find . -name "*.ts" -path "*/routes/*" -o -name "*.ts" -path "*/api/*" 2>/dev/null | head -10
find . -name "*.graphql" -o -name "*.gql" 2>/dev/null | head -5
```

### Step 6: Detect Existing Documentation

```bash
# Key documentation files
ls -la README.md ARCHITECTURE.md CONTRIBUTING.md 2>/dev/null
ls -la docs/*.md 2>/dev/null | head -10
ls -la CLAUDE.md .claude/CLAUDE.md 2>/dev/null
```

### Step 7: Detect Testing Setup

```bash
# Test files
find . -name "*.test.ts" -o -name "*.spec.ts" -o -name "*.test.tsx" 2>/dev/null | wc -l
find . -name "*.test.rs" 2>/dev/null | wc -l

# E2E tests
ls -la e2e/ tests/e2e/ playwright/ cypress/ 2>/dev/null
```

### Step 8: Detect Claude Code Integration

```bash
# Claude-specific files
ls -la .claude/ 2>/dev/null
ls -la .claude/agents/ 2>/dev/null | wc -l
ls -la .claude/commands/ 2>/dev/null | wc -l
ls -la .claude/hooks/ 2>/dev/null
ls -la .claude/settings.json 2>/dev/null
ls -la fix_plan.md @AGENT.md PROMPT.md 2>/dev/null  # Ralph integration
```

---

## Step 9: Generate CLAUDE.md Content

Based on the scan, generate or update CLAUDE.md with the following sections:

### Template for Generated Content

```markdown
# Project-Specific Instructions

## Project Overview

**Project Name**: [Detected from package.json/Cargo.toml or directory name]
**Type**: [Web App | API | Library | CLI | Monorepo]
**Primary Language**: [TypeScript | Rust | Go | Python]
**Package Manager**: [pnpm | yarn | npm | bun | cargo]

## Tech Stack

### Frontend

- [Framework]: [version]
- [UI Library]: [version]
- [State Management]: [if detected]

### Backend

- [Framework]: [version]
- [Database ORM]: [version]
- [API Style]: REST | GraphQL | tRPC

### Infrastructure

- [Deployment]: Cloudflare | Vercel | AWS | Docker
- [Database]: PostgreSQL | SQLite | MongoDB
- [CI/CD]: GitHub Actions | GitLab CI

## Project Structure
```

[Auto-generated directory tree]

````

### Key Directories
- `[path]` - [purpose]
- ...

## Development Commands

```bash
# Install dependencies
[detected package manager] install

# Development
[detected dev command]

# Testing
[detected test command]

# Build
[detected build command]

# Type checking
[detected typecheck command]
````

## File Naming Conventions

- Components: [PascalCase.tsx | kebab-case.tsx]
- Utilities: [camelCase.ts | kebab-case.ts]
- Tests: [*.test.ts | *.spec.ts]
- Styles: [*.module.css | *.css]

## Architecture Patterns

[Detected patterns from codebase analysis]

## Claude Code Integration

- **Agents**: [count] specialized agents available
- **Commands**: [list key commands]
- **Hooks**: [list active hooks]
- **Ralph Integration**: [Yes/No - based on fix_plan.md detection]

## Current State

**Last Scanned**: [timestamp]
**Uncommitted Changes**: [count from git status]
**Active Branch**: [from git]

```

---

## Step 10: Write or Update CLAUDE.md

**For new projects (no CLAUDE.md exists):**
- Create CLAUDE.md with full template
- Include `@~/.claude/CLAUDE.md` import at top

**For existing projects (`--update` flag):**
- Read existing CLAUDE.md
- Preserve custom sections (marked with `<!-- CUSTOM -->`)
- Update auto-generated sections (marked with `<!-- AUTO-GENERATED -->`)

**For dry-run (`--dry-run` flag):**
- Output generated content to console
- Do not write to file

---

## Output Format

After completion, report:

```

/init complete

Project: [name]
Type: [type]
Tech Stack: [primary framework] + [key libraries]
Structure: [monorepo | single-app]

Updated Sections:
✅ Project Overview
✅ Tech Stack
✅ Project Structure
✅ Development Commands
✅ Architecture Patterns

Claude Code Integration:
📦 [X] agents available
🔧 [Y] commands configured
🪝 [Z] hooks active
🤖 Ralph: [Ready | Not configured]

Memory bank updated. Context ready for development.

```

---

## Notes

- Run `/init` at the start of each project or after major changes
- Use `/init --update` to refresh without losing custom sections
- Use `/init --dry-run` to preview changes
- Integrates with Ralph workflow - ensures fix_plan.md detection
- Complements `/context` command (init generates, context loads)
```
