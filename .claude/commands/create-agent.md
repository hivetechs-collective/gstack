# Create Agent Command

Create a new Claude Code agent definition using the meta-agent.

## Usage

```
/create-agent [description of the agent you want]
```

## Process

1. The meta-agent will analyze your request
2. Search existing agents for duplicates or similar definitions
3. Generate a properly formatted agent definition
4. Place it in the correct `.claude/agents/` subdirectory
5. Report the created file path

## Examples

```
/create-agent A Python testing specialist that writes pytest tests
/create-agent A Kubernetes deployment agent for managing Helm charts
/create-agent A performance profiling agent for Node.js applications
```

## Notes

- All agents are created with proper YAML frontmatter
- Model defaults to `opus` unless specified otherwise
- Disallowed tools are set based on the agent's intended role
- The meta-agent checks for existing similar agents before creating
