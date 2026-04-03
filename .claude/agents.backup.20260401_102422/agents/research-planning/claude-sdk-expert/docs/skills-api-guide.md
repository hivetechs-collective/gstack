# Agent Skills API Guide

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/skills-guide **Category**: Agent Skills / API
Integration

## Overview

Agent Skills extend Claude's capabilities through organized folders of
instructions, scripts, and resources. This guide explains how to use both
pre-built Anthropic Skills and custom Skills via the Claude API.

## Key Components

### Two Skill Sources

**Anthropic Skills**:

- Pre-built, maintained by Anthropic
- Type: `anthropic`
- Available IDs: `pptx`, `xlsx`, `docx`, `pdf`
- Automatically maintained and updated

**Custom Skills**:

- User-uploaded and managed
- Type: `custom`
- Generated IDs like `skill_01AbCdEfGhIjKlMnOpQrStUv`
- Full control over content and versioning

## Prerequisites

Required for using Skills:

- **Anthropic API key** from Console
- **Beta headers**:
  - `code-execution-2025-08-25`
  - `skills-2025-10-02`
  - `files-api-2025-04-14`
- **Code execution tool** enabled in requests

## Using Skills in Messages

### Container Parameter Structure

Skills are specified via the `container` parameter, supporting up to **8 Skills
per request**. Each requires `type` and `skill_id`, with optional `version`
pinning.

```python
import anthropic

client = anthropic.Anthropic(api_key="your-api-key")

response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    messages=[
        {"role": "user", "content": "Create a PowerPoint presentation about AI trends"}
    ],
    container={
        "skills": [
            {
                "type": "anthropic",
                "skill_id": "pptx",
                "version": "latest"
            }
        ]
    },
    tools=[{"type": "code_execution"}],
    betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
)
```

### Version Pinning

Use `version` parameter to ensure consistent behavior:

```python
{
    "type": "anthropic",
    "skill_id": "xlsx",
    "version": "2025-10-15"  # Pin to specific version
}
```

Without `version` or using `"latest"`, you get the most recent version (may
change behavior over time).

## File Management

When Skills generate documents, they return `file_id` attributes. Use the Files
API to download:

### Retrieve File Metadata

```python
file_metadata = client.beta.files.retrieve_metadata(
    file_id="file_01AbCdEfGhIjKlMnOpQrStUv"
)
```

### Download File Content

```python
file_content = client.beta.files.download(
    file_id="file_01AbCdEfGhIjKlMnOpQrStUv"
)

with open("output.pptx", "wb") as f:
    f.write(file_content.read())
```

### List All Files

```python
files = client.beta.files.list()
for file in files.data:
    print(f"{file.file_id}: {file.file_name}")
```

### Delete Files

```python
client.beta.files.delete(
    file_id="file_01AbCdEfGhIjKlMnOpQrStUv"
)
```

## Multi-Turn Conversations

Reuse containers across messages by specifying the container ID in subsequent
requests, maintaining state and context.

```python
# First message
response1 = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    messages=[{"role": "user", "content": "Start a presentation"}],
    container={
        "skills": [{"type": "anthropic", "skill_id": "pptx"}]
    },
    tools=[{"type": "code_execution"}],
    betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
)

container_id = response1.container.id

# Subsequent messages
response2 = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    messages=[
        {"role": "user", "content": "Start a presentation"},
        {"role": "assistant", "content": response1.content},
        {"role": "user", "content": "Add a slide about benefits"}
    ],
    container={"id": container_id},  # Reuse container
    tools=[{"type": "code_execution"}],
    betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
)
```

## Long-Running Operations

Handle `pause_turn` stop reasons for extended operations. Provide responses back
in subsequent requests to allow Claude to continue.

```python
response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    messages=[{"role": "user", "content": "Complex task..."}],
    container={"skills": [{"type": "anthropic", "skill_id": "xlsx"}]},
    tools=[{"type": "code_execution"}],
    betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
)

if response.stop_reason == "pause_turn":
    # Continue the operation
    continuation = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=4096,
        messages=[
            {"role": "user", "content": "Complex task..."},
            {"role": "assistant", "content": response.content},
            {"role": "user", "content": ""}  # Empty message to continue
        ],
        container={"id": response.container.id},
        tools=[{"type": "code_execution"}],
        betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
    )
```

## Managing Custom Skills

### Creating Skills

Upload via `client.beta.skills.create()` with SKILL.md file required. Maximum
8MB total size.

```python
with open("path/to/SKILL.md", "rb") as skill_file:
    skill = client.beta.skills.create(
        files=[skill_file],
        name="Brand Guidelines",
        description="Apply company brand guidelines to all documents"
    )

print(f"Skill created with ID: {skill.skill_id}")
```

### Adding Supporting Files

```python
with open("path/to/SKILL.md", "rb") as skill_file, \
     open("path/to/reference.md", "rb") as ref_file:
    skill = client.beta.skills.create(
        files=[skill_file, ref_file],
        name="Technical Documentation",
        description="Create technical documentation following our standards"
    )
```

### Listing Skills

Retrieve all Skills with optional `source` filtering for custom or Anthropic
Skills.

```python
# List all skills
all_skills = client.beta.skills.list()

# List only custom skills
custom_skills = client.beta.skills.list(source="custom")

# List only Anthropic skills
anthropic_skills = client.beta.skills.list(source="anthropic")

for skill in all_skills.data:
    print(f"{skill.skill_id}: {skill.name}")
```

### Retrieving Skill Details

```python
skill_details = client.beta.skills.retrieve(
    skill_id="skill_01AbCdEfGhIjKlMnOpQrStUv"
)

print(f"Name: {skill_details.name}")
print(f"Description: {skill_details.description}")
print(f"Created: {skill_details.created_at}")
```

### Updating Skills

```python
with open("path/to/updated_SKILL.md", "rb") as skill_file:
    updated_skill = client.beta.skills.update(
        skill_id="skill_01AbCdEfGhIjKlMnOpQrStUv",
        files=[skill_file]
    )
```

### Deleting Skills

```python
client.beta.skills.delete(
    skill_id="skill_01AbCdEfGhIjKlMnOpQrStUv"
)
```

## Best Practices

### Skill Limits

- **Maximum 8 Skills** per request
- **Maximum 8MB** total size per custom Skill
- Use version pinning for production deployments

### Error Handling

```python
from anthropic import APIError

try:
    response = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=4096,
        messages=[{"role": "user", "content": "Create a report"}],
        container={"skills": [{"type": "custom", "skill_id": "skill_123"}]},
        tools=[{"type": "code_execution"}],
        betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
    )
except APIError as e:
    print(f"API error: {e}")
    # Handle skill not found, invalid configuration, etc.
```

### Performance Optimization

- **Progressive disclosure**: Skills load only when relevant
- **File caching**: Reuse container IDs for multi-turn conversations
- **Selective activation**: Claude determines which Skills to load based on task

## Integration Examples

### TypeScript/Node.js

```typescript
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});

const response = await client.messages.create({
  model: "claude-sonnet-4-5",
  max_tokens: 4096,
  messages: [{ role: "user", content: "Create an Excel report of sales data" }],
  container: {
    skills: [{ type: "anthropic", skill_id: "xlsx", version: "latest" }],
  },
  tools: [{ type: "code_execution" }],
  betas: [
    "code-execution-2025-08-25",
    "skills-2025-10-02",
    "files-api-2025-04-14",
  ],
});
```

### Python with Custom Skills

```python
import anthropic
import os

client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))

# Use custom brand guidelines skill
response = client.messages.create(
    model="claude-sonnet-4-5",
    max_tokens=4096,
    messages=[
        {"role": "user", "content": "Create a branded presentation for Q4 results"}
    ],
    container={
        "skills": [
            {"type": "anthropic", "skill_id": "pptx"},
            {"type": "custom", "skill_id": "skill_brand_guidelines_123"}
        ]
    },
    tools=[{"type": "code_execution"}],
    betas=["code-execution-2025-08-25", "skills-2025-10-02", "files-api-2025-04-14"]
)
```

## Related Documentation

- [Skills in Claude Code](skills-claude-code.md) - CLI environment usage
- [Skills User Guide](skills-user-guide.md) - Getting started guide
- [What Are Skills](skills-what-are-skills.md) - Concepts and overview
- [Skills Engineering Blog](skills-engineering-blog.md) - Technical architecture
- [Skills Examples](skills-github-examples.md) - Community examples

## See Also

- [Agent SDK Overview](overview.md) - Complete SDK architecture
- [Custom Tools](custom-tools.md) - Building custom agent tools
- [Code Execution](code-execution.md) - Code execution capabilities
- [Files API](files-api.md) - File management operations
