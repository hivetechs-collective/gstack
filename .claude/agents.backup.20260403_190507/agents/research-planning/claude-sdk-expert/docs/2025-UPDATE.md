# Claude Agent SDK 2025 Update

**Last Updated**: 2025-10-17 **Version**: Agent SDK (renamed from Claude Code
SDK) **Sources**: Anthropic official docs, engineering blog, skywork.ai analysis

---

## Major Changes in 2025

### 1. Renamed from "Claude Code SDK" to "Claude Agent SDK"

The SDK was renamed to reflect its broader applicability beyond coding tasks. It
now powers agents for a "very wide variety of tasks, not just coding."

### 2. Official Language Support

- **TypeScript/Node.js**: `npm install @anthropic-ai/claude-agent-sdk`
- **Python**: `pip install claude-agent-sdk` (requires Python 3.10+)

### 3. Core Architecture: Feedback Loop Pattern

Agents implement a systematic approach:

```
gather context → take action → verify work → repeat
```

This enables self-correction and progressive improvement.

---

## Tool Design Best Practices (2025)

### Primary Execution Mechanism

**Critical insight**: Tools are "prominent in Claude's context window, making
them the primary actions Claude will consider when deciding how to complete a
task."

**Implications**:

- Design tools as **primary, frequent actions**, not secondary utilities
- Be conscious about tool design to maximize context efficiency
- Use specific tools (e.g., `fetchInbox`, `searchEmails`) rather than generic
  ones

### Tool Restriction Patterns

**Permission sprawl prevention**: "Treat tool access like production IAM. Start
from deny-all; allowlist only the commands and directories a subagent needs."

**Recommended approach**:

```typescript
agents: {
  'read-only-analyst': {
    tools: ['Read', 'Grep', 'Glob'], // No modification tools
    permissionMode: 'read-only'
  },
  'code-modifier': {
    tools: ['Read', 'Edit', 'Write'],
    permissionMode: 'prompt' // Requires user approval
  }
}
```

### Complementary Execution Methods

1. **Bash scripts**: Flexible computer operations (file system, process
   management)
2. **Code generation**: Complex, reusable operations
3. **MCP servers**: Standardized external integrations (databases, APIs)

---

## Context Management Strategies

### Agentic Search (Recommended)

Agents use bash commands (`grep`, `tail`, `find`) to intelligently load file
system content into context. This treats "folder structure as a form of context
engineering."

**Advantages**:

- More accurate
- Easier to maintain
- Transparent to developers

### Semantic Search (Use Sparingly)

Only recommended when speed is critical. It's "less accurate, more difficult to
maintain, and less transparent" than agentic search.

### Automatic Compaction

The SDK "automatically summarizes previous messages when the context limit
approaches" to prevent context exhaustion during long-running operations.

**Best practice**: Use CLAUDE.md to encode project conventions, test commands,
directory layout, and architecture notes so agents converge on shared standards.

---

## Subagent Creation Patterns

### Two Primary Use Cases

**1. Parallelization** Execute multiple tasks simultaneously for faster
completion.

**2. Context Isolation** Subagents "use their own isolated context windows, and
only send relevant information back to the orchestrator."

### Creation Pattern

```typescript
const result = query({
  prompt: 'Complex multi-agent task',
  options: {
    agents: {
      'specialist-1': {
        description: 'Specialized task handler',
        prompt: 'You are a specialist in X...',
        tools: ['Read', 'Grep'],
        model: 'claude-sonnet-4-5',
      },
      'specialist-2': {
        description: 'Another specialized handler',
        prompt: 'You are a specialist in Y...',
        tools: ['Write', 'Bash'],
        model: 'claude-haiku-3-5', // Cheaper for simpler tasks
      },
    },
  },
});
```

---

## Verification & Quality Assurance

### Three Validation Approaches

**1. Rules-Based Feedback** (Most Robust) Code linting, syntax checking, and
automated tests provide "multiple additional layers of feedback."

**Example**: Running `eslint` or `cargo clippy` after code generation.

**2. Visual Feedback** Screenshots enable verification of UI/formatting outputs.
Critical for desktop applications.

**Example**: Taking screenshots after UI changes to verify appearance.

**3. LLM-as-Judge** (Least Robust, Use Carefully) Secondary model evaluation for
quality assessment.

**Trade-off**: Less robust but useful for performance gains when speed matters.

---

## Production Deployment Best Practices

### Testing Strategy

1. **Thorough testing**: Examine failure cases specifically
2. **Tool appropriateness**: Evaluate whether agents have the right tools for
   assigned tasks
3. **Representative test sets**: Build tests based on actual usage patterns
4. **Iterative improvement**: Refine tool design when agents repeatedly fail or
   misunderstand tasks

### Permission Management

**Start from deny-all**:

```typescript
// ❌ Bad: Overly permissive
tools: ['Read', 'Write', 'Edit', 'Bash', 'Glob', 'Grep'];

// ✅ Good: Minimal necessary permissions
tools: ['Read', 'Grep']; // Read-only analyst
```

### Security Considerations

- API key management via environment variables or secure storage
- Input validation with schema libraries (Zod in TypeScript)
- Rate limiting per user/IP
- Budget protection to prevent runaway costs
- Audit logging for tool execution

---

## Session Management (2025)

### Session Forking

Create parallel exploration branches from a base session:

```typescript
// Base session
const baseSessionId = await createDesignSession();

// Fork for approach A
const approachA = query({
  prompt: 'Implement with microservices',
  options: {
    resume: baseSessionId,
    forkSession: true, // Creates new branch
  },
});

// Fork for approach B
const approachB = query({
  prompt: 'Implement with monolith',
  options: {
    resume: baseSessionId,
    forkSession: true, // Another branch
  },
});
```

### Session Resumption

Maintain context across days/sessions:

```typescript
const continuedSession = query({
  prompt: 'Continue implementation from yesterday',
  options: {
    resume: previousSessionId, // Full context preserved
  },
});
```

---

## Cost Optimization Strategies

### Model Selection

- **Haiku**: Simple tasks, log analysis, documentation (5x cheaper)
- **Sonnet**: Complex logic, security reviews, architecture design
- **Opus**: Highly complex reasoning (use sparingly)

### Prompt Caching (Extended Thinking)

Cache static context (system prompts, tool definitions, conversation history):

```typescript
{
  type: 'text',
  text: systemPrompt,
  cache_control: { type: 'ephemeral' }
}
```

**Savings**: 90% discount on cached tokens ($0.30/MTok vs $3.00/MTok for Sonnet)

### Budget Enforcement

```typescript
const budgetManager = new BudgetManager({
  maxCostUSD: 100.0,
  dailyLimit: 10.0,
  alertThreshold: 0.8, // Alert at 80%
});

// Check before execution
const budgetCheck = await budgetManager.checkBudget(estimatedCost);
if (!budgetCheck.allowed) {
  throw new Error(`Budget exceeded: ${budgetCheck.reason}`);
}
```

---

## Key Insights for Debug Agents

### For Electron Debugging Specifically

**1. Read-Only Analysis First** Debug agents should use
`['Read', 'Grep', 'Glob', 'Bash']` for analysis, requiring explicit approval
before modifications.

**2. Visual Feedback Critical** Desktop app debugging requires screenshot
verification:

```typescript
tools: ['Read', 'Bash']; // Can take screenshots via Bash
```

**3. Rules-Based Verification** Run linting/compilation after diagnosis:

```bash
cargo build --release # Verify Rust compiles
npm run build         # Verify Electron builds
```

**4. Context Management** Use CLAUDE.md to encode:

- Build pipeline workflow (9 quality gates)
- Apple signing requirements
- Production build = test environment philosophy

**5. Systematic Approach**

```
1. Gather logs (Console.app, app logs, crash reports)
2. Analyze patterns (grep, regex matching)
3. Form hypothesis
4. Present findings to user
5. Get approval before fixes
6. Iterate after next build
```

---

## Migration Notes

### From Manual Anthropic SDK

```typescript
// Before
const client = new Anthropic({ apiKey });
const response = await client.messages.create({...});

// After (2025)
const runtime = new AgentRuntime({
  adapter,
  agents: { 'agent-name': {...} }
});
const response = await runtime.executeAgent('agent-name', input);
```

**Benefits**:

- Automatic cost tracking
- Session management
- Tool registry
- Budget enforcement
- Analytics

---

## References

- [Anthropic Engineering Blog](https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk)
- [Official SDK Docs](https://docs.claude.com/en/api/agent-sdk/overview)
- [GitHub - TypeScript SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
- [GitHub - Python SDK](https://github.com/anthropics/claude-agent-sdk-python)
- [Skywork AI Best Practices](https://skywork.ai/blog/claude-agent-sdk-best-practices-ai-agents-2025/)

---

## Summary for Debug Agent Implementation

**electron-debug-expert** should be designed with:

1. **Read-only tools initially**: `['Read', 'Grep', 'Bash']`
2. **Visual feedback capability**: Screenshots via Bash
3. **Rules-based verification**: Run builds/tests after diagnosis
4. **Context awareness**: Understands release = test workflow
5. **User approval pattern**: Present findings, ask permission, implement fixes
6. **Systematic process**: Gather → Analyze → Hypothesize → Present → Fix →
   Iterate
7. **Production build focus**: No local build suggestions
8. **Cost-conscious**: Use Haiku for log analysis, Sonnet for complex diagnosis
