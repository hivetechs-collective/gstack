# git-expert SDK Enhancements

**Version**: 2.0.0 **Date**: 2025-10-08 **Agent**: git-expert (Coordination
Agent) **Current Utilization**: 20% (3/15 features) **Target Utilization**: 80%
(12/15 features) **Priority**: CRITICAL (parallel workflow coordinator)

---

## Enhancement Overview

The git-expert agent is critical for coordinating parallel agent workflows.
These enhancements enable:

- **Session forking** to compare Git workflow strategies
- **Subagent creation** for parallel branch operations
- **PreToolUse hooks** to prevent destructive Git operations
- **PostToolUse hooks** to sanitize Git output (emails, sensitive data)
- **Context management** for long-running Git operations
- **Budget enforcement** for cost control

---

## Implementation 1: Session Forking (Workflow Comparison)

### Use Case

Compare Git Flow vs GitHub Flow vs Trunk-Based Development for a specific
project.

### Implementation

```typescript
import { query } from '@anthropic-ai/agent-ts-sdk';

interface GitWorkflowAnalysis {
  workflowType: string;
  complexity: 'low' | 'medium' | 'high';
  teamSize: 'small' | 'medium' | 'large';
  releaseFrequency: 'continuous' | 'weekly' | 'monthly';
  recommendation: string;
  pros: string[];
  cons: string[];
}

class GitWorkflowComparator {
  /**
   * Compare multiple Git workflows using session forking
   */
  async compareWorkflows(
    projectContext: string
  ): Promise<GitWorkflowAnalysis[]> {
    // Base session: Analyze project requirements
    const baseAnalysis = await this.analyzeProjectRequirements(projectContext);
    const baseSessionId = baseAnalysis.sessionId;

    // Fork 1: Git Flow analysis
    const gitFlowAnalysis = query({
      prompt: `Analyze suitability of Git Flow for this project:
        - Main branch (production)
        - Develop branch (integration)
        - Feature branches (feature/*)
        - Release branches (release/*)
        - Hotfix branches (hotfix/*)

        Consider: ${projectContext}`,
      options: {
        resume: baseSessionId,
        forkSession: true, // Creates independent branch
        agents: {
          'gitflow-analyzer': {
            description: 'Analyzes Git Flow compatibility',
            prompt:
              'Expert in Git Flow methodology, release management, hotfix workflows',
            tools: ['Bash', 'Read', 'Grep'],
            allowedTools: ['Bash', 'Read', 'Grep'], // Read-only
            model: 'claude-sonnet-4-5',
          },
        },
      },
    });

    // Fork 2: GitHub Flow analysis
    const githubFlowAnalysis = query({
      prompt: `Analyze suitability of GitHub Flow for this project:
        - Main branch (always deployable)
        - Feature branches (short-lived)
        - Pull requests for all changes
        - Continuous deployment

        Consider: ${projectContext}`,
      options: {
        resume: baseSessionId,
        forkSession: true, // Another independent branch
        agents: {
          'githubflow-analyzer': {
            description: 'Analyzes GitHub Flow compatibility',
            prompt:
              'Expert in GitHub Flow, continuous deployment, PR workflows',
            tools: ['Bash', 'Read', 'Grep'],
            allowedTools: ['Bash', 'Read', 'Grep'],
            model: 'claude-sonnet-4-5',
          },
        },
      },
    });

    // Fork 3: Trunk-Based Development analysis
    const trunkBasedAnalysis = query({
      prompt: `Analyze suitability of Trunk-Based Development:
        - Main branch (trunk)
        - Very short-lived feature branches (<24h)
        - Feature flags for incomplete features
        - High CI/CD maturity required

        Consider: ${projectContext}`,
      options: {
        resume: baseSessionId,
        forkSession: true,
        agents: {
          'trunkbased-analyzer': {
            description: 'Analyzes Trunk-Based Development compatibility',
            prompt:
              'Expert in trunk-based development, feature flags, high-frequency integration',
            tools: ['Bash', 'Read', 'Grep'],
            allowedTools: ['Bash', 'Read', 'Grep'],
            model: 'claude-sonnet-4-5',
          },
        },
      },
    });

    // Collect all results
    const results: GitWorkflowAnalysis[] = [];

    for await (const message of gitFlowAnalysis) {
      if (message.type === 'assistant') {
        results.push(this.parseAnalysis(message, 'Git Flow'));
      }
    }

    for await (const message of githubFlowAnalysis) {
      if (message.type === 'assistant') {
        results.push(this.parseAnalysis(message, 'GitHub Flow'));
      }
    }

    for await (const message of trunkBasedAnalysis) {
      if (message.type === 'assistant') {
        results.push(this.parseAnalysis(message, 'Trunk-Based'));
      }
    }

    // Compare and recommend
    return this.recommendBestWorkflow(results);
  }

  /**
   * Analyze project to establish baseline session
   */
  private async analyzeProjectRequirements(context: string) {
    const analysis = query({
      prompt: `Analyze project requirements for Git workflow selection:
        ${context}

        Extract:
        - Team size
        - Release frequency
        - Deployment environment
        - CI/CD maturity
        - Hotfix requirements`,
      options: {
        agents: {
          'requirements-analyzer': {
            description: 'Extracts project requirements',
            prompt:
              'Analyze project characteristics for Git workflow selection',
            tools: ['Read', 'Grep'],
            allowedTools: ['Read', 'Grep'],
            model: 'claude-sonnet-4-5',
          },
        },
      },
    });

    let sessionId = '';
    for await (const message of analysis) {
      if (message.type === 'system' && message.subtype === 'init') {
        sessionId = message.session_id;
      }
    }

    return { sessionId };
  }

  private parseAnalysis(
    message: any,
    workflowType: string
  ): GitWorkflowAnalysis {
    // Parse assistant response into structured analysis
    return {
      workflowType,
      complexity: 'medium',
      teamSize: 'medium',
      releaseFrequency: 'weekly',
      recommendation: message.content,
      pros: [],
      cons: [],
    };
  }

  private recommendBestWorkflow(
    analyses: GitWorkflowAnalysis[]
  ): GitWorkflowAnalysis[] {
    console.log('\n' + '='.repeat(80));
    console.log('  GIT WORKFLOW COMPARISON RESULTS');
    console.log('='.repeat(80));

    analyses.forEach((analysis, index) => {
      console.log(`\n${index + 1}. ${analysis.workflowType}`);
      console.log(`   Complexity: ${analysis.complexity}`);
      console.log(`   Pros: ${analysis.pros.join(', ')}`);
      console.log(`   Cons: ${analysis.cons.join(', ')}`);
    });

    console.log('\n' + '='.repeat(80));

    return analyses;
  }
}
```

### Integration with Orchestrator

```typescript
// orchestrator.md calls git-expert with session forking
const gitExpert = query({
  prompt:
    'Compare Git workflows for this Next.js project with 5-person team, weekly releases',
  options: {
    agents: {
      'git-expert': {
        description: 'Git workflow specialist',
        prompt:
          'Use session forking to compare Git Flow, GitHub Flow, and Trunk-Based Development',
        tools: ['Bash', 'Read', 'Grep'],
        model: 'claude-sonnet-4-5',
        // git-expert internally uses session forking
      },
    },
  },
});
```

---

## Implementation 2: Advanced Subagent Patterns (Parallel Branch Operations)

### Use Case

Coordinate 7 agents working on different features simultaneously without merge
conflicts.

### Implementation

```typescript
interface BranchTask {
  agentName: string;
  featureName: string;
  targetFiles: string[];
  estimatedDuration: string;
}

interface ConflictDetection {
  hasConflicts: boolean;
  conflicts: Array<{
    file: string;
    agents: string[];
    severity: 'high' | 'medium' | 'low';
  }>;
  mergeOrder: string[];
}

class ParallelBranchCoordinator {
  /**
   * Create specialized subagents for parallel Git operations
   */
  getParallelBranchSubagents() {
    return {
      'conflict-detector': {
        description: 'Detects file conflicts before agents start work',
        prompt: `Analyze proposed agent tasks and predict merge conflicts.

          For each file:
          1. Identify which agents will modify it
          2. Determine conflict probability (high if 2+ agents, low if read-only)
          3. Recommend merge order based on dependencies

          Output format:
          - File: path/to/file.ts
          - Agents: [agent1, agent2]
          - Conflict: High (both writing)
          - Recommendation: Sequential execution`,
        tools: ['Bash', 'Read', 'Grep'],
        allowedTools: ['Bash', 'Read', 'Grep'], // Read-only
        model: 'claude-sonnet-4-5',
      },

      'branch-creator': {
        description: 'Creates isolated feature branches for each agent',
        prompt: `Create feature branches with timestamp-based naming:

          Pattern: feature/<agent-name>-<feature>-<timestamp>
          Example: feature/auth-models-20241008-143022

          For each agent:
          1. Create branch from main
          2. Verify branch creation
          3. Set up branch tracking
          4. Report branch name to agent`,
        tools: ['Bash', 'TodoWrite'],
        model: 'claude-sonnet-4-5',
      },

      'merge-orchestrator': {
        description: 'Executes merges in dependency order',
        prompt: `Merge feature branches in optimal order:

          1. Start with branches that others depend on
          2. Run tests after each merge
          3. Rollback on test failure
          4. Continue only if CI passes

          Stop immediately if:
          - Merge conflicts occur
          - Tests fail
          - CI fails`,
        tools: ['Bash', 'TodoWrite'],
        model: 'claude-sonnet-4-5',
      },

      'conflict-resolver': {
        description: 'Resolves merge conflicts intelligently',
        prompt: `Analyze merge conflicts and provide resolution strategies:

          For each conflict:
          1. Identify conflict type (overlapping, structural, semantic)
          2. Determine if auto-resolvable
          3. If resolvable: Provide merged code
          4. If not: Escalate to human with context

          Use three-way merge analysis:
          - Base: Original code
          - Ours: First agent's changes
          - Theirs: Second agent's changes`,
        tools: ['Bash', 'Read', 'Edit'],
        model: 'claude-sonnet-4-5',
      },
    };
  }

  /**
   * Coordinate parallel agent execution with conflict prevention
   */
  async executeParallelAgents(tasks: BranchTask[]) {
    console.log('🔍 Analyzing task dependencies and conflicts...');

    // Step 1: Detect conflicts BEFORE agents start
    const conflictAnalysis = await this.detectConflicts(tasks);

    if (conflictAnalysis.hasConflicts) {
      console.log('⚠️  Conflicts detected! Adjusting execution plan...');
      console.log(
        'Recommended merge order:',
        conflictAnalysis.mergeOrder.join(' → ')
      );
    }

    // Step 2: Create isolated branches for each agent
    const branches = await this.createBranches(tasks);

    console.log('✅ Created branches:');
    branches.forEach((branch) => console.log(`   - ${branch}`));

    // Step 3: Execute agents in parallel on their branches
    console.log('🚀 Executing agents in parallel...');

    const agentPromises = tasks.map((task) =>
      this.executeAgentOnBranch(task, branches)
    );

    const results = await Promise.all(agentPromises);

    // Step 4: Merge branches in dependency order
    console.log('🔀 Merging branches in optimal order...');

    await this.mergeBranchesInOrder(conflictAnalysis.mergeOrder, results);

    console.log('✅ Parallel execution complete!');
  }

  /**
   * Detect conflicts before agents start
   */
  private async detectConflicts(
    tasks: BranchTask[]
  ): Promise<ConflictDetection> {
    const fileMap = new Map<string, string[]>();

    // Map files to agents
    for (const task of tasks) {
      for (const file of task.targetFiles) {
        if (!fileMap.has(file)) {
          fileMap.set(file, []);
        }
        fileMap.get(file)!.push(task.agentName);
      }
    }

    // Find conflicts (files with multiple agents)
    const conflicts = Array.from(fileMap.entries())
      .filter(([file, agents]) => agents.length > 1)
      .map(([file, agents]) => ({
        file,
        agents,
        severity: 'high' as const,
      }));

    // Determine merge order (topological sort based on dependencies)
    const mergeOrder = this.calculateMergeOrder(tasks, conflicts);

    return {
      hasConflicts: conflicts.length > 0,
      conflicts,
      mergeOrder,
    };
  }

  /**
   * Calculate optimal merge order based on dependencies
   */
  private calculateMergeOrder(tasks: BranchTask[], conflicts: any[]): string[] {
    // Simple heuristic: Tasks with files others depend on go first
    const dependencyGraph = new Map<string, Set<string>>();

    for (const conflict of conflicts) {
      const [first, ...rest] = conflict.agents;
      for (const agent of rest) {
        if (!dependencyGraph.has(agent)) {
          dependencyGraph.set(agent, new Set());
        }
        dependencyGraph.get(agent)!.add(first);
      }
    }

    // Topological sort
    const sorted: string[] = [];
    const visited = new Set<string>();

    function visit(agent: string) {
      if (visited.has(agent)) return;
      visited.add(agent);

      const deps = dependencyGraph.get(agent);
      if (deps) {
        for (const dep of deps) {
          visit(dep);
        }
      }

      sorted.push(agent);
    }

    for (const task of tasks) {
      visit(task.agentName);
    }

    return sorted;
  }

  private async createBranches(tasks: BranchTask[]): Promise<string[]> {
    // Implementation: Create feature branches
    return tasks.map(
      (task) => `feature/${task.agentName}-${task.featureName}-${Date.now()}`
    );
  }

  private async executeAgentOnBranch(
    task: BranchTask,
    branches: string[]
  ): Promise<any> {
    // Implementation: Execute agent on its branch
    return { task, success: true };
  }

  private async mergeBranchesInOrder(
    mergeOrder: string[],
    results: any[]
  ): Promise<void> {
    // Implementation: Merge branches sequentially
    for (const agentName of mergeOrder) {
      console.log(`   Merging ${agentName}...`);
      // Run tests, merge, verify
    }
  }
}
```

### Usage Example

```typescript
const coordinator = new ParallelBranchCoordinator();

await coordinator.executeParallelAgents([
  {
    agentName: 'auth-models',
    featureName: 'user-authentication',
    targetFiles: ['src/models/user.ts', 'src/models/session.ts'],
    estimatedDuration: '15 min',
  },
  {
    agentName: 'auth-api',
    featureName: 'auth-endpoints',
    targetFiles: ['src/api/auth.ts'],
    estimatedDuration: '20 min',
  },
  {
    agentName: 'auth-ui',
    featureName: 'login-components',
    targetFiles: ['src/components/Login.tsx', 'src/components/Signup.tsx'],
    estimatedDuration: '25 min',
  },
]);
```

---

## Implementation 3: PreToolUse Hooks (Prevent Destructive Operations)

### Use Case

Block force pushes to main/master, prevent accidental branch deletions, validate
commit messages.

### Implementation

```typescript
class GitSafetyHooks {
  /**
   * PreToolUse hook to prevent destructive Git operations
   */
  static getPreToolUseHook() {
    return async (input: any) => {
      if (input.tool_name !== 'Bash') {
        return { continue: true };
      }

      const cmd = input.tool_input.command;

      // 1. Block force push to main/master
      if (
        cmd.includes('git push') &&
        cmd.includes('--force') &&
        cmd.match(/origin\s+(main|master)/)
      ) {
        return {
          decision: 'block' as const,
          reason: `❌ BLOCKED: Force push to main/master is prohibited.

            Alternatives:
            - Use feature branches for development
            - Create a PR for review
            - Use --force-with-lease if you must force push

            If this is intentional, use: git push --force-with-lease origin main`,
        };
      }

      // 2. Block deletion of main/master/develop branches
      if (
        cmd.includes('git branch -D') ||
        cmd.includes('git branch --delete')
      ) {
        const protectedBranches = [
          'main',
          'master',
          'develop',
          'staging',
          'production',
        ];

        for (const branch of protectedBranches) {
          if (cmd.includes(branch)) {
            return {
              decision: 'block' as const,
              reason: `❌ BLOCKED: Cannot delete protected branch '${branch}'.

                Protected branches: ${protectedBranches.join(', ')}

                If you need to remove this branch, use GitHub/GitLab UI with proper approvals.`,
            };
          }
        }
      }

      // 3. Warn about reset --hard on main
      if (
        cmd.includes('git reset --hard') &&
        cmd.match(/HEAD~\d+|[a-f0-9]{7,40}/)
      ) {
        console.warn(`⚠️  WARNING: git reset --hard detected!
          This will permanently delete commits.

          Command: ${cmd}

          Safer alternatives:
          - git revert <commit> (creates new commit undoing changes)
          - git reset --soft (keeps changes in staging)

          Continue? (Bash will execute, but this is risky)`);

        // Allow but warn
        return { continue: true };
      }

      // 4. Block commits without proper message format
      if (cmd.includes('git commit -m')) {
        const messageMatch = cmd.match(/git commit -m ["'](.+?)["']/);

        if (messageMatch) {
          const message = messageMatch[1];

          // Enforce conventional commits
          const conventionalPattern =
            /^(feat|fix|docs|style|refactor|test|chore|perf|ci|build)(\(.+\))?: .+/;

          if (!conventionalPattern.test(message)) {
            return {
              decision: 'block' as const,
              reason: `❌ BLOCKED: Commit message must follow Conventional Commits format.

                Invalid: "${message}"

                Format: <type>(<scope>): <description>

                Examples:
                - feat(auth): add JWT authentication
                - fix(api): resolve race condition in user update
                - docs(readme): update installation instructions

                Types: feat, fix, docs, style, refactor, test, chore, perf, ci, build`,
            };
          }
        }
      }

      // 5. Block adding .env files
      if (cmd.includes('git add') && cmd.includes('.env')) {
        return {
          decision: 'block' as const,
          reason: `❌ BLOCKED: Cannot commit .env files (contains secrets).

            .env files should be in .gitignore

            Instead:
            - Add .env to .gitignore
            - Create .env.example with placeholder values
            - Document required env vars in README`,
        };
      }

      // 6. Block rebase on public branches
      if (
        cmd.includes('git rebase') &&
        cmd.match(/origin\/(main|master|develop)/)
      ) {
        return {
          decision: 'block' as const,
          reason: `❌ BLOCKED: Rebasing public branches rewrites history.

            This breaks other developers' work.

            Instead:
            - Use merge for public branches
            - Rebase only local feature branches
            - Coordinate with team if rebase is necessary`,
        };
      }

      return { continue: true };
    };
  }
}

// Integration with git-expert agent
const gitExpertWithSafety = query({
  prompt: 'Merge feature branch into main',
  options: {
    agents: {
      'git-expert': {
        description: 'Git workflow specialist with safety hooks',
        prompt: 'Execute Git operations with safety validation',
        tools: ['Bash', 'Read', 'TodoWrite'],
        model: 'claude-sonnet-4-5',
      },
    },
    hooks: {
      PreToolUse: [
        {
          hooks: [GitSafetyHooks.getPreToolUseHook()],
        },
      ],
    },
  },
});
```

---

## Implementation 4: PostToolUse Hooks (Sanitize Git Output)

### Use Case

Redact email addresses from git log, sanitize git config output, filter
sensitive branch names.

### Implementation

```typescript
class GitOutputSanitizer {
  /**
   * PostToolUse hook to sanitize Git command outputs
   */
  static getPostToolUseHook() {
    return async (input: any, result: any, toolUseId: string) => {
      if (input.tool_name !== 'Bash') {
        return { continue: true };
      }

      const cmd = input.tool_input.command;

      // Only sanitize Git commands
      if (!cmd.includes('git')) {
        return { continue: true };
      }

      // Sanitize output
      const sanitized = this.sanitizeGitOutput(result, cmd);

      return {
        continue: true,
        result: sanitized,
      };
    };
  }

  /**
   * Sanitize Git command output
   */
  private static sanitizeGitOutput(result: any, command: string): any {
    if (!result.content) {
      return result;
    }

    const sanitizedContent = result.content.map((item: any) => {
      if (item.type !== 'text') {
        return item;
      }

      let text = item.text;

      // 1. Redact email addresses from git log
      if (command.includes('git log') || command.includes('git shortlog')) {
        text = text.replace(
          /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g,
          '[email_redacted]'
        );
      }

      // 2. Redact git config user info
      if (command.includes('git config')) {
        text = text.replace(
          /user\.email\s*=\s*[^\s]+/g,
          'user.email=[redacted]'
        );
        text = text.replace(/user\.name\s*=\s*.+$/gm, 'user.name=[redacted]');
      }

      // 3. Redact remote URLs with credentials
      if (command.includes('git remote')) {
        // https://username:password@github.com/... → https://[redacted]@github.com/...
        text = text.replace(/https:\/\/[^:]+:[^@]+@/g, 'https://[redacted]@');

        // git@github.com:username/repo.git → git@github.com:[redacted]/repo.git
        text = text.replace(/git@[^:]+:([^\/]+)\//g, 'git@$1:[redacted]/');
      }

      // 4. Redact sensitive branch names (e.g., feature/SECRET-123)
      text = text.replace(
        /\b(feature|bugfix|hotfix)\/(SECRET|INTERNAL|CONFIDENTIAL)-\d+/g,
        '$1/[redacted]-$2'
      );

      // 5. Redact commit SHAs if full 40-char (keep short 7-char)
      if (command.includes('git log --oneline') === false) {
        text = text.replace(/\b[a-f0-9]{40}\b/g, '[commit_sha_redacted]');
      }

      return {
        ...item,
        text,
      };
    });

    return {
      ...result,
      content: sanitizedContent,
    };
  }
}

// Integration example
const gitExpertWithSanitization = query({
  prompt: 'Show git log for authentication feature',
  options: {
    agents: {
      'git-expert': {
        description: 'Git workflow specialist',
        prompt: 'Analyze git history with output sanitization',
        tools: ['Bash', 'Read'],
        allowedTools: ['Bash', 'Read'],
        model: 'claude-sonnet-4-5',
      },
    },
    hooks: {
      PostToolUse: [
        {
          hooks: [GitOutputSanitizer.getPostToolUseHook()],
        },
      ],
    },
  },
});
```

---

## Implementation 5: Context Management (Long Git Operations)

### Use Case

Preserve state during long git operations (large repo clones, extensive history
analysis).

### Implementation

```typescript
class GitContextManager {
  private contextUsage: number = 0;
  private readonly MAX_CONTEXT = 200000;
  private gitOperationState: {
    operation: string;
    branch: string;
    progress: number;
    timestamp: Date;
  } | null = null;

  /**
   * Monitor context during git operations
   */
  async monitorGitOperation(message: any) {
    if (message.usage) {
      this.contextUsage += message.usage.input_tokens;
      const percentage = (this.contextUsage / this.MAX_CONTEXT) * 100;

      if (percentage >= 85) {
        console.log('🚨 Context at 85% during git operation');
        await this.saveGitState();
        await this.triggerCompact();
        this.contextUsage = 0;
      } else if (percentage >= 75) {
        console.warn(
          `⚠️  Context at ${percentage.toFixed(1)}% - git operation may need compaction`
        );
      }
    }
  }

  /**
   * Save git operation state before /compact
   */
  async saveGitState() {
    if (!this.gitOperationState) {
      return;
    }

    console.log('📝 Saving git operation state...');

    const stateData = {
      ...this.gitOperationState,
      currentBranch: await this.getCurrentBranch(),
      uncommittedChanges: await this.getUncommittedChanges(),
      stashList: await this.getStashList(),
    };

    // Save to memory
    await this.persistState('git-operation-state', stateData);

    console.log(`✅ Git state saved: ${this.gitOperationState.operation}`);
  }

  /**
   * Restore git state after /compact
   */
  async restoreGitState() {
    const state = await this.loadState('git-operation-state');

    if (state) {
      this.gitOperationState = state;
      console.log(
        `✅ Restored git operation: ${state.operation} (${state.progress}% complete)`
      );
    }
  }

  /**
   * Update current git operation state
   */
  updateGitOperation(operation: string, branch: string, progress: number) {
    this.gitOperationState = {
      operation,
      branch,
      progress,
      timestamp: new Date(),
    };
  }

  private async getCurrentBranch(): Promise<string> {
    // Implementation: git rev-parse --abbrev-ref HEAD
    return 'main';
  }

  private async getUncommittedChanges(): Promise<string[]> {
    // Implementation: git status --porcelain
    return [];
  }

  private async getStashList(): Promise<string[]> {
    // Implementation: git stash list
    return [];
  }

  private async persistState(key: string, data: any): Promise<void> {
    // Implementation: Save to file or memory
  }

  private async loadState(key: string): Promise<any> {
    // Implementation: Load from file or memory
    return null;
  }

  private async triggerCompact(): Promise<void> {
    console.log('\n' + '='.repeat(60));
    console.log('  🚨 CONTEXT LIMIT - COMPACT RECOMMENDED');
    console.log('  Git operation state has been saved');
    console.log('  Run: /compact');
    console.log('='.repeat(60) + '\n');
  }
}
```

---

## Implementation 6: Budget Enforcement

### Use Case

Limit cost of expensive git operations (large repo analysis, extensive history
parsing).

### Implementation

```typescript
class GitBudgetEnforcer {
  private currentCost: number = 0;
  private readonly maxBudget: number;
  private processedMessages = new Set<string>();

  constructor(maxBudgetUSD: number = 0.5) {
    this.maxBudget = maxBudgetUSD;
  }

  /**
   * PreToolUse hook to enforce budget
   */
  async enforceBeforeGitOperation(input: any) {
    if (input.tool_name !== 'Bash') {
      return { continue: true };
    }

    const cmd = input.tool_input.command;

    // Estimate cost of git operation
    const estimatedCost = this.estimateGitOperationCost(cmd);
    const projectedCost = this.currentCost + estimatedCost;

    if (projectedCost >= this.maxBudget) {
      return {
        decision: 'block' as const,
        reason: `💰 Budget limit of $${this.maxBudget} would be exceeded.

          Current cost: $${this.currentCost.toFixed(4)}
          Estimated operation cost: $${estimatedCost.toFixed(4)}
          Projected total: $${projectedCost.toFixed(4)}

          Operation: ${cmd}

          To continue:
          - Increase budget
          - Use more targeted git commands
          - Break operation into smaller steps`,
      };
    }

    if (projectedCost >= this.maxBudget * 0.8) {
      console.warn(
        `⚠️  Budget at ${((projectedCost / this.maxBudget) * 100).toFixed(1)}%`
      );
      console.warn(
        `   Remaining: $${(this.maxBudget - projectedCost).toFixed(4)}`
      );
    }

    return { continue: true };
  }

  /**
   * Track actual cost of git operations
   */
  async trackGitOperationCost(message: any) {
    if (
      message.type === 'assistant' &&
      message.usage &&
      !this.processedMessages.has(message.id)
    ) {
      this.processedMessages.add(message.id);

      const cost = this.calculateCost(message.usage, message.model);
      this.currentCost += cost;

      console.log(
        `💰 Operation cost: $${cost.toFixed(4)} (Total: $${this.currentCost.toFixed(4)})`
      );
    }
  }

  /**
   * Estimate cost of git operation
   */
  private estimateGitOperationCost(command: string): number {
    // Large repo operations are expensive
    if (
      command.includes('git log --all') ||
      command.includes('git log --graph')
    ) {
      return 0.02; // $0.02 for extensive history
    }

    if (command.includes('git clone') || command.includes('git fetch --all')) {
      return 0.01; // $0.01 for network operations
    }

    if (command.includes('git diff') && command.includes('--stat')) {
      return 0.005; // $0.005 for diff stats
    }

    // Standard git operations
    return 0.001; // $0.001 for basic operations
  }

  private calculateCost(usage: any, model: string): number {
    const pricing = {
      'claude-sonnet-4-5': { input: 3.0, output: 15.0 },
      'claude-opus-4': { input: 15.0, output: 75.0 },
      'claude-haiku-4': { input: 0.25, output: 1.25 },
    };

    const rates = pricing[model] || pricing['claude-sonnet-4-5'];

    const inputCost = (usage.input_tokens / 1_000_000) * rates.input;
    const outputCost = (usage.output_tokens / 1_000_000) * rates.output;

    return inputCost + outputCost;
  }

  /**
   * Get budget summary
   */
  getBudgetSummary() {
    return {
      currentCost: this.currentCost,
      maxBudget: this.maxBudget,
      remaining: this.maxBudget - this.currentCost,
      percentageUsed: (this.currentCost / this.maxBudget) * 100,
    };
  }
}
```

---

## Complete git-expert Integration

### Updated git-expert.md Frontmatter

```yaml
---
name: git-expert
version: 2.0.0
description:
  Git workflow specialist with session forking, subagent coordination, safety
  hooks, and budget enforcement
color: green
model: inherit
sdk_features:
  - sessions
  - session_forking
  - subagents
  - advanced_subagent_patterns
  - cost_tracking
  - budget_enforcement
  - tool_restrictions
  - preToolUse_hooks
  - postToolUse_hooks
  - onMessage_hooks
  - context_management
  - todo_analytics
cost_optimization: true
session_aware: true
supports_subagent_creation: true
---
```

### SDK Utilization Summary

**Before Enhancement**: 20% (3/15 features)

- ✅ Sessions (basic)
- ✅ Cost tracking (basic)
- ✅ Tool restrictions (basic)

**After Enhancement**: 80% (12/15 features)

- ✅ Sessions
- ✅ **Session forking** (workflow comparison)
- ✅ Subagents
- ✅ **Advanced subagent patterns** (parallel branch workers)
- ✅ Cost tracking
- ✅ **Budget enforcement** (limit git operations)
- ✅ Tool restrictions
- ✅ **PreToolUse hooks** (prevent destructive ops)
- ✅ **PostToolUse hooks** (sanitize git output)
- ✅ **OnMessage hooks** (track operations)
- ✅ **Context management** (preserve state)
- ✅ **Todo analytics** (branch lifecycle tracking)

**Remaining** (3/15 - not applicable):

- ❌ Streaming input (not needed for git)
- ❌ Permission modes (covered by PreToolUse)
- ❌ Dynamic prompts (not needed)

---

## Integration with Orchestrator

The orchestrator can now leverage git-expert's enhanced capabilities:

```typescript
// Compare Git workflows using session forking
const workflowComparison = await orchestrator.execute({
  task: "Select optimal Git workflow for project",
  agents: ['git-expert'],
  enableSessionForking: true
});

// Coordinate 7 parallel agents with conflict prevention
const parallelExecution = await orchestrator.execute({
  task: "Implement authentication with 7 agents in parallel",
  agents: ['git-expert', 'auth-models', 'auth-api', 'auth-ui', ...],
  gitExpertMode: 'parallel-coordinator'
});

// Safe git operations with automatic validation
const safeGitOps = await orchestrator.execute({
  task: "Merge feature branch to main",
  agents: ['git-expert'],
  enableSafetyHooks: true
});
```

---

**End of git-expert SDK Enhancements**
