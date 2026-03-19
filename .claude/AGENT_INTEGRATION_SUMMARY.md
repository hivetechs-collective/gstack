# Hive Consensus Agent Integration Summary

**Created**: 2025-10-12
**Purpose**: Document all specialized agents for Hive Consensus development and releases

---

## Agent Overview

Hive Consensus uses 9 specialized agents for development, building, releasing, and skills management:

| Agent | Color | Specialization |
|-------|-------|----------------|
| consensus-analyzer | GREEN | 4-stage consensus analysis and optimization |
| memory-optimizer | BLUE | SQLite Memory Service performance tuning |
| electron-specialist | YELLOW | Electron Forge, IPC, ProcessManager integration |
| rust-backend-expert | ORANGE | Rust WebSocket, Tokio async, OpenRouter API |
| cli-tool-manager | MAGENTA | 8 AI CLI tools management and recommendations |
| macos-signing-expert | BLUE | Apple code signing, notarization, entitlements |
| release-orchestrator | PURPLE | Multi-phase release pipeline coordination |
| homebrew-publisher | GREEN | Homebrew cask automation and publishing |
| skills-expert | CYAN | Claude Skills creation, compliance, and optimization |

---

## Release Management

### Primary Agent: release-orchestrator

**Configuration**: `.claude/agents/hive/release-orchestrator.md`

**Purpose**: Coordinate the complete release pipeline with automated quality gates

### Standard Release Command

```bash
# User says any of:
"@release-orchestrator release the next version"
"release v1.8.538"
"build and publish to Homebrew"

# Agent executes:
cd /Users/veronelazio/Developer/Private/hive/electron-poc
./scripts/release-with-quality-gates.sh <version>
```

### Quality Gates: 7 Mandatory Checkpoints

The release-orchestrator enforces these gates automatically:

| Gate | Purpose | Duration | Script |
|------|---------|----------|--------|
| 1 | Pre-Build Config Check | 10s | `verify-forge-config.js` |
| 2 | Clean Environment | 30s | Built into pipeline |
| 3 | Build Execution | 3-5min | `build-production-dmg.js` |
| 4 | Post-Build Signing | 10s | `verify-signing-after-build.sh` |
| 5 | Deep Signing & Notarization | 10-15min | `sign-notarize-macos.sh` |
| 6 | Pre-Release Verification | 30s | `verify-signing-before-release.sh` |
| 7 | SHA256 & Metadata | 10s | Built into pipeline |

**Total Time**: ~20-25 minutes per release

### Agent Coordination During Release

```
release-orchestrator (PURPLE - Primary Coordinator)
         |
         ├─ Gate 1, 4, 5, 6: macos-signing-expert (BLUE)
         |  - Apple code signing expertise
         |  - Notarization debugging
         |  - Entitlements configuration
         |
         ├─ Gate 3 (if fails): electron-specialist (YELLOW)
         |  - Build debugging
         |  - Electron Forge configuration
         |  - Webpack optimization
         |
         └─ After Gate 7: homebrew-publisher (GREEN)
            - Homebrew cask updates
            - GitHub release creation
            - Installation testing
```

### Key Benefits

- ✅ **No manual steps**: Just ask for a release
- ✅ **No skipping gates**: All verification mandatory
- ✅ **Unsigned builds impossible**: 3 independent verification steps
- ✅ **Expert coordination**: Orchestrator delegates to specialists
- ✅ **Intelligent recovery**: Stops at failures, suggests fixes

### User Experience

**Before** (Manual Process):
1. User runs build script manually
2. User remembers to verify signing
3. User manually signs and notarizes
4. User manually updates Homebrew cask
5. User manually computes SHA256
6. User manually creates GitHub release
7. **Risk**: Easy to skip steps or make mistakes

**After** (Orchestrated Process):
```
User: "@release-orchestrator release the next version"

Orchestrator:
"I'll execute the quality gates release pipeline for v1.8.538

🚀 Starting release pipeline...
🔐 Gate 1: Pre-Build Configuration Check... ✅ PASSED
🧹 Gate 2: Clean Environment Check... ✅ PASSED
🏗️ Gate 3: Build Execution (17 phases)... ✅ PASSED
🔐 Gate 4: Post-Build Signing Verification... ✅ PASSED
🔐 Gate 5: Deep Signing and Notarization... ✅ PASSED
🔐 Gate 6: Pre-Release Comprehensive Verification... ✅ PASSED
🔢 Gate 7: SHA256 Computation and Metadata... ✅ PASSED

✅ All 7 quality gates passed!

📦 Coordinating with @homebrew-publisher to complete release...
✅ Homebrew cask updated
✅ GitHub release created
✅ Installation tested

🎉 Release v1.8.538 complete!"
```

**Result**: Fully automated, verified, safe release in ~20-25 minutes

---

## Development Agents

### consensus-analyzer (GREEN)

**Configuration**: `.claude/agents/hive/consensus-analyzer.md`

**Use Cases**:
- Analyzing 4-stage consensus results (Generator → Refiner → Validator → Curator)
- Evaluating consensus quality and identifying missing perspectives
- Suggesting improvements to consensus prompts
- Integrating with Memory Service for historical context

**Example**:
```
"@consensus-analyzer review these consensus results and suggest improvements"
```

### memory-optimizer (BLUE)

**Configuration**: `.claude/agents/hive/memory-optimizer.md`

**Use Cases**:
- Optimizing SQLite Memory Service queries
- Designing efficient indexes for memory retrieval
- Tuning database performance parameters
- Analyzing concurrent memory access patterns from 8 CLI tools

**Example**:
```
"@memory-optimizer analyze slow queries and suggest index improvements"
```

### electron-specialist (YELLOW)

**Configuration**: `.claude/agents/hive/electron-specialist.md`

**Use Cases**:
- Electron Forge configuration and debugging
- Secure IPC communication patterns
- ProcessManager and PortManager integration
- Zero-fallback port philosophy (no hardcoded ports)

**Example**:
```
"@electron-specialist design secure IPC pattern for consensus progress updates"
```

### rust-backend-expert (ORANGE)

**Configuration**: `.claude/agents/hive/rust-backend-expert.md`

**Use Cases**:
- Rust WebSocket backend implementation
- Tokio async patterns for consensus engine
- OpenRouter API integration for AI models
- WebSocket communication with Electron frontend

**Example**:
```
"@rust-backend-expert optimize this Tokio async code for consensus streaming"
```

### cli-tool-manager (MAGENTA)

**Configuration**: `.claude/agents/hive/cli-tool-manager.md`

**Use Cases**:
- Managing 8 integrated AI CLI tools (Claude, Gemini, Grok, DeepSeek, Cursor, ChatGPT, +2 custom)
- Recommending optimal tool for each task type
- Integrating tools with Memory-as-a-Service
- Tracking CLI tool launches and analytics

**Example**:
```
"@cli-tool-manager which tool should I use for code generation vs analysis?"
```

---

## Signing & Publishing Agents

### macos-signing-expert (BLUE)

**Configuration**: `.claude/agents/hive/macos-signing-expert.md`

**Expertise**:
- Hive's 239-line `sign-notarize-macos.sh` script
- Apple code signing with Developer ID
- Notarization submission and polling
- DMG creation and signing
- Entitlements configuration (`scripts/entitlements.plist`)
- Embedded binary signing (node, ttyd, git-bundle)
- CI/CD keychain management
- Debugging notarization failures with JSON logs
- Stapling verification and Gatekeeper assessment

**Use Cases**:
- Gates 1, 4, 5, 6 during release
- Debugging signing issues
- Configuring entitlements
- Troubleshooting notarization

**Example**:
```
"@macos-signing-expert why is notarization failing for this build?"
```

### homebrew-publisher (GREEN)

**Configuration**: `.claude/agents/hive/homebrew-publisher.md`

**Expertise**:
- Managing `~/Developer/Private/hive/homebrew-tap/` repository
- Updating `Casks/hive-consensus.rb` with version and SHA256
- Automating cask updates via GitHub Actions
- SHA256 computation timing (critical: after stapling, not before)
- Homebrew cask audit and style validation
- GitHub Release integration and CDN propagation
- Troubleshooting SHA256 mismatches and installation failures

**Use Cases**:
- After Gate 7: Homebrew publication
- Updating Homebrew cask
- Creating GitHub releases
- Testing local installation

**Example**:
```
"@homebrew-publisher update cask for v1.8.538 with SHA256 abc123..."
```

---

## Skills Management

### skills-expert (CYAN)

**Configuration**: `.claude/agents/research-planning/skills-expert.md`

**Expertise**:
- Claude Skills creation and authoring from scratch
- Compliance verification against official Anthropic specifications
- Performance optimization through progressive disclosure patterns
- Description field best practices with activation triggers
- Tool restrictions and security auditing
- Skills migration and version management
- Progressive disclosure implementation (3-tier loading)
- API integration patterns for Skills

**Knowledge Base**:
- Official Anthropic documentation (8 sources in `docs/official/`)
- Local implementation analysis (4 reports in `docs/implementation/`)
- Monthly refresh process documented in `REFRESH.md`
- Complete inventory of 39 active skills (24 Hive + 15 Universal)

**Use Cases**:
- Creating new skills from workflows or requirements
- Auditing existing skills for compliance with Anthropic specs
- Optimizing skill performance with progressive disclosure
- Fixing YAML frontmatter or description issues
- Providing examples from official Anthropic repository
- Updating skills knowledge from latest documentation
- Generating compliance and quality reports

**Example Usage**:
```
@skills-expert create a new skill for API testing
@skills-expert audit our skills for compliance with latest specs
@skills-expert optimize the docker-best-practices skill for token efficiency
@skills-expert how do I write a good description field?
@skills-expert update knowledge from latest Anthropic documentation
```

**Knowledge Refresh Schedule**:
- **Frequency**: Monthly (every 20th)
- **Last Updated**: 2025-10-20
- **Next Refresh**: 2025-11-20
- **Process**: Documented in `.claude/agents/research-planning/skills-expert/REFRESH.md`

**Quality Standards**:
Every skill created or audited by skills-expert must have:
- ✅ YAML frontmatter with `name` and `description`
- ✅ Description including "when to use" triggers
- ✅ `allowed-tools` field (security best practice)
- ✅ Version field for tracking changes
- ✅ Concise SKILL.md (<500 lines preferred)
- ✅ Supporting files for detailed content
- ✅ No hardcoded secrets
- ✅ Tested activation with sample prompts

**Current Skills Inventory** (All Production-Ready):

**Universal Skills (15)**:
1. api-design - REST and GraphQL API design patterns
2. ci-pipeline-patterns - GitHub Actions and CI/CD workflows
3. code-review-standards - Security, performance, quality review
4. database-design - Schema design and query optimization
5. deployment-strategies - Blue-green, canary deployments
6. docker-best-practices - Container optimization and security
7. documentation-templates - README, API docs, architecture
8. error-handling - Robust error recovery patterns
9. git-best-practices - Semantic commits, branching strategies
10. incident-response - Postmortem templates and workflows
11. microservices-patterns - Service discovery, circuit breakers
12. monitoring-observability - Distributed system monitoring
13. performance-profiling - Performance optimization techniques
14. security-fundamentals - Authentication, authorization, encryption
15. testing-patterns - Unit, integration, E2E testing strategies

**Hive-Specific Skills (24)** (Electron + TypeScript + PTY + Python):

**Electron Desktop App (5 skills)**:
1. hive-electron-typescript - IPC patterns, main/renderer, TypeScript best practices
2. hive-pty-terminals - node-pty, xterm.js, terminal lifecycle, AI CLI integration
3. hive-memory-service-api - Express API, IPC database access, WebSocket streaming
4. hive-ai-cli-integration - 8+ AI CLI tools, authentication, installation, tracking
5. hive-python-bundling - Embedded Python runtime, package management, script execution

**AI & OpenRouter (2 skills)**:
6. hive-openrouter-integration - 323+ models, streaming, cost tracking, rate limiting
7. hive-enterprise-hooks - Event-driven workflows, compliance, security scanning

**Existing Hive Skills (18 skills)**:
8. hive-agent-ecosystem - 31+ specialized agents knowledge
9. hive-architecture-knowledge - System architecture understanding
10. hive-binary-bundling - Embedded binary management
11. hive-cli-tools-integration - 8 AI CLI tools integration
12. hive-consensus-engine - 4-stage consensus pipeline
13. hive-crash-debugger - Automated crash log analysis
14. hive-documentation-standards - Hive docs patterns
15. hive-git-workflow - Hive commit conventions
16. hive-ipc-patterns - Electron IPC best practices
17. hive-memory-service - SQLite memory optimization
18. hive-performance-benchmarks - Performance metrics
19. hive-python-runtime - Python runtime bundling
20. hive-qa-checklist - Quality assurance checklists
21. hive-release-docs - Release documentation generation
22. hive-release-verification - 11-gate quality verification
23. hive-security-audit - Security audit checklists
24. hive-state-management - Redux patterns for Hive
25. hive-testing-strategy - Comprehensive testing strategy

**Integration with Other Agents**:
- Works with **documentation-expert** for creating skill documentation
- Works with **security-expert** for auditing skill security
- Works with **code-review-expert** for reviewing skill code/scripts
- Works with **system-architect** for designing skill composition patterns
- Works with **claude-sdk-expert** for API integration patterns

---

## Documentation

### User Documentation

- **How to Release**: `electron-poc/HOW_TO_RELEASE.md`
  - Simple instructions for users
  - What to expect during a release
  - Troubleshooting common issues

- **Quality Gates Overview**: `electron-poc/docs/RELEASE_QUALITY_GATES.md`
  - Technical details of each gate
  - Verification scripts explained
  - Design rationale

- **Quick Start**: `electron-poc/QUICK_START_QUALITY_GATES.md`
  - Quick reference for developers
  - One-page summary of the process

### Agent Documentation

Each agent has a comprehensive configuration file:

```
.claude/agents/hive/
├── consensus-analyzer.md
├── memory-optimizer.md
├── electron-specialist.md
├── rust-backend-expert.md
├── cli-tool-manager.md
├── macos-signing-expert.md
├── release-orchestrator.md
└── homebrew-publisher.md
```

These files include:
- Specialization and expertise
- Use cases and examples
- Coordination with other agents
- Documentation references

---

## Integration with Claude Code

### Status Line

Configuration: `.claude/statusline.sh`

Shows:
- Current directory and git branch
- Model (Sonnet 4.5) and version
- Context remaining with color-coded progress
- Token usage and burn rate
- Session time and cost tracking

### Settings

Configuration: `.claude/settings.local.json`

```json
{
  "statusLine": {
    "type": "command",
    "command": ".claude/statusline.sh",
    "padding": 0
  }
}
```

---

## Agent Invocation Patterns

### Direct Invocation

Use the `@agent-name` pattern to invoke a specific agent:

```
@release-orchestrator release v1.8.538
@macos-signing-expert debug notarization failure
@homebrew-publisher update cask with new SHA256
@consensus-analyzer evaluate these results
@memory-optimizer suggest index improvements
@skills-expert audit our skills for compliance
@skills-expert create a new skill for API testing
```

### Contextual Invocation

The orchestrator will automatically coordinate with other agents:

```
User: "release the next version"
Orchestrator: [Automatically coordinates with @macos-signing-expert and @homebrew-publisher]
```

### Multi-Agent Coordination

For complex tasks, the orchestrator manages multiple agents:

```
User: "debug why the build is unsigned"

Orchestrator coordinates:
1. @electron-specialist checks Electron Forge config
2. @macos-signing-expert checks signing certificates
3. @macos-signing-expert verifies codesign output
4. Reports integrated diagnosis
```

---

## Benefits of Agent System

### Before Agents

- ❌ Manual process prone to errors
- ❌ Easy to skip verification steps
- ❌ Inconsistent releases
- ❌ Long debugging cycles
- ❌ Tribal knowledge not documented

### After Agents

- ✅ Fully automated with verification
- ✅ Impossible to skip safety gates
- ✅ Consistent, repeatable releases
- ✅ Intelligent error recovery
- ✅ Expert knowledge embedded in agents
- ✅ Skills management with compliance verification

### Metrics

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| **Unsigned Builds** | Frequent | Zero | 100% prevention |
| **Manual Steps** | ~15 | 1 (invoke agent) | 93% reduction |
| **Release Time** | 60+ min | 20-25 min | 58% faster |
| **Failed Releases** | High | Near zero | Major improvement |
| **Developer Confidence** | Low | High | Qualitative |
| **Skills Compliance** | Unknown | 100% verified | Full compliance |

---

## Future Enhancements

### Planned Agent Additions

1. **performance-analyzer** (CYAN)
   - Analyze runtime performance
   - Suggest optimizations
   - Benchmark comparisons

2. **database-migrator** (ORANGE)
   - Manage SQLite schema migrations
   - Safe database upgrades
   - Rollback strategies

3. **integration-tester** (RED)
   - End-to-end testing
   - Cross-platform verification
   - Regression detection

### Planned Improvements

- **Parallel gate execution**: Where safe, run gates concurrently
- **Progressive rollout**: Canary releases with gradual rollout
- **Auto-rollback**: Detect critical bugs and auto-revert
- **Release analytics**: Track metrics across releases

---

## Lessons Learned

### What Works Well

1. **Quality Gates**: Preventing unsigned builds saved countless hours
2. **Agent Coordination**: Orchestrator + specialists > single monolithic agent
3. **User Experience**: One-command releases are delightful
4. **Documentation**: Comprehensive agent docs enable consistency

### What We Improved

1. **SHA256 Timing**: Moved computation to AFTER stapling (was causing mismatches)
2. **Gate 4 Addition**: Catches unsigned builds immediately after build
3. **Recovery Process**: Clear error messages with fix suggestions
4. **Progress Reporting**: Detailed updates at each gate

### Best Practices

1. **Never skip gates**: Every gate caught real issues
2. **Always restart from Gate 1**: Don't try to resume mid-pipeline
3. **Coordinate with experts**: Don't try to debug signing alone
4. **Trust the process**: 20-25 minutes is time well spent

---

## References

### Primary Documentation

- **Release Process**: `electron-poc/HOW_TO_RELEASE.md`
- **Quality Gates**: `electron-poc/docs/RELEASE_QUALITY_GATES.md`
- **Architecture**: `electron-poc/MASTER_ARCHITECTURE_DESKTOP.md`

### Agent Configuration

- **All Agents**: `.claude/agents/hive/*.md`
- **Release Orchestrator**: `.claude/agents/hive/release-orchestrator.md`

### Scripts

- **Quality Gates Pipeline**: `scripts/release-with-quality-gates.sh`
- **Build**: `scripts/build-production-dmg.js`
- **Signing**: `scripts/sign-notarize-macos.sh`
- **Verification**: `scripts/verify-signing-*.sh`

---

**Last Updated**: 2025-10-20
**Version**: 1.1.0
**Status**: Production-ready
**Total Agents**: 9 (8 Hive development + 1 skills management)
