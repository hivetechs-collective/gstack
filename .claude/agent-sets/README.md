# Agent Sets - Curated Collections

**Purpose**: Pre-defined agent groups for common workflows to avoid token bloat.

## Available Sets

### Core Development Sets

| Set Name | Agents | Est. Tokens | Use Case |
|----------|--------|-------------|----------|
| **core.json** | 7 | ~4k | Essential agents for any project |
| **electron.json** | 8 | ~5k | Electron desktop development |
| **rust.json** | 6 | ~4k | Rust backend development |
| **web-fullstack.json** | 10 | ~6k | Next.js/React web apps |
| **database.json** | 5 | ~3k | Database design and optimization |

### Specialized Sets

| Set Name | Agents | Est. Tokens | Use Case |
|----------|--------|-------------|----------|
| **release-pipeline.json** | 5 | ~3-4k | Release automation and distribution |
| **hive-core.json** | 12 | ~9k | Hive Consensus (Electron + Rust + Release) |
| **cloud.json** | 6 | ~4k | Cloud infrastructure (AWS, GCP, Azure) |
| **observability.json** | 4 | ~3k | Monitoring, logging, tracing |

## Usage

### Option 1: Copy Agent List to Project Config

```bash
# View agents in a set
cat agent-sets/hive-core.json | jq '.agents'

# Copy to clipboard (macOS)
cat agent-sets/hive-core.json | jq '.agents' | pbcopy
```

Then paste into your project's `.claude/settings.local.json`:

```json
{
  "agentDescriptions": {
    "enabled": [
      // Paste agent list here
      "orchestrator",
      "electron-specialist",
      "rust-backend-specialist"
      // ...
    ]
  }
}
```

### Option 2: Create Custom Set

```bash
# Create your own set
cat > agent-sets/custom/my-workflow.json <<'EOF'
{
  "name": "my-workflow",
  "description": "My custom workflow agents",
  "agents": [
    "agent-1",
    "agent-2",
    "agent-3"
  ],
  "estimatedTokens": 3000
}
EOF
```

### Option 3: Merge Multiple Sets

```bash
# Combine electron + rust for hybrid project
jq -s '.[0].agents + .[1].agents | unique' \
  agent-sets/electron.json \
  agent-sets/rust.json
```

## Set Descriptions

### core.json
**Purpose**: Essential agents for ANY project
**Includes**: orchestrator, system-architect, security-expert, code-review-expert, documentation-expert, git-expert, mcp-expert

**When to use**: Starting a new project, unsure what you need

### electron.json
**Purpose**: Electron desktop application development
**Includes**: electron-specialist, nodejs-specialist, react-typescript-specialist, database-expert, security-expert, api-expert, documentation-expert, git-expert

**When to use**: Building Electron apps, IPC patterns, packaging/distribution

### rust.json
**Purpose**: Rust backend services and systems programming
**Includes**: rust-backend-specialist, system-architect, performance-testing-specialist, database-expert, security-expert, code-review-expert

**When to use**: Rust APIs, WebSocket servers, async Tokio patterns

### release-pipeline.json
**Purpose**: Automated build, signing, and distribution
**Includes**: release-orchestrator, macos-signing-expert, homebrew-publisher, git-expert, documentation-expert

**When to use**: Setting up CI/CD, code signing, package distribution

### hive-core.json
**Purpose**: Hive Consensus development (Electron + Rust + Release)
**Includes**: All of electron.json + rust.json + release-pipeline.json (deduplicated)

**When to use**: Working on Hive project specifically

### web-fullstack.json
**Purpose**: Next.js/React full-stack web applications
**Includes**: nextjs-expert, react-typescript-specialist, nodejs-specialist, database-expert, api-expert, docker-advanced-specialist, observability-specialist

**When to use**: Building web apps with Next.js, React, TypeScript

### database.json
**Purpose**: Database design, optimization, and administration
**Includes**: database-expert, mongodb-specialist, redis-specialist, vector-database-specialist, snowflake-specialist

**When to use**: Database schema design, query optimization, data modeling

### cloud.json
**Purpose**: Cloud infrastructure and DevOps
**Includes**: aws-specialist, gcp-specialist, azure-specialist, cloudflare-expert, terraform-specialist, kubernetes-specialist

**When to use**: Infrastructure as Code, cloud deployments, containerization

### observability.json
**Purpose**: Monitoring, logging, and tracing
**Includes**: observability-specialist, elasticsearch-specialist, kafka-specialist, docker-advanced-specialist

**When to use**: Setting up monitoring, log aggregation, distributed tracing

## Token Budget

**Stay under 15k tokens** (~12 agents max per project)

| Agents | Tokens | Status |
|--------|--------|--------|
| 0-7    | 0-4k   | ✅ Optimal |
| 8-12   | 5-9k   | ✅ Good |
| 13-15  | 10-12k | ⚠️ High |
| 16+    | 13k+   | 🚫 Token bloat |

## Tips

1. **Start small**: Use core.json, add specialists as needed
2. **Remove unused**: If you haven't used an agent in a week, remove it
3. **Context-aware**: Enable agents only when working on that tech
4. **Session-specific**: Different agent sets for different work sessions
5. **Monitor warnings**: If you see token warnings, reduce agent count

## Custom Sets

Create your own sets in `agent-sets/custom/`:

```json
{
  "name": "my-custom-workflow",
  "description": "Description of workflow",
  "agents": [
    "agent-1",
    "agent-2"
  ],
  "estimatedTokens": 2000,
  "notes": "When to use this set"
}
```

## Maintenance

- **Review monthly**: Which agents did you actually use?
- **Update sets**: Add/remove based on usage
- **Sync pattern repo**: Pull latest agent updates
- **Share sets**: Commit useful sets to pattern repo
