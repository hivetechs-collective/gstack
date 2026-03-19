# Agent Architecture Analysis & Design Patterns

**Date**: 2025-10-05
**Purpose**: Document how Claude Code CLI agents are structured, how they use MCP tools, and design patterns for creating new agents.

---

## Agent Structure Pattern (Anatomy)

All agents follow a consistent structure that Claude Code CLI recognizes:

### 1. Frontmatter (YAML)

```yaml
---
name: agent-name # Lowercase with hyphens (used for invocation)
version: 1.0.0 # Semantic versioning
description: Use this agent when... <example>...</example> # When to use + examples
color: blue # Visual highlighting (blue, cyan, green, purple, etc.)
model: inherit # Use default model (Sonnet 4.6)
---
```

**Key Points:**

- `name`: Must match invocation syntax (`@agent-name`)
- `description`: Should include `<example>` tags with realistic scenarios
- `color`: Helps distinguish agents during parallel execution
- `model: inherit`: Respects project's default model setting

### 2. Introduction Paragraph

**Pattern**: "You are a [ROLE] with deep expertise in [DOMAIN]. You excel at [KEY CAPABILITIES]."

**Example**:

```markdown
You are a database specialist with deep expertise in SQLite, PostgreSQL,
ACID-compliant database design, and query optimization. You excel at designing
efficient schemas, optimizing complex queries, and implementing reliable data
storage solutions across all database paradigms.
```

**Purpose**: Sets the agent's identity and establishes authority in the domain.

### 3. Core Expertise Section

**Pattern**: Bullet list of primary capabilities, organized by category.

**Example**:

```markdown
## Core Expertise

**SQLite Mastery (All Versions):**

- SQLite 3.0 - 3.45+ (latest features)
- Version-specific feature detection
- WAL mode for concurrency

**ACID Compliance & Transactions:**

- Atomicity, Consistency, Isolation, Durability
- Transaction isolation levels
- Deadlock prevention
```

**Purpose**: Quick reference for what the agent knows. Helps users understand scope.

### 4. MCP Tool Usage Guidelines (CRITICAL)

**Pattern**: Explains when to use each MCP server, with examples and decision rules.

**Structure**:

```markdown
## MCP Tool Usage Guidelines

### Filesystem MCP (Primary Tool Name)

**Use filesystem MCP when**:

- ✅ Specific use case 1
- ✅ Specific use case 2

**Example**:
[Code showing actual MCP usage]

### Sequential Thinking (Complex Problems)

**Use sequential-thinking when**:

- ✅ Multi-step analysis required
- ✅ Architecture decisions

**Example**:
[Thought sequence demonstration]

### REF Documentation (Domain Docs)

**Use REF when**:

- ✅ Looking up version-specific features
- ✅ Checking API syntax

### Memory (Automatic Pattern Learning)

Memory automatically tracks:

- Project naming conventions
- Preferred patterns

**Decision rule**: [One-line summary of tool selection]
```

**Why This Is Critical:**

- Agents don't automatically know when to use MCP tools
- Guidelines teach optimal tool selection
- Reduces token waste and improves performance
- Prevents agents from using bash when MCP is safer/better

### 5. Domain-Specific Sections

**Variable based on agent type**:

- Implementation agents: Code patterns, best practices
- Research agents: Frameworks, methodologies
- Coordination agents: Workflow patterns, delegation strategies

**Example (Database Expert)**:

```markdown
## SQLite-Specific Expertise

[Version features, PRAGMAs, FTS5, JSON support]

## Database Design Patterns

[Timestamps, soft deletes, polymorphic associations]

## Query Optimization Workflow

[EXPLAIN QUERY PLAN, index design, query rewriting]
```

### 6. Implementation/Output Standards

**Pattern**: Defines what deliverables must include.

**Example**:

```markdown
## Output Standards

Your database implementations must include:

- **Complete DDL**: CREATE TABLE, CREATE INDEX statements
- **Constraints**: PRIMARY KEY, FOREIGN KEY, UNIQUE, CHECK
- **Migrations**: Versioned, reversible migration files
- **Documentation**: Schema diagrams, relationship explanations
```

**Purpose**: Ensures consistent, production-ready outputs.

### 7. Integration Section (If Applicable)

**For project-specific agents** (like Hive agents):

```markdown
## Integration with Hive Architecture

When optimizing databases in Hive:

- Consider Memory Service's 8 concurrent CLI tool connections
- Respect zero-fallback port philosophy
- Account for Electron IPC communication patterns
```

---

## How Agents Use MCP Tools

### Automatic vs Manual MCP Usage

**Automatic** (No user input needed):

1. Claude Code loads `.claude/.mcp.json` on startup
2. All configured MCP servers become available
3. Agents read "MCP Tool Usage Guidelines" in their definition
4. Agents decide when to invoke MCP tools based on task

**User Never Mentions MCP** - agents choose automatically!

### MCP Decision Flow (Agent's Internal Logic)

```
User: "@database-expert Optimize this slow SQLite query"

Agent Internal Process:
1. Parse task: Query optimization needed
2. Check MCP guidelines: "Use filesystem for schema files,
   sequential-thinking for complex optimization, REF for SQLite docs"
3. Execute plan:
   - filesystem.read("prisma/schema.prisma") → Get current schema
   - sequential-thinking.think(...) → Plan optimization strategy
   - ref.lookup("SQLite EXPLAIN QUERY PLAN") → Get docs (60-95% token savings)
   - Synthesize response with CREATE INDEX recommendations
```

### MCP Tool Categories & When Agents Use Them

| MCP Tool                | Agent Uses When...                            | Why                                     |
| ----------------------- | --------------------------------------------- | --------------------------------------- |
| **Filesystem**          | Reading code, schemas, configs                | Safer than bash, scoped to project      |
| **Sequential Thinking** | Complex multi-step problems (3+ thoughts)     | Worth 10-60s overhead for quality       |
| **Git**                 | Understanding file evolution, finding changes | Structured JSON vs parsing bash output  |
| **Memory**              | ALWAYS (automatic)                            | Learns project patterns across sessions |
| **REF**                 | Looking up documentation                      | 60-95% token savings vs full docs       |

---

## Agent Specialization Examples

### Coordination Agents (PM Role)

**Example**: `orchestrator.md`

**Characteristics**:

- Breaks down complex tasks
- Assigns work to specialists
- Prevents conflicts between parallel agents
- Uses sequential-thinking heavily for planning

**MCP Usage**:

- Primary: Sequential Thinking (multi-agent coordination)
- Secondary: Git (conflict detection), Filesystem (manifests)

### Implementation Agents (Code Writers)

**Example**: `react-typescript-specialist.md`

**Characteristics**:

- Writes production code
- Follows strict patterns (TypeScript zero `any` types)
- Creates tests alongside implementation

**MCP Usage**:

- Primary: Filesystem (reading/writing code)
- Secondary: Git (understanding component evolution), REF (React docs)

### Research/Planning Agents (Architects)

**Example**: `database-expert.md`, `system-architect.md`

**Characteristics**:

- Designs schemas, architectures
- Optimizes performance
- Plans migrations

**MCP Usage**:

- Primary: Sequential Thinking (complex design decisions)
- Secondary: Filesystem (schema files), REF (version-specific features)

### Hive-Specific Agents (Domain Experts)

**Example**: `memory-optimizer.md`, `rust-backend-expert.md`

**Characteristics**:

- Deep knowledge of Hive's architecture
- References specific file paths (src/memory-service/, src/consensus-engine/)
- Works with Hive's unique patterns (zero-fallback ports, 8 CLI tools)

**MCP Usage**:

- Primary: Filesystem (Hive-specific code), Sequential Thinking (Hive debugging)
- Secondary: REF (Tokio docs, SQLite docs), Git (Hive evolution)

---

## Creating New Agents: Step-by-Step

### Step 1: Identify the Need

**Ask**:

- Is there a domain where users frequently need expert help?
- Would specialists benefit from deep, domain-specific knowledge?
- Can this agent's role be clearly defined?

**Example**: Database work kept appearing → Need database-expert

### Step 2: Define the Scope

**Document**:

- Primary expertise areas
- Technologies covered (e.g., SQLite 3.0-3.45+, PostgreSQL)
- What the agent does NOT cover

### Step 3: Structure the Agent File

**Use this template**:

```markdown
---
name: your-agent-name
version: 1.0.0
description: Use this agent when... <example>...</example>
color: purple
model: inherit
---

You are a [role] with deep expertise in [domain]. You excel at [capabilities].

## Core Expertise

**Category 1:**

- Capability 1
- Capability 2

**Category 2:**

- Capability 1

## MCP Tool Usage Guidelines

### Filesystem MCP (Primary Tool)

**Use filesystem MCP when**:

- ✅ Use case 1
- ✅ Use case 2

### Sequential Thinking (Complex Problems)

**Use sequential-thinking when**:

- ✅ Multi-step analysis

### REF Documentation

**Use REF when**:

- ✅ Looking up docs

**Decision rule**: [Summary]

## [Domain-Specific Sections]

[Your specialized knowledge here]

## Output Standards

Your outputs must include:

- **Standard 1**: Description
- **Standard 2**: Description
```

### Step 4: Add Comprehensive MCP Guidelines

**Critical**: Each MCP tool section should have:

1. ✅ When to use (specific scenarios)
2. 📝 Example usage (code/pseudo-code)
3. ⚠️ When NOT to use (avoid misuse)
4. 🎯 Decision rule (one-line summary)

### Step 5: Test the Agent

**Validation**:

```bash
# Create the agent file
vim .claude/agents/research-planning/your-agent.md

# Restart Claude Code
cd ~/your-project
claude

# Test invocation
@your-agent Test this agent's capabilities
```

**Check**:

- Does agent respond with domain expertise?
- Does agent use appropriate MCP tools?
- Does agent follow output standards?

---

## Agent Naming Conventions

### File Naming

- **Pattern**: `lowercase-with-hyphens.md`
- **Location**:
  - `.claude/agents/coordination/` - PM agents
  - `.claude/agents/implementation/` - Code writers
  - `.claude/agents/research-planning/` - Architects, planners
  - `.claude/agents/hive/` - Project-specific (Hive example)

### Agent Name (YAML frontmatter)

- **Must match** file name (without `.md`)
- **Invocation**: `@agent-name`
- **Example**: File `database-expert.md` → `name: database-expert` → `@database-expert`

### Color Selection

- **Blue**: Coordination, core infrastructure
- **Cyan**: Implementation (code writers)
- **Green**: Analysis, validation
- **Purple**: Architecture, databases, orchestration
- **Orange**: Backend, systems
- **Yellow**: Frontend, UI
- **Magenta**: Tools, integrations
- **Pink**: Documentation, planning
- **Red**: APIs, external integrations

**Tip**: Use colors thematically to help users recognize agent types visually.

---

## database-expert Agent: Case Study

### Why This Agent Was Created

**Problem**: Database design and optimization kept appearing as user needs:

- SQLite schema design for Memory Service
- Query optimization for slow searches
- Migration strategies for schema changes
- ACID compliance questions

**Solution**: Create comprehensive database specialist covering:

- SQLite (all versions, 3.0-3.45+)
- PostgreSQL (comparison, when to switch)
- ACID transactions
- Query optimization (EXPLAIN QUERY PLAN)
- Indexing strategies
- Schema normalization

### Key Design Decisions

**1. Version-Specific Feature Coverage**

- SQLite 3.35+: RETURNING clause
- SQLite 3.44+: JSONB format
- SQLite 3.45+: Enhanced aggregates

**Why**: Users need to know which features are available in their version.

**2. Comprehensive PRAGMA Guide**

- WAL mode (journal_mode)
- Cache sizing (cache_size)
- Memory-mapped I/O (mmap_size)

**Why**: SQLite performance heavily depends on PRAGMA configuration.

**3. Real-World Patterns**

- Timestamps with triggers
- Soft deletes
- Polymorphic associations
- Audit trails

**Why**: Common patterns users implement repeatedly.

**4. MCP Tool Selection**

- **Primary**: Sequential Thinking (complex schema design)
- **Secondary**: Filesystem (reading schemas), REF (version features)

**Why**: Database design is inherently multi-step and requires version-specific docs.

### Integration Points

**Works With**:

- `memory-optimizer` - Both optimize SQLite (database-expert designs, memory-optimizer tunes)
- `system-architect` - Architect designs system, database-expert implements schema
- `rust-backend-expert` - Backend uses database, database-expert optimizes queries

**Hive-Specific Use Cases**:

- Memory Service SQLite optimization
- Consensus result storage
- CLI tool launch tracking
- IPC message persistence

---

## Best Practices for Agent Development

### 1. ✅ Be Specific in MCP Guidelines

**Good**:

```markdown
**Use filesystem MCP when**:

- ✅ Reading Prisma schema files (prisma/schema.prisma)
- ✅ Analyzing TypeORM entities (src/entities/\*.ts)
```

**Bad**:

```markdown
**Use filesystem MCP when**:

- ✅ Reading files
```

### 2. ✅ Include Realistic Examples

**Good**:

```markdown
<example>
Context: User has slow queries on 100k rows
user: 'My SQLite query takes 5+ seconds. How do I optimize?'
assistant: 'I'll use database-expert to analyze with EXPLAIN QUERY PLAN'
<commentary>Query optimization requires deep SQLite knowledge</commentary>
</example>
```

### 3. ✅ Provide Decision Rules

**Good**:

```markdown
**Decision rule**: Use filesystem for schema files, sequential-thinking
for complex optimization, REF for version-specific features, bash for
running migrations.
```

### 4. ✅ Define Output Standards

**Good**:

```markdown
## Output Standards

Your database implementations must include:

- **Complete DDL**: CREATE TABLE with all constraints
- **Indexes**: Covering indexes for common queries
- **Migrations**: Versioned with rollback capability
```

### 5. ✅ Version Your Agents

**Pattern**: Semantic versioning

- `1.0.0`: Initial release
- `1.1.0`: New capability added
- `1.0.1`: Bug fix in examples
- `2.0.0`: Breaking change (major restructure)

---

## Summary: Agent Design Principles

1. **Single Responsibility**: Each agent has ONE clear domain
2. **Deep Expertise**: Agents are specialists, not generalists
3. **MCP-Aware**: All agents know when to use MCP tools
4. **Output Standards**: Consistent, production-ready deliverables
5. **Examples-Driven**: Description includes realistic use cases
6. **Version-Aware**: Agents know technology version differences
7. **Integration-Ready**: Agents work well with other specialists

**The database-expert agent exemplifies these principles**: Deep SQLite knowledge, clear MCP guidelines, comprehensive patterns, version-aware features, works with memory-optimizer and system-architect.

---

**For more information**:

- Agent implementations: `.claude/agents/`
- MCP configuration: `.claude/.mcp.json`
- MCP usage guide: `.claude/docs/MCP_USAGE_GUIDE.md`
