# Custom Commands Research & Workflow Analysis

**Mission**: Design custom slash commands to enhance development workflows across three repositories

**Orchestrator**: Task Orchestrator
**Date**: 2025-10-08
**Agent**: claude-sdk-expert (research delegate)

---

## Executive Summary

After analyzing the Claude SDK slash command documentation and examining workflow patterns across three active repositories (claude-pattern, Hive Consensus IDE, HiveTechs Website), I've identified significant automation opportunities through custom slash commands. This document synthesizes SDK capabilities with real-world workflow needs to propose 15 high-value custom commands.

---

## Section 1: SDK Slash Command Capabilities

### Core Command Features (from SDK Documentation)

**1. Command Discovery**
- Commands auto-discovered from `.claude/commands/` (project) and `~/.claude/commands/` (global)
- Available commands exposed via `system.init` message with `slash_commands` array
- Supports nested namespacing via subdirectories (e.g., `/code/review`, `/db/migrate`)

**2. Frontmatter Configuration**

```yaml
---
description: What the command does
argument-hint: [expected-args]
allowed-tools:
  - Read
  - Write
  - Bash(git:*)
  - Grep
  - Glob
permission-mode: default
max-turns: 10
---
```

**3. Bash Execution Patterns**
- Inline bash commands prefixed with `!` execute before prompt processing
- Example: `!`git status --short`` runs and output injected into prompt context
- Supports multi-step workflows with sequential bash operations

**4. Argument Handling**
- `$ARGUMENTS` variable contains user-provided arguments
- `${ARGUMENTS:-default}` provides fallback values
- Arguments parsed from command invocation: `/command arg1 arg2`

**5. Tool Restrictions**
- `allowed-tools` limits which tools the command can use
- Supports glob patterns: `Bash(git:*)` allows only git commands
- Enhances security by preventing unintended tool usage

**6. Namespacing Strategy**
- Subdirectories create command hierarchies
- Examples from existing setup:
  - `.claude/commands/agent_prompts/` for agent-specific commands
  - `.claude/commands/design/` for design workflow commands
  - `.claude/commands/dev/` for development commands

---

## Section 2: Workflow Pattern Analysis

### 2.1 Hive Consensus IDE Workflows

**Project Characteristics**:
- Rust backend (WebSocket consensus engine, port management)
- Electron frontend (IPC, main/renderer coordination)
- Complex release pipeline (17 phases: build → sign → notarize → publish)
- macOS-specific: Code signing with 239-line script
- Homebrew distribution via custom tap

**Repetitive Workflows Identified**:

1. **Rust Build & Test Cycle**
   - `cargo check` → `cargo clippy` → `cargo test` → `cargo build --release`
   - Target: `aarch64-apple-darwin` (M1/M2 Macs)
   - Verification: PortManager, ProcessManager integration tests

2. **Electron IPC Testing**
   - Validate IPC handlers in main process
   - Test renderer process communication
   - Verify consensus message propagation across 4 stages

3. **macOS Code Signing Workflow**
   - Deep signing: Scan for all Mach-O binaries (find + file command)
   - Apply entitlements (JIT, library validation, unsigned memory)
   - Notarize via `notarytool` with error recovery
   - Staple notarization ticket

4. **Release Coordination**
   - Version bump across Cargo.toml, package.json, Info.plist
   - Build binaries for macOS (Intel + Apple Silicon)
   - Sign and notarize `.app` bundle
   - Create DMG, notarize DMG
   - Update Homebrew cask with new SHA256
   - Publish to GitHub releases

5. **Agent Coordination Testing**
   - Consensus analysis across 4 stages
   - Memory optimization for SQLite Memory Service
   - Multi-agent output validation

### 2.2 HiveTechs Website Workflows

**Project Characteristics**:
- Next.js 14/15 with App Router (server components, dynamic routes)
- Cloudflare Workers deployment (edge runtime)
- D1 database (SQLite at edge), R2 storage, KV cache
- SMTP2GO email integration (magic links, transactional emails)
- Portal authentication system

**Repetitive Workflows Identified**:

1. **Cloudflare Development Cycle**
   - `wrangler dev --local` for local testing
   - `wrangler types` to generate bindings
   - `wrangler deploy --dry-run` for pre-flight checks
   - `wrangler deploy --env production` for deployment

2. **D1 Database Migrations**
   - Schema changes in local dev
   - Generate migration files
   - Test migrations locally
   - Apply to production D1 database
   - Verify data integrity

3. **Next.js Build & Deploy Workflow**
   - `npm run build` with OpenNext adapter for Cloudflare
   - Validate SSR/SSG routes work in edge runtime
   - Check environment variable configuration
   - Deploy with Wrangler

4. **API Route Validation**
   - Test REST endpoints (auth, portal, webhooks)
   - Verify D1 query performance
   - Check edge runtime constraints (no Node.js APIs)
   - Rate limiting and CORS validation

5. **Email Template Testing**
   - Magic link generation
   - SMTP2GO API integration
   - Deliverability checks
   - Bounce/spam handling

### 2.3 Claude Pattern Repository Workflows

**Project Characteristics**:
- Agent development and testing (31 agents at v1.1.0)
- SDK documentation maintenance (17 complete doc files)
- Design workflow commands (`/design-app`, `/implement-app`)
- Cross-repository integration (Hive, Website)

**Repetitive Workflows Identified**:

1. **Agent Creation Workflow**
   - Create agent definition with frontmatter (name, version, description, color)
   - Define SDK features (subagents, sessions, cost_tracking)
   - Write MCP usage guidelines
   - Add to orchestrator's agent registry
   - Update agent count and version tracking

2. **SDK Documentation Updates**
   - Fetch latest docs from Anthropic (WebFetch/WebSearch)
   - Convert to local markdown format
   - Update INDEX.md with new content
   - Update REFRESH.md timestamp
   - Validate code examples

3. **Design-to-Implementation Workflow**
   - `/design-app` creates design specifications (ui-designer, shadcn-expert, api-expert)
   - Outputs to `.claude/outputs/design/projects/[name]/[timestamp]/`
   - MANIFEST.md tracks all agent outputs
   - `/implement-app` consumes design specs for Next.js app generation

4. **Cross-Repository Agent Testing**
   - Test agent in claude-pattern
   - Copy to Hive `.claude/agents/`
   - Copy to Website `.claude/agents/`
   - Validate agent works in all three contexts

5. **Multi-Agent Coordination Validation**
   - Orchestrator assigns agents to tasks
   - PM coordination prevents file conflicts
   - Verify compilation after agent tasks
   - Integration validation

---

## Section 3: Automation Opportunities

### 3.1 High-Value Multi-Step Workflows

**Opportunity 1: Release Pipeline Automation**
- **Current**: Manual 17-phase process (Hive), multi-step deployment (Website)
- **Proposed**: `/release` command family with pre-flight checks
- **Value**: Reduces 2-hour release process to 20 minutes with automated verification

**Opportunity 2: Pre-Commit Quality Gates**
- **Current**: Manual linting, testing, type-checking before commits
- **Proposed**: `/pre-commit` command with configurable checks
- **Value**: Prevents broken commits, enforces quality standards

**Opportunity 3: Agent Development Lifecycle**
- **Current**: Manual agent creation, testing, cross-repo sync
- **Proposed**: `/agent/create`, `/agent/test`, `/agent/sync` commands
- **Value**: Standardizes agent development, ensures consistency

**Opportunity 4: Database Migration Management**
- **Current**: Manual Prisma/D1 migration workflows
- **Proposed**: `/db/migrate`, `/db/rollback`, `/db/verify` commands
- **Value**: Safe, repeatable database changes with rollback capability

**Opportunity 5: Multi-Agent Coordination Shortcuts**
- **Current**: Manual orchestrator invocation with PM coordination
- **Proposed**: `/team/build`, `/team/fix`, `/team/review` commands
- **Value**: One command triggers optimal agent teams for common tasks

### 3.2 Project-Specific Automation Needs

**Hive-Specific Commands**:
1. Rust build verification chain
2. macOS signing and notarization orchestration
3. Homebrew cask update automation
4. Electron IPC validation
5. Consensus engine testing

**Website-Specific Commands**:
1. Cloudflare deployment validation
2. D1 migration workflow
3. Edge runtime compatibility checks
4. Email template testing
5. Portal authentication verification

**Pattern-Specific Commands**:
1. Agent creation wizard
2. SDK documentation refresh
3. Design workflow validation
4. Cross-repository sync
5. Multi-agent testing

---

## Section 4: Proposed Custom Commands (15 Commands)

### 4.1 Universal Commands (Work Across All Projects)

#### Command 1: `/qa-all` - Comprehensive Quality Assurance

**File**: `.claude/commands/qa-all.md`

```markdown
---
description: Run all quality checks (lint, test, type-check, build)
allowed-tools:
  - Bash
  - Read
  - Grep
argument-hint: [skip-tests]
max-turns: 5
---

# Quality Assurance - All Checks

Run comprehensive quality checks before committing or deploying.

## Detect Project Type
!`test -f Cargo.toml && echo "rust" || (test -f package.json && echo "node") || echo "unknown"`

## Rust Projects
If Cargo.toml exists:
!`cargo fmt --check`
!`cargo clippy -- -D warnings`
!`cargo test --all-features`
!`cargo build --release`

## Node.js Projects
If package.json exists:
!`npm run lint || echo "No lint script"`
!`npm run type-check || echo "No type-check script"`
!`[ "$ARGUMENTS" != "skip-tests" ] && npm test || echo "Tests skipped"`
!`npm run build`

## Report
Summarize all check results:
- Which checks passed/failed
- Severity of failures
- Recommended fixes
- Safe to commit/deploy?
```

**Agent Coordination**: None (runs bash commands directly)

**Use Cases**:
- Pre-commit verification
- Pre-deployment validation
- CI/CD local simulation
- Pull request quality checks

---

#### Command 2: `/team/fix` - Multi-Agent Bug Fix Coordination

**File**: `.claude/commands/team/fix.md`

```markdown
---
description: Coordinate multi-agent team to diagnose and fix bugs
allowed-tools:
  - Task
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
argument-hint: [error-description-or-log-file]
max-turns: 20
---

# Multi-Agent Bug Fix Workflow

Coordinate specialized agents to diagnose and fix complex bugs.

## Input
Error description: $ARGUMENTS

## Get Recent Error Logs
!`tail -100 ~/.claude/violations.log 2>/dev/null || echo "No violation log"`
!`git diff --name-only HEAD`
!`git status --short`

## Agent Coordination Strategy

Invoke orchestrator with PM coordination:

**Phase 1: Diagnosis (Parallel Analysis)**
- @agent-security-expert: Check for security vulnerabilities
- @agent-code-review-expert: Analyze code quality issues
- @agent-git-expert: Check for merge conflicts or file dependency issues

**Phase 2: Root Cause Analysis**
- @agent-system-architect: Identify architectural issues
- @agent-database-expert: Check for database-related problems (if applicable)
- @agent-api-expert: Verify API integration issues (if applicable)

**Phase 3: Fix Implementation (PM-Coordinated)**
- PM creates conflict-free work breakdown
- Assigns specialized agents to specific files/modules
- Verifies compilation after each agent task
- Coordinates integration of fixes

**Phase 4: Verification**
- Run `/qa-all` to verify fix
- Execute relevant tests
- Confirm no regressions introduced

## Success Criteria
- [ ] Bug root cause identified
- [ ] Fix implemented and tested
- [ ] No compilation errors
- [ ] All tests passing
- [ ] Code review approved
```

**Agent Coordination**: Orchestrator → PM → Specialist Agents (security, code-review, git, system-architect, database, api)

**Use Cases**:
- Complex multi-file bugs
- Performance regressions
- Security vulnerabilities
- Integration failures

---

#### Command 3: `/team/review` - Automated Code Review

**File**: `.claude/commands/team/review.md`

```markdown
---
description: Multi-agent code review with security, performance, and quality analysis
allowed-tools:
  - Bash(git:*)
  - Read
  - Grep
  - Glob
  - Task
argument-hint: [commit-or-branch]
max-turns: 15
---

# Multi-Agent Code Review

Comprehensive code review with specialized agent perspectives.

## Changed Files
!`git diff --name-only ${ARGUMENTS:-HEAD~1}`

## Detailed Changes
!`git diff ${ARGUMENTS:-HEAD~1}`

## Agent Review Coordination

**Security Review** (@agent-security-expert):
- OWASP Top 10 vulnerabilities
- Input validation and sanitization
- Authentication/authorization flaws
- Secrets management issues
- Dependency vulnerabilities

**Performance Review** (@agent-python-ml-expert or @agent-react-typescript-specialist):
- Algorithm complexity analysis
- Memory usage patterns
- Database query optimization
- Bundle size and lazy loading (frontend)
- Async/await usage (avoid blocking I/O)

**Code Quality Review** (@agent-code-review-expert):
- Clean code principles
- SOLID patterns
- DRY violations
- Error handling completeness
- Documentation quality

**Architecture Review** (@agent-system-architect):
- Design pattern adherence
- Module coupling and cohesion
- Scalability implications
- Tech debt introduced

**Git Workflow Review** (@agent-git-expert):
- Commit message quality
- Branch strategy adherence
- Merge conflict risks
- File dependency analysis

## Consolidated Report

Synthesize all agent reviews into:
1. **Critical Issues**: Must fix before merge
2. **High Priority**: Should fix soon
3. **Medium Priority**: Consider addressing
4. **Low Priority**: Nice-to-have improvements
5. **Positive Highlights**: What was done well

Provide actionable feedback with specific line numbers and code suggestions.
```

**Agent Coordination**: Orchestrator → security-expert, python-ml-expert/react-typescript-specialist, code-review-expert, system-architect, git-expert (parallel reviews)

**Use Cases**:
- Pull request reviews
- Pre-merge quality gates
- Learning from expert feedback
- Team code review standards

---

#### Command 4: `/agent/create` - Agent Development Wizard

**File**: `.claude/commands/agent/create.md`

```markdown
---
description: Create new specialized agent with SDK features and best practices
allowed-tools:
  - Write
  - Read
  - Edit
  - Task
argument-hint: <agent-name> <specialty>
max-turns: 10
---

# Agent Creation Wizard

Create production-ready agent definitions with SDK v1.1.0 features.

## Parse Arguments
Agent name: ${ARGUMENTS%% *}
Specialty: ${ARGUMENTS#* }

## Agent Definition Template

Coordinate with @agent-documentation-expert to create:

**Agent File**: `.claude/agents/research-planning/${ARGUMENTS%% *}.md`

**Required Sections**:
1. **Frontmatter**:
   - name: kebab-case
   - version: 1.1.0 (start at current SDK version)
   - description: Clear use case with examples
   - color: Choose from (cyan, orange, purple, red, blue, yellow, green, magenta)
   - model: inherit
   - sdk_features: [subagents, sessions, cost_tracking, tool_restrictions, lifecycle_hooks]
   - cost_optimization: true
   - session_aware: true
   - sdk_self_aware: true (if agent uses SDK docs)

2. **MCP Tool Usage Guidelines**:
   - Sequential thinking use cases
   - Filesystem MCP patterns
   - Memory integration
   - Git/REF usage where applicable

3. **Core Expertise Section**:
   - Domain knowledge
   - Key workflows
   - Best practices
   - Code examples

4. **Integration Patterns**:
   - How to invoke this agent
   - What context it needs
   - Expected outputs
   - Common use cases

## Post-Creation Tasks

1. Update orchestrator.md agent registry
2. Add agent to version tracking (SDK_UPGRADE_SUMMARY.md)
3. Create usage examples
4. Test agent in isolated task
5. Document in agent library

## Validation Checklist
- [ ] Frontmatter complete and valid
- [ ] MCP guidelines included
- [ ] Examples use correct syntax
- [ ] Color assigned (avoid duplicates)
- [ ] SDK features appropriate for specialty
- [ ] Integration patterns documented
```

**Agent Coordination**: Orchestrator → documentation-expert

**Use Cases**:
- Creating new specialized agents
- Standardizing agent format
- SDK version consistency
- Agent library expansion

---

### 4.2 Hive-Specific Commands

#### Command 5: `/hive/sign` - macOS Signing & Notarization

**File**: `.claude/commands/hive/sign.md`

```markdown
---
description: Sign and notarize Hive Consensus IDE macOS app bundle
allowed-tools:
  - Bash
  - Read
  - Grep
  - Task
argument-hint: [path-to-app]
max-turns: 10
---

# Hive macOS Signing & Notarization

Coordinate @agent-macos-signing-expert to sign and notarize Hive.app.

## App Bundle Path
Target: ${ARGUMENTS:-./release/Hive.app}

## Pre-Flight Checks
!`test -d "${ARGUMENTS:-./release/Hive.app}" && echo "App bundle exists" || echo "ERROR: App bundle not found"`
!`codesign --verify --strict "${ARGUMENTS:-./release/Hive.app}" 2>&1 || echo "Not signed yet"`

## Signing Workflow (via macos-signing-expert)

**Phase 1: Deep Binary Signing**
1. Scan for all Mach-O binaries (find + file command)
2. Sign embedded binaries first (bottom-up approach)
3. Apply entitlements to helpers and executables
4. Handle versioned frameworks (Versions/A pattern)
5. Seal app bundle with final signature

**Phase 2: Verification**
- `codesign --verify --deep --strict Hive.app`
- `codesign --display --verbose=4 Hive.app` (check runtime flags)
- `spctl --assess --verbose Hive.app` (Gatekeeper assessment)

**Phase 3: Notarization**
1. Create DMG or ZIP for submission
2. Submit via `xcrun notarytool submit --keychain-profile HiveProfile --wait`
3. Capture submission ID
4. On failure, fetch logs: `xcrun notarytool log <id> output.json`
5. Parse JSON issues and fix
6. Resubmit if needed

**Phase 4: Stapling**
- `xcrun stapler staple Hive.app` (embed notarization ticket)
- `xcrun stapler validate Hive.app`

## Success Criteria
- [ ] All binaries signed with hardened runtime
- [ ] Entitlements applied correctly (JIT, library validation)
- [ ] Notarization accepted
- [ ] Ticket stapled
- [ ] Gatekeeper assessment passes
```

**Agent Coordination**: Orchestrator → macos-signing-expert

**Use Cases**:
- Release builds for distribution
- Debugging Gatekeeper failures
- CI/CD signing automation
- Entitlements troubleshooting

---

#### Command 6: `/hive/release` - Full Release Pipeline

**File**: `.claude/commands/hive/release.md`

```markdown
---
description: Execute Hive's 17-phase release pipeline with governance
allowed-tools:
  - Task
  - Bash
  - Read
  - Write
  - Edit
  - Grep
argument-hint: <version> [skip-phases]
max-turns: 30
---

# Hive Consensus IDE Release Pipeline

Coordinate release-orchestrator and governance-expert for complete release.

## Version
Target version: $ARGUMENTS

## Pre-Release Governance (via governance-expert)

**Quality Gates**:
- [ ] All tests passing (Rust + Electron + Integration)
- [ ] Code review completed
- [ ] Security audit passed
- [ ] Performance benchmarks met
- [ ] Documentation updated
- [ ] Changelog prepared

## 17-Phase Release Pipeline (via release-orchestrator)

**Phase 1-5: Build & Quality**
1. Version bump (Cargo.toml, package.json, Info.plist)
2. Rust backend build (cargo build --release --target aarch64-apple-darwin)
3. Electron frontend build (npm run build)
4. Run full test suite
5. Pre-release quality verification

**Phase 6-10: Signing & Packaging**
6. Deep binary signing (via /hive/sign)
7. Notarization submission
8. Notarization verification
9. Staple notarization ticket
10. Create DMG with signed app

**Phase 11-15: Publication**
11. Sign and notarize DMG
12. Upload to GitHub releases
13. Update Homebrew cask (SHA256, version)
14. Homebrew audit verification
15. npm package publish (if applicable)

**Phase 16-17: Verification & Rollback**
16. Post-deployment verification (download from Homebrew, test install)
17. Rollback plan ready (previous version available)

## Agent Coordination
- @agent-governance-expert: Pre-release gates, approval workflows
- @agent-release-orchestrator: Pipeline coordination
- @agent-macos-signing-expert: Signing and notarization
- @agent-homebrew-publisher: Cask updates
- @agent-devops-automation-expert: CI/CD integration

## Success Metrics
- [ ] All 17 phases completed successfully
- [ ] Homebrew cask installs correctly
- [ ] App launches without Gatekeeper warnings
- [ ] No critical bugs in first 24 hours
```

**Agent Coordination**: Orchestrator → governance-expert, release-orchestrator, macos-signing-expert, homebrew-publisher, devops-automation-expert

**Use Cases**:
- Major/minor version releases
- Hotfix deployments
- Release process testing
- CI/CD automation

---

#### Command 7: `/hive/test-consensus` - Consensus Engine Validation

**File**: `.claude/commands/hive/test-consensus.md`

```markdown
---
description: Test Hive's 4-stage consensus engine with multi-agent coordination
allowed-tools:
  - Bash
  - Read
  - Grep
  - Task
argument-hint: [test-scenario]
max-turns: 15
---

# Consensus Engine Testing

Test Hive's 4-stage consensus with specialized agents.

## Test Scenario
Scenario: ${ARGUMENTS:-default-consensus-flow}

## Run Consensus Tests
!`cd /Users/veronelazio/Developer/Private/hive && cargo test --test consensus_integration -- --nocapture`

## Multi-Agent Analysis

**Consensus Analyzer** (@agent-consensus-analyzer):
- Analyze consensus results from all 4 stages
- Verify message propagation
- Check state consistency
- Validate merge algorithms

**Rust Backend Expert** (@agent-rust-backend-expert):
- Review WebSocket message handling
- Check Tokio async patterns
- Verify error handling in consensus logic
- Analyze performance bottlenecks

**Memory Optimizer** (@agent-memory-optimizer):
- Check SQLite Memory Service performance
- Analyze query optimization opportunities
- Verify index usage
- Memory usage patterns

**Electron Specialist** (@agent-electron-specialist):
- Verify IPC communication correctness
- Check ProcessManager integration
- Test PortManager coordination
- Renderer process state sync

## Integration Report

Synthesize findings:
1. Consensus correctness verification
2. Performance metrics (latency, throughput)
3. Memory usage analysis
4. IPC reliability assessment
5. Recommended optimizations
```

**Agent Coordination**: Orchestrator → consensus-analyzer, rust-backend-expert, memory-optimizer, electron-specialist

**Use Cases**:
- Pre-release consensus validation
- Performance regression testing
- Debugging consensus failures
- Optimization analysis

---

### 4.3 Website-Specific Commands

#### Command 8: `/web/deploy-check` - Cloudflare Deployment Validation

**File**: `.claude/commands/web/deploy-check.md`

```markdown
---
description: Validate Next.js app for Cloudflare Workers deployment
allowed-tools:
  - Bash
  - Read
  - Grep
  - Task
max-turns: 10
---

# Cloudflare Deployment Pre-Flight Checks

Coordinate cloudflare-expert and nextjs-expert for deployment validation.

## Current Directory
!`pwd`

## Pre-Flight Checks

**1. Wrangler Types Generation**
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && wrangler types`

**2. Build Validation**
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && npm run build`

**3. Dry-Run Deployment**
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && wrangler deploy --dry-run`

**4. Environment Variables Check**
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && wrangler secret list`

## Agent Analysis

**Cloudflare Expert** (@agent-cloudflare-expert):
- Review wrangler.toml configuration
- Verify D1 database bindings
- Check KV/R2 namespaces
- Validate edge runtime compatibility
- Review Worker size limits

**Next.js Expert** (@agent-nextjs-expert):
- Verify App Router patterns are edge-compatible
- Check for Node.js APIs usage (forbidden in Workers)
- Review server component patterns
- Validate dynamic routes configuration
- Check OpenNext adapter settings

**Security Expert** (@agent-security-expert):
- Verify environment variable usage
- Check for hardcoded secrets
- Review CORS configuration
- Validate authentication patterns
- Check rate limiting implementation

## Deployment Readiness Report

Provide checklist:
- [ ] Build succeeds without errors
- [ ] Wrangler types generated successfully
- [ ] No Node.js APIs in edge routes
- [ ] All environment variables set
- [ ] D1 migrations applied
- [ ] Security review passed
- [ ] Performance budget met (Worker size, CPU time)
- [ ] Safe to deploy to production
```

**Agent Coordination**: Orchestrator → cloudflare-expert, nextjs-expert, security-expert

**Use Cases**:
- Pre-deployment validation
- Edge runtime compatibility checks
- Security audits before production
- Debugging deployment failures

---

#### Command 9: `/web/db-migrate` - D1 Migration Workflow

**File**: `.claude/commands/web/db-migrate.md`

```markdown
---
description: Create and apply D1 database migrations with rollback support
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Task
argument-hint: <migration-name>
max-turns: 10
---

# D1 Database Migration Workflow

Coordinate database-expert and cloudflare-expert for safe migrations.

## Migration Name
Name: ${ARGUMENTS:-schema-update}

## Current Schema
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && cat prisma/schema.prisma 2>/dev/null || echo "No Prisma schema"`

## Migration Workflow

**Phase 1: Generate Migration** (@agent-database-expert):
1. Analyze schema changes
2. Generate SQL migration file
3. Review for:
   - Data loss risks (DROP TABLE, ALTER COLUMN)
   - Index creation impact
   - Foreign key constraints
   - SQLite compatibility (D1 uses SQLite)
4. Create rollback migration

**Phase 2: Local Testing** (@agent-cloudflare-expert):
1. Apply migration to local D1 database
   !`wrangler d1 execute hivetechs-db --local --file=./migrations/${ARGUMENTS}.sql`
2. Run integration tests
3. Verify data integrity
4. Test rollback procedure

**Phase 3: Production Deployment**
1. Backup current database (D1 export)
2. Apply migration to production:
   !`wrangler d1 execute hivetechs-db --remote --file=./migrations/${ARGUMENTS}.sql`
3. Verify migration success
4. Monitor for errors

**Phase 4: Verification**
- Query production database to confirm schema
- Run smoke tests on API routes
- Check for performance regressions
- Validate application functionality

## Rollback Plan

If migration fails:
!`wrangler d1 execute hivetechs-db --remote --file=./migrations/${ARGUMENTS}-rollback.sql`

## Success Criteria
- [ ] Migration SQL reviewed and approved
- [ ] Rollback script created
- [ ] Local testing passed
- [ ] Production migration succeeded
- [ ] Application functional post-migration
- [ ] No data loss or corruption
```

**Agent Coordination**: Orchestrator → database-expert, cloudflare-expert

**Use Cases**:
- Schema evolution
- Production database updates
- Migration rollback scenarios
- Database performance optimization

---

#### Command 10: `/web/email-test` - Email System Validation

**File**: `.claude/commands/web/email-test.md`

```markdown
---
description: Test SMTP2GO email integration and magic link flow
allowed-tools:
  - Bash
  - Read
  - Task
argument-hint: [test-email]
max-turns: 8
---

# Email System Testing

Test SMTP2GO integration and magic link authentication flow.

## Test Email
Target: ${ARGUMENTS:-test@example.com}

## Email Configuration Check
!`cd /Users/veronelazio/Developer/Private/hivetechs-website && grep -E "SMTP2GO|EMAIL" .env.local 2>/dev/null || echo "Check .env.local for SMTP2GO credentials"`

## Agent Coordination

**SMTP2GO Expert** (@agent-smtpgo-expert):
1. Verify API credentials
2. Test email sending via SMTP2GO API
3. Check deliverability (SPF, DKIM, DMARC)
4. Monitor bounce rates
5. Review email templates (magic link, welcome, notifications)

**API Expert** (@agent-api-expert):
1. Test magic link generation endpoint
2. Verify token security (expiration, one-time use)
3. Check rate limiting on email endpoints
4. Validate email address sanitization
5. Test webhook handling (bounces, complaints)

## Test Workflow

**1. Magic Link Generation**
Send test request:
!`curl -X POST http://localhost:3000/api/auth/magic-link -H "Content-Type: application/json" -d '{"email":"${ARGUMENTS:-test@example.com}"}'`

**2. Email Delivery Verification**
- Check SMTP2GO dashboard for delivery status
- Verify email received in inbox (not spam)
- Validate magic link format and expiration

**3. Authentication Flow**
- Click magic link
- Verify token validation
- Check session creation
- Test portal access

## Success Criteria
- [ ] Email sent successfully via SMTP2GO
- [ ] Magic link delivered (not in spam)
- [ ] Token validation works correctly
- [ ] Session created on authentication
- [ ] Rate limiting prevents abuse
- [ ] Bounce handling configured
```

**Agent Coordination**: Orchestrator → smtpgo-expert, api-expert

**Use Cases**:
- Email deliverability testing
- Magic link flow validation
- SMTP2GO integration debugging
- Spam filter troubleshooting

---

### 4.4 Pattern Repository Commands

#### Command 11: `/agent/sync` - Cross-Repository Agent Sync

**File**: `.claude/commands/agent/sync.md`

```markdown
---
description: Sync agent definitions across claude-pattern, Hive, and Website repos
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
  - Task
argument-hint: <agent-name> [target-repos]
max-turns: 8
---

# Cross-Repository Agent Synchronization

Sync agent definitions across three active repositories.

## Agent to Sync
Agent: ${ARGUMENTS%% *}
Target repos: ${ARGUMENTS#* }

## Source Repository
Source: /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/

## Target Repositories
1. Hive: /Users/veronelazio/Developer/Private/hive/.claude/agents/
2. Website: /Users/veronelazio/Developer/Private/hivetechs-website/.claude/agents/

## Sync Workflow

**Phase 1: Validation**
- Verify agent exists in source repository
- Check agent version (should be ≥1.1.0)
- Validate frontmatter structure
- Confirm SDK features are properly defined

**Phase 2: Pre-Sync Analysis**
- Check if agent already exists in target repos
- Compare versions (skip if target is newer)
- Identify any local customizations to preserve
- List files to be copied

**Phase 3: Sync Execution**
For each target repository:
!`cp /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/**/${ARGUMENTS%% *}.md /Users/veronelazio/Developer/Private/hive/.claude/agents/**/ 2>/dev/null || echo "Hive: Agent category not found, manual placement needed"`

!`cp /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/**/${ARGUMENTS%% *}.md /Users/veronelazio/Developer/Private/hivetechs-website/.claude/agents/**/ 2>/dev/null || echo "Website: Agent category not found"`

**Phase 4: Verification**
- Confirm agent file exists in all target repos
- Verify file contents match (diff comparison)
- Update orchestrator.md agent registries if needed
- Run smoke test: invoke agent in each repo

## Report
Summarize sync status:
- ✅ Repos successfully synced
- ⚠️  Repos requiring manual intervention
- ❌ Repos that failed sync
- 📝 Next steps for manual sync
```

**Agent Coordination**: None (file operations)

**Use Cases**:
- New agent distribution
- Agent version updates
- Consistency across repositories
- Agent library maintenance

---

#### Command 12: `/sdk/refresh` - SDK Documentation Update

**File**: `.claude/commands/sdk/refresh.md`

```markdown
---
description: Refresh local Claude SDK documentation from Anthropic sources
allowed-tools:
  - WebFetch
  - WebSearch
  - Write
  - Edit
  - Read
  - Task
max-turns: 15
---

# SDK Documentation Refresh

Update local SDK documentation via claude-sdk-expert.

## Documentation Path
Target: /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/claude-sdk-expert/docs/

## Current Documentation Status
!`ls -lh /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/claude-sdk-expert/docs/*.md | wc -l`
!`cat /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/claude-sdk-expert/docs/REFRESH.md`

## Agent Coordination (@agent-claude-sdk-expert)

**Phase 1: Fetch Latest Docs**
Use WebSearch to find latest Anthropic SDK documentation:
- TypeScript SDK reference
- Python SDK reference
- Slash commands documentation
- Custom tools guide
- Subagents and sessions
- Cost tracking and analytics
- Migration guides

**Phase 2: Convert to Local Format**
- Convert HTML to clean markdown
- Extract code examples
- Preserve syntax highlighting
- Add internal cross-references
- Update INDEX.md navigation

**Phase 3: Validate Updates**
- Compare with existing docs (diff)
- Verify all code examples are valid
- Check for breaking changes
- Update version numbers
- Test documentation completeness

**Phase 4: Update Metadata**
- Update REFRESH.md with timestamp
- Increment documentation version
- Update agent frontmatter if SDK features changed
- Create changelog of documentation updates

## Success Criteria
- [ ] All 17+ documentation files updated
- [ ] Code examples validated
- [ ] INDEX.md reflects new content
- [ ] REFRESH.md timestamp updated
- [ ] No broken internal links
- [ ] Agent can reference new documentation
```

**Agent Coordination**: Orchestrator → claude-sdk-expert (with WebFetch/WebSearch)

**Use Cases**:
- Keeping SDK docs current
- Learning new SDK features
- Updating agent capabilities
- Documentation maintenance

---

### 4.5 Git & Workflow Commands

#### Command 13: `/git/safe-push` - Multi-Branch Safety Checks

**File**: `.claude/commands/git/safe-push.md`

```markdown
---
description: Perform safety checks before pushing to remote (prevent force-push to main)
allowed-tools:
  - Bash(git:*)
  - Read
  - Grep
  - Task
max-turns: 8
---

# Safe Git Push Workflow

Coordinate git-expert and governance-expert for safe push operations.

## Current Branch Status
!`git branch --show-current`
!`git status --short`
!`git log --oneline -5`

## Agent Safety Analysis

**Git Expert** (@agent-git-expert):
- Verify not pushing to main/master directly
- Check for merge conflicts
- Analyze file dependencies (prevent parallel agent conflicts)
- Review commit history (no force-push indicators)
- Validate branch naming convention

**Governance Expert** (@agent-governance-expert):
- Verify pre-commit hooks passed
- Check code review status (if PR exists)
- Validate commit message format
- Ensure tests are passing
- Verify no sensitive data in commits

## Safety Checks

**1. Branch Protection**
!`[ "$(git branch --show-current)" = "main" ] && echo "ERROR: Cannot push directly to main" || echo "Branch OK"`

**2. Uncommitted Changes**
!`git diff --quiet && git diff --cached --quiet && echo "Working tree clean" || echo "WARNING: Uncommitted changes exist"`

**3. Diverged from Remote**
!`git fetch origin && git status -sb | grep -E "ahead|behind" || echo "In sync with remote"`

**4. Pre-Push Quality Gates**
- Run `/qa-all` before pushing
- Verify tests pass
- Check for linting errors

## Push Execution

If all checks pass:
!`git push origin $(git branch --show-current)`

If pushing to main (requires confirmation):
- ❌ BLOCKED: Direct push to main forbidden
- ✅ Create pull request instead: `gh pr create`

## Success Criteria
- [ ] Not pushing to protected branch
- [ ] Working tree clean
- [ ] In sync with remote
- [ ] Quality gates passed
- [ ] Safe to push
```

**Agent Coordination**: Orchestrator → git-expert, governance-expert

**Use Cases**:
- Preventing accidental force-pushes
- Pre-push quality validation
- Branch protection enforcement
- Governance compliance

---

#### Command 14: `/team/build` - Complete Feature Build Coordination

**File**: `.claude/commands/team/build.md`

```markdown
---
description: Coordinate multi-agent team to build complete features from requirements
allowed-tools:
  - Task
  - Bash
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - TodoWrite
argument-hint: <feature-description>
max-turns: 40
---

# Multi-Agent Feature Build Workflow

Coordinate specialized agents with PM coordination to build complete features.

## Feature Request
Feature: $ARGUMENTS

## PM Coordination Setup (@agent-git-expert)

**Pre-Build Analysis**:
- Current compilation status
- Existing modules and file structure
- Potential conflicts
- Work breakdown strategy

## Agent Team Assembly

Coordinate orchestrator to assign optimal agent team:

**Architecture Phase** (@agent-system-architect):
- Design feature architecture
- Identify components and modules
- Define interfaces and contracts
- Technology selection

**Database Phase** (@agent-database-expert, if applicable):
- Schema design
- Migration planning
- Query optimization
- Index strategy

**Implementation Phase** (PM-Coordinated):
- @agent-react-typescript-specialist (frontend features)
- @agent-rust-backend-expert (backend services, Hive)
- @agent-python-ml-expert (ML/AI features)
- PM assigns non-conflicting files to each agent
- PM runs `cargo check` or `npm run build` after each agent

**API Integration Phase** (@agent-api-expert):
- REST/GraphQL endpoint design
- Authentication/authorization
- Rate limiting
- Documentation (OpenAPI)

**Testing Phase** (@agent-stagehand-expert):
- E2E test strategy
- Unit test coverage
- Integration tests
- Test automation

**Security Phase** (@agent-security-expert):
- Security review
- Vulnerability scanning
- Input validation
- Secrets management

**Documentation Phase** (@agent-documentation-expert):
- API documentation
- User guides
- Code comments
- Architecture diagrams

## Quality Verification

After implementation:
- Run `/qa-all` to verify build
- Execute `/team/review` for code review
- Run `/git/safe-push` for pre-commit checks

## Success Metrics
- [ ] Feature architecture designed
- [ ] All components implemented
- [ ] Tests passing
- [ ] Security review passed
- [ ] Documentation complete
- [ ] Code review approved
- [ ] Ready to merge
```

**Agent Coordination**: Orchestrator → PM (git-expert) → system-architect, database-expert, react-typescript-specialist/rust-backend-expert/python-ml-expert, api-expert, stagehand-expert, security-expert, documentation-expert

**Use Cases**:
- Complete feature development
- Multi-component implementations
- Cross-cutting concerns
- Complex requirements

---

#### Command 15: `/project/init` - New Project Initialization

**File**: `.claude/commands/project/init.md`

```markdown
---
description: Initialize new project with best practices and agent setup
allowed-tools:
  - Bash
  - Write
  - Edit
  - Task
argument-hint: <project-type> <project-name>
max-turns: 15
---

# Project Initialization Workflow

Setup new project with optimal agent configuration and tooling.

## Project Details
Type: ${ARGUMENTS%% *}
Name: ${ARGUMENTS#* }

## Supported Project Types
- rust-cli: Rust CLI application
- rust-lib: Rust library
- nextjs: Next.js application (App Router)
- electron: Electron desktop app
- cloudflare-worker: Cloudflare Workers project

## Initialization Workflow

**Phase 1: Project Scaffolding**

Coordinate with appropriate specialist agent:

For Rust projects (@agent-rust-backend-expert):
!`cargo new ${ARGUMENTS#* } --bin`
- Setup Cargo.toml with dependencies
- Configure clippy.toml for strict linting
- Create .cargo/config.toml

For Next.js projects (@agent-nextjs-expert):
!`npx create-next-app@latest ${ARGUMENTS#* } --typescript --app --tailwind --eslint`
- Configure next.config.js
- Setup shadcn/ui (@agent-shadcn-expert)
- Configure TypeScript strict mode

For Electron projects (@agent-electron-specialist):
!`npm create electron-app@latest ${ARGUMENTS#* } -- --template=typescript-webpack`
- Setup main/renderer process structure
- Configure IPC patterns
- Setup build pipeline

For Cloudflare Workers (@agent-cloudflare-expert):
!`npm create cloudflare@latest ${ARGUMENTS#* } -- --template worker-typescript`
- Configure wrangler.toml
- Setup D1 database bindings
- Configure KV namespaces

**Phase 2: Agent Setup**

Create `.claude/` directory structure:
- `.claude/agents/` (copy relevant agents from pattern repo)
- `.claude/commands/` (project-specific commands)
- `.claude/CLAUDE.md` (with @~/.claude/CLAUDE.md import)

**Phase 3: Quality Tooling**

Setup quality tools:
- Git hooks (pre-commit, commit-msg)
- CI/CD configuration (GitHub Actions)
- Testing framework
- Linting/formatting
- Documentation generation

**Phase 4: Documentation**

Create essential docs (@agent-documentation-expert):
- README.md with setup instructions
- ARCHITECTURE.md with design decisions
- CONTRIBUTING.md with development guidelines
- LICENSE file

**Phase 5: Governance**

Setup governance (@agent-governance-expert):
- Branch protection rules
- PR templates
- Code review standards
- Release workflow
- Security policies

## Success Criteria
- [ ] Project scaffolded with correct template
- [ ] Dependencies installed
- [ ] Agent library configured
- [ ] Quality tools setup
- [ ] Documentation complete
- [ ] First commit created
- [ ] CI/CD configured
- [ ] Ready for development
```

**Agent Coordination**: Orchestrator → (rust-backend-expert OR nextjs-expert OR electron-specialist OR cloudflare-expert), documentation-expert, governance-expert

**Use Cases**:
- Starting new projects
- Standardizing project structure
- Onboarding new repositories
- Best practices enforcement

---

## Section 5: Implementation Guide

### 5.1 Command File Organization

**Recommended Directory Structure**:

```
.claude/commands/
├── agent/
│   ├── create.md
│   └── sync.md
├── team/
│   ├── build.md
│   ├── fix.md
│   └── review.md
├── git/
│   └── safe-push.md
├── hive/
│   ├── sign.md
│   ├── release.md
│   └── test-consensus.md
├── web/
│   ├── deploy-check.md
│   ├── db-migrate.md
│   └── email-test.md
├── sdk/
│   └── refresh.md
├── project/
│   └── init.md
└── qa-all.md
```

**Naming Conventions**:
- Use kebab-case for file names (e.g., `deploy-check.md`, not `deployCheck.md`)
- Group related commands in subdirectories (namespace pattern)
- Command path becomes slash command: `.claude/commands/team/build.md` → `/team/build`
- Use descriptive names that indicate purpose

### 5.2 Frontmatter Best Practices

**Essential Fields**:
```yaml
---
description: Clear, concise description (required for /help)
allowed-tools: [List of tools this command needs]
argument-hint: [expected-arg-format] (optional but recommended)
max-turns: 10 (optional, default is unlimited)
---
```

**Tool Restrictions**:
- **Broad access**: `allowed-tools: [Task, Bash, Read, Write, Edit, Grep, Glob]`
- **Restricted access**: `allowed-tools: [Bash(git:*), Read, Grep]` (only git commands)
- **Minimal access**: `allowed-tools: [Read]` (read-only command)

**Max Turns**:
- Simple commands: 5-10 turns
- Complex workflows: 20-40 turns
- Unlimited: Omit field for no limit

### 5.3 Agent Coordination Patterns

**Pattern 1: Single Specialist Agent**
```markdown
Coordinate with @agent-macos-signing-expert to sign and notarize app.

[Detailed workflow...]
```
- Use for domain-specific tasks
- Clear handoff to specialist
- Specialist has all needed context

**Pattern 2: Parallel Analysis**
```markdown
**Phase 1: Diagnosis (Parallel Analysis)**
- @agent-security-expert: Check vulnerabilities
- @agent-code-review-expert: Analyze quality
- @agent-git-expert: Check conflicts

[Synthesize results...]
```
- Multiple agents analyze same artifact
- Results combined into unified report
- Efficient for multi-perspective reviews

**Pattern 3: Sequential Pipeline**
```markdown
**Phase 1: Architecture** (@agent-system-architect)
**Phase 2: Implementation** (@agent-react-typescript-specialist)
**Phase 3: Testing** (@agent-stagehand-expert)
**Phase 4: Documentation** (@agent-documentation-expert)
```
- Each phase depends on previous
- Clear handoffs between agents
- PM coordination prevents conflicts

**Pattern 4: PM-Coordinated Parallel Work**
```markdown
**PM Coordination** (@agent-git-expert):
- Analyzes file dependencies
- Creates conflict-free work breakdown
- Assigns agents to specific files

**Parallel Implementation**:
- Agent 1: src/auth/handler.rs
- Agent 2: src/api/routes.rs
- Agent 3: tests/integration_test.rs

PM runs `cargo check` after each agent completes.
```
- Prevents file conflicts
- Maintains compilation at all times
- Scales to many agents

### 5.4 Bash Execution Patterns

**Pattern 1: Inline Execution with `!` Prefix**
```markdown
## Current Status
!`git status --short`
!`git log --oneline -5`

## Build Check
!`cargo check 2>&1 | tail -20`
```
- Executes immediately when command loads
- Output injected into prompt context
- Use for gathering current state

**Pattern 2: Conditional Execution**
```markdown
!`[ "$(git branch --show-current)" = "main" ] && echo "ERROR: On main branch" || echo "Branch OK"`
```
- Bash conditionals for validation
- Return error/success messages
- Useful for pre-flight checks

**Pattern 3: Multi-Step Workflows**
```markdown
## Step 1: Build
!`npm run build`

## Step 2: Test
!`npm test`

## Step 3: Deploy
!`wrangler deploy`
```
- Sequential steps with clear labels
- Each step builds on previous
- Easy to debug failures

**Pattern 4: Error Handling**
```markdown
!`cargo build --release 2>&1 || echo "Build failed, see errors above"`
!`test -f ./release/Hive.app && echo "App exists" || echo "ERROR: App not found"`
```
- Capture errors with `2>&1`
- Provide fallback messages with `||`
- Makes failures clear

### 5.5 Argument Parsing

**Pattern 1: Single Required Argument**
```markdown
## Agent Name
Target: $ARGUMENTS
```
- `$ARGUMENTS` contains full argument string
- Use when expecting single value

**Pattern 2: Multiple Arguments with Defaults**
```markdown
## Version & Environment
Version: ${ARGUMENTS%% *}
Environment: ${ARGUMENTS#* }
```
- `${ARGUMENTS%% *}`: First word (remove after first space)
- `${ARGUMENTS#* }`: Remaining words (remove first word)
- Supports: `/release v1.2.0 production`

**Pattern 3: Optional Arguments with Fallbacks**
```markdown
## Target Path
Path: ${ARGUMENTS:-./release/Hive.app}
```
- `${ARGUMENTS:-default}`: Use default if no argument
- Supports both: `/hive/sign` and `/hive/sign /custom/path`

**Pattern 4: Flag Detection**
```markdown
## Check for Skip Flag
!`[ "$ARGUMENTS" = "skip-tests" ] && echo "Tests skipped" || npm test`
```
- Parse flags from arguments
- Conditional behavior

### 5.6 Safety and Error Handling

**Pre-Flight Checks**:
```markdown
## Validation
!`test -d /path/to/project && echo "Project exists" || echo "ERROR: Project not found"`
!`which wrangler >/dev/null && echo "Wrangler installed" || echo "ERROR: Install wrangler"`
```
- Verify prerequisites exist
- Fail fast with clear errors

**Destructive Operation Warnings**:
```markdown
## WARNING: Destructive Operation
This will DELETE data. Confirm:
- [ ] Backup created
- [ ] Read documentation
- [ ] Tested on staging

Proceed? (yes/no): $ARGUMENTS
```
- Explicit warnings for dangerous operations
- Require user confirmation
- Provide escape hatch

**Rollback Plans**:
```markdown
## Success Criteria
- [ ] Operation completed
- [ ] Verification passed

## Rollback
If operation fails:
!`git reset --hard HEAD@{1}`
!`wrangler d1 execute db --remote --file=rollback.sql`
```
- Always provide undo path
- Document recovery procedures

### 5.7 Output Formatting

**Checklists for Verification**:
```markdown
## Success Criteria
- [ ] All tests passing
- [ ] Code review completed
- [ ] Documentation updated
- [ ] Safe to deploy
```
- Clear success definition
- Easy to track completion
- Shareable with team

**Status Reports**:
```markdown
## Deployment Status
✅ Build succeeded
✅ Tests passed
⚠️  Dry-run deployment has warnings
❌ Environment variables missing

Next steps: Configure environment variables
```
- Visual indicators (✅, ⚠️ , ❌)
- Clear status communication
- Actionable next steps

**Tabular Summaries**:
```markdown
## Agent Assignments
| Agent | Files | Status |
|-------|-------|--------|
| security-expert | auth/*.rs | ✅ Complete |
| api-expert | routes/*.rs | ⚠️  In Progress |
| test-expert | tests/*.rs | Pending |
```
- Structured information
- Easy to scan
- Clear progress tracking

---

## Section 6: Priority Ranking & Roadmap

### 6.1 Priority 1: Universal High-Value Commands (Immediate)

**Implement First** (Next 24 hours):
1. `/qa-all` - Universal quality checks (all projects)
2. `/team/fix` - Multi-agent bug fixing
3. `/git/safe-push` - Safe push with governance

**Rationale**:
- Used across all three repositories
- Immediate productivity gains
- Prevent common mistakes (broken commits, unsafe pushes)
- Foundation for other commands

**Estimated Time**: 2-3 hours to create and test

### 6.2 Priority 2: Project-Specific Automation (Week 1)

**Hive Commands**:
4. `/hive/sign` - macOS signing automation
5. `/hive/test-consensus` - Consensus validation

**Website Commands**:
6. `/web/deploy-check` - Cloudflare deployment validation
7. `/web/db-migrate` - D1 migration workflow

**Rationale**:
- Address project-specific pain points
- Automate repetitive manual workflows
- Reduce error-prone operations
- Enable faster iteration cycles

**Estimated Time**: 4-5 hours to create and test

### 6.3 Priority 3: Agent Development Workflow (Week 2)

**Pattern Repository Commands**:
8. `/agent/create` - Agent creation wizard
9. `/agent/sync` - Cross-repo agent sync
10. `/sdk/refresh` - SDK documentation update

**Rationale**:
- Standardize agent development
- Maintain consistency across repos
- Keep SDK knowledge current
- Support ongoing agent library expansion

**Estimated Time**: 3-4 hours to create and test

### 6.4 Priority 4: Advanced Coordination (Week 2-3)

**Multi-Agent Commands**:
11. `/team/build` - Complete feature builds
12. `/team/review` - Comprehensive code review
13. `/hive/release` - Full release pipeline

**Rationale**:
- Orchestrate complex multi-agent workflows
- Demonstrate PM coordination patterns
- Handle end-to-end feature delivery
- Production release automation

**Estimated Time**: 6-8 hours to create and test

### 6.5 Priority 5: Project Initialization & Ecosystem (Future)

**Infrastructure Commands**:
14. `/project/init` - New project setup
15. `/web/email-test` - Email system validation

**Rationale**:
- Onboarding new projects
- Testing infrastructure components
- Establishing best practices early
- Future-proofing development

**Estimated Time**: 3-4 hours to create and test

---

## Section 7: Success Metrics & Validation

### 7.1 Command Quality Metrics

**Technical Metrics**:
- **Execution Success Rate**: >95% of command invocations succeed
- **Error Recovery**: Clear error messages with actionable next steps
- **Performance**: Commands complete within expected time (5-40 turns based on max-turns)
- **Tool Coverage**: All necessary tools in allowed-tools (no tool restriction errors)

**User Experience Metrics**:
- **Clarity**: Descriptions are clear and argument hints are helpful
- **Efficiency**: Commands reduce manual steps by 50-90%
- **Safety**: Destructive operations require confirmation, rollback available
- **Documentation**: Each command self-documents its workflow

### 7.2 Validation Workflow

**For Each Command**:
1. **Syntax Validation**: Frontmatter parses correctly, no YAML errors
2. **Tool Availability**: All allowed-tools exist and are accessible
3. **Bash Execution**: All `!` prefixed commands execute successfully
4. **Agent Coordination**: Referenced agents exist and are callable
5. **Argument Handling**: $ARGUMENTS parsed correctly with/without input
6. **Output Verification**: Command produces expected results
7. **Error Handling**: Failures provide clear recovery steps

**Testing Checklist**:
```markdown
- [ ] Command loads without errors
- [ ] Bash commands execute successfully
- [ ] Agent coordination works as designed
- [ ] Arguments parsed correctly
- [ ] Success criteria met
- [ ] Error messages are clear
- [ ] Rollback tested (if applicable)
- [ ] Documentation accurate
```

### 7.3 Adoption Metrics

**Usage Tracking** (First 30 Days):
- Command invocation frequency
- Most/least used commands
- Average completion time
- User satisfaction (qualitative feedback)

**Iteration Plan**:
- Week 1: Deploy Priority 1 commands, gather feedback
- Week 2: Refine based on usage, deploy Priority 2
- Week 3: Expand to Priority 3-4 based on demand
- Month 2: Full command library available

---

## Section 8: Implementation Checklist

### 8.1 Repository Setup

**For claude-pattern**:
- [ ] Create `.claude/commands/` subdirectories (team, agent, git, sdk, project)
- [ ] Implement Priority 1 commands (qa-all, team/fix, git/safe-push)
- [ ] Test commands in isolation
- [ ] Update main CLAUDE.md with command usage guide

**For Hive**:
- [ ] Create `.claude/commands/hive/` directory
- [ ] Implement hive/sign, hive/test-consensus, hive/release
- [ ] Test with actual build/release workflows
- [ ] Document Hive-specific command usage

**For Website**:
- [ ] Create `.claude/commands/web/` directory
- [ ] Implement web/deploy-check, web/db-migrate, web/email-test
- [ ] Test with Cloudflare/D1 integration
- [ ] Document Website-specific workflows

### 8.2 Documentation Requirements

**For Each Command**:
- [ ] Frontmatter complete (description, allowed-tools, argument-hint)
- [ ] Clear workflow sections with headings
- [ ] Bash commands properly prefixed with `!`
- [ ] Agent coordination explicitly stated
- [ ] Success criteria defined
- [ ] Error handling documented

**Master Documentation**:
- [ ] Update `.claude/CLAUDE.md` with `/help` command list
- [ ] Create command usage guide with examples
- [ ] Document argument patterns for each command
- [ ] Add troubleshooting section

### 8.3 Validation & Testing

**Per-Command Testing**:
- [ ] Run command with valid arguments
- [ ] Run command with invalid arguments
- [ ] Run command with missing arguments
- [ ] Test in different project contexts
- [ ] Verify agent coordination works
- [ ] Confirm output format correct

**Integration Testing**:
- [ ] Test command sequences (e.g., /qa-all → /git/safe-push)
- [ ] Verify cross-command compatibility
- [ ] Test in fresh repository clones
- [ ] Validate with different user permissions

### 8.4 Rollout Plan

**Phase 1: Priority 1 Commands (Days 1-2)**
- Implement qa-all, team/fix, git/safe-push
- Test in claude-pattern repository
- Gather initial feedback
- Refine based on usage

**Phase 2: Project-Specific Commands (Days 3-5)**
- Implement Hive commands (sign, test-consensus)
- Implement Website commands (deploy-check, db-migrate)
- Test in respective repositories
- Document project-specific workflows

**Phase 3: Agent Development Commands (Days 6-8)**
- Implement agent/create, agent/sync, sdk/refresh
- Test agent creation and synchronization
- Validate SDK documentation refresh
- Update agent library documentation

**Phase 4: Advanced Coordination (Days 9-14)**
- Implement team/build, team/review, hive/release
- Test complex multi-agent workflows
- Validate PM coordination patterns
- Document best practices

**Phase 5: Ecosystem Commands (Future)**
- Implement project/init, web/email-test
- Test new project setup
- Validate email integration testing
- Complete command library

---

## Section 9: Future Enhancements

### 9.1 Command Composition

**Idea**: Allow commands to invoke other commands
```markdown
## Run Quality Checks
Execute /qa-all before deployment

## Deploy if Passing
If qa-all succeeds, execute /web/deploy-check
```

**Benefits**:
- Reduce duplication
- Create workflow pipelines
- Compose complex behaviors from simple commands

### 9.2 Interactive Commands

**Idea**: Prompt for user input during execution
```markdown
## Deployment Environment
Select environment:
1. Development
2. Staging
3. Production

Environment: $PROMPT
```

**Benefits**:
- User-guided workflows
- Safer destructive operations
- Context-aware execution

### 9.3 Command Templates

**Idea**: Parameterized command generation
```markdown
Generate command from template:
- Template: git-workflow
- Parameters: {branch_prefix: "feature/", require_review: true}
```

**Benefits**:
- Rapid command creation
- Consistent patterns
- Team-specific customization

### 9.4 Command Analytics

**Idea**: Track command usage and performance
```json
{
  "command": "/qa-all",
  "invocations": 47,
  "avg_completion_time": "12s",
  "success_rate": 0.96,
  "most_common_errors": ["lint_failure", "test_timeout"]
}
```

**Benefits**:
- Identify optimization opportunities
- Understand usage patterns
- Prioritize improvements

### 9.5 AI-Generated Commands

**Idea**: Use agent to generate custom commands on-demand
```
User: "Create a command to deploy Hive with full release pipeline"
Assistant: Generates /hive/deploy.md based on templates and context
```

**Benefits**:
- Rapid prototyping
- User-specific workflows
- Learning from examples

---

## Section 10: Conclusion

### Key Findings

1. **Slash Commands are Powerful**: SDK supports sophisticated workflows with frontmatter, bash execution, and tool restrictions
2. **Multi-Agent Coordination is Essential**: Most valuable commands orchestrate multiple specialist agents
3. **Project-Specific Automation Matters**: Hive/Website have unique workflows that benefit from custom commands
4. **Safety and Governance**: Commands must include pre-flight checks, rollback plans, and error handling
5. **Incremental Rollout**: Start with universal high-value commands, expand to project-specific

### Expected Impact

**Productivity Gains**:
- **50-90% reduction** in repetitive manual workflows
- **2-hour Hive releases → 20-minute automated** releases
- **Pre-commit quality checks** prevent broken builds
- **Safe push operations** prevent force-push accidents

**Quality Improvements**:
- **Consistent agent coordination** patterns
- **Standardized workflows** across repositories
- **Comprehensive code reviews** with multi-agent perspectives
- **Governance enforcement** via automated checks

**Developer Experience**:
- **One command** triggers complex multi-agent workflows
- **Self-documenting** commands with clear success criteria
- **Safe operations** with rollback plans
- **Cross-repository consistency** via agent sync

### Next Steps

1. **Implement Priority 1 Commands** (qa-all, team/fix, git/safe-push)
2. **Test in Real Workflows** (Hive release, Website deployment)
3. **Gather Feedback** from actual usage
4. **Iterate and Expand** based on adoption metrics
5. **Document Best Practices** for command development

### Call to Action

**For User**:
- Review proposed commands and prioritize based on immediate needs
- Provide feedback on command designs
- Test Priority 1 commands in daily workflows
- Suggest additional automation opportunities

**For Orchestrator**:
- Create command files in appropriate repositories
- Coordinate agent testing and validation
- Monitor command usage and performance
- Iterate based on real-world feedback

---

**End of Research Synthesis**

Generated by: Task Orchestrator + claude-sdk-expert
Date: 2025-10-08
Total Agent Coordination: 2 agents (orchestrator, claude-sdk-expert)
Documentation References: 17 SDK docs, 31 agent definitions, 3 repository workflows
