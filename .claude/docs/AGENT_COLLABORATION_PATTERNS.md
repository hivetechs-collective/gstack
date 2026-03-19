# Agent Collaboration Patterns

**Purpose**: Document which agents work well together and common multi-agent workflows.

---

## Common Agent Combinations

### Full-Stack Application Development

**Workflow**:
1. `@prd-writer` - Create Product Requirements Document
2. `@system-architect` - Design system architecture
3. `@database-expert` - Design database schema
4. `@react-typescript-specialist` - Implement frontend
5. `@stagehand-expert` - Write E2E tests

**Orchestrator Prompt**:
```
@orchestrator Build a full-stack blog platform with user auth, posts, comments.
Use prd-writer → system-architect → database-expert → react-typescript-specialist → stagehand-expert
```

---

### API Integration Project

**Workflow**:
1. `@prd-writer` - Document API requirements
2. `@system-architect` - Design integration architecture
3. `@reddit-api-expert` OR `@youtube-api-expert` OR `@chatgpt-expert` - Implement API client
4. `@database-expert` - Design data storage schema
5. `@react-typescript-specialist` - Build UI for API data

**Orchestrator Prompt**:
```
@orchestrator Integrate Reddit API to fetch and analyze posts from r/ClaudeAI.
Use reddit-api-expert → database-expert → chatgpt-expert (for sentiment analysis) → react-typescript-specialist
```

---

### UI/UX Design → Implementation

**Workflow**:
1. `@ui-designer` - Research and create design specifications (NO CODE)
2. `@shadcn-expert` - Select appropriate shadcn/ui components
3. `@react-typescript-specialist` - Implement components with TypeScript
4. `@stagehand-expert` - Test UI with E2E tests

**Orchestrator Prompt**:
```
@orchestrator Design and implement a modern dashboard UI with charts and data tables.
Use ui-designer (research) → shadcn-expert (component selection) → react-typescript-specialist (implementation) → stagehand-expert (testing)
```

---

### Database Optimization Workflow

**Workflow**:
1. `@database-expert` - Analyze schema, design indexes
2. `@memory-optimizer` - Tune SQLite performance (Hive-specific)

**Orchestrator Prompt**:
```
@orchestrator Optimize our SQLite database for 100k+ record queries.
Use database-expert (schema + indexes) → memory-optimizer (Hive Memory Service tuning)
```

---

### macOS Application Release

**Workflow**:
1. `@release-orchestrator` - Coordinate build pipeline
2. `@macos-signing-expert` - Sign and notarize application
3. `@homebrew-publisher` - Update Homebrew cask

**Orchestrator Prompt**:
```
@orchestrator Execute full release for macOS app version 1.8.525.
Use release-orchestrator (build) → macos-signing-expert (sign/notarize) → homebrew-publisher (Homebrew update)
```

---

## Agent Compatibility Matrix

| Agent | Works Best With | Why |
|-------|----------------|-----|
| **prd-writer** | All agents | Creates requirements for implementation |
| **system-architect** | database-expert, react-typescript-specialist | Designs systems that need implementation |
| **database-expert** | system-architect, memory-optimizer, rust-backend-expert | Schema design + optimization + backend integration |
| **react-typescript-specialist** | ui-designer, shadcn-expert, stagehand-expert | UI design → component selection → implementation → testing |
| **ui-designer** | shadcn-expert, react-typescript-specialist | Research → component selection → implementation |
| **shadcn-expert** | react-typescript-specialist | Component selection → implementation |
| **stagehand-expert** | react-typescript-specialist, nextjs-expert | Tests components/pages built by specialists |
| **chatgpt-expert** | database-expert, react-typescript-specialist | API integration + data storage + UI display |
| **reddit-api-expert** | chatgpt-expert, database-expert | Fetch data → analyze sentiment → store results |
| **youtube-api-expert** | chatgpt-expert, database-expert | Fetch videos/comments → analyze → store |
| **nextjs-expert** | react-typescript-specialist, database-expert | Framework patterns + components + data layer |
| **macos-signing-expert** | release-orchestrator, homebrew-publisher | Sign → publish pipeline |
| **release-orchestrator** | macos-signing-expert, homebrew-publisher | Coordinates build/release workflow |
| **homebrew-publisher** | release-orchestrator, macos-signing-expert | Final step after signing |

---

## Hive-Specific Collaboration Patterns

### Memory Service Optimization
```
@database-expert Design optimal indexes for Memory Service
→ @memory-optimizer Tune SQLite PRAGMA settings for 8 concurrent CLI tools
```

### Consensus Engine Development
```
@rust-backend-expert Implement WebSocket consensus handler
→ @database-expert Design consensus result storage schema
→ @electron-specialist Create IPC bridge for frontend
```

### CLI Tool Integration
```
@cli-tool-manager Recommend optimal tool for codebase analysis
→ @memory-optimizer Optimize memory access for CLI tool tracking
```

---

## Anti-Patterns (What NOT to Do)

### ❌ Don't Ask Specialists to Coordinate
**Bad**:
```
@database-expert Design schema AND implement frontend AND write tests
```

**Why**: Specialist agents focus on one domain. Use orchestrator for multi-domain work.

**Good**:
```
@orchestrator Build user auth system.
Use database-expert (schema) + react-typescript-specialist (frontend) + stagehand-expert (tests)
```

---

### ❌ Don't Overlap Responsibilities
**Bad**:
```
@ui-designer Implement this React component  # ui-designer doesn't write code!
```

**Good**:
```
@ui-designer Research modern dashboard design patterns
→ @react-typescript-specialist Implement the dashboard based on design specs
```

---

### ❌ Don't Skip Planning Agents
**Bad**:
```
@react-typescript-specialist Build an entire e-commerce platform
```

**Why**: No architecture, no schema design, no planning.

**Good**:
```
@orchestrator Build e-commerce platform.
Use prd-writer → system-architect → database-expert → react-typescript-specialist
```

---

## When to Use Orchestrator

**Use `@orchestrator` when**:
- ✅ 3+ agents needed
- ✅ Multiple domains (frontend + backend + database)
- ✅ Dependencies between tasks (DB must exist before API)
- ✅ Parallel execution beneficial

**Use individual agents when**:
- ✅ Single domain task (just database schema design)
- ✅ Simple implementation (one component)
- ✅ No dependencies on other specialists

---

## Sequential vs Parallel Execution

### Sequential (Dependencies)
```
Database schema MUST exist before backend can use it:
1. @database-expert (create schema)
2. Wait for completion
3. @rust-backend-expert (implement API using schema)
```

### Parallel (Independent)
```
Frontend and backend can be built simultaneously:
1. @react-typescript-specialist (build UI components)
2. @rust-backend-expert (build API endpoints)  # Parallel!
3. @orchestrator integrates both
```

**Orchestrator automatically determines which tasks can run in parallel!**

---

## Summary

**Golden Rules**:
1. **Orchestrator** = Only agent that knows all 15 agents
2. **Specialists** = Focus on their domain, mention complementary agents only
3. **Users** = Invoke orchestrator for multi-agent work, individual specialists for single-domain tasks
4. **Collaboration** = Orchestrator coordinates, specialists execute

**This architecture maintains clean separation while enabling powerful multi-agent workflows.**
