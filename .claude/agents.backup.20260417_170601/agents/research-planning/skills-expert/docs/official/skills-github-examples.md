# Claude Skills Repository: Examples and Templates

**Last Updated**: 2025-10-17 **Source**: https://github.com/anthropics/skills
**Category**: Agent Skills / Community Examples **Repository**:
anthropics/skills

## Repository Overview

The official Anthropic Skills repository contains example implementations,
templates, and reference source code for building Skills.

As the repository explains:

> "Skills are folders of instructions, scripts, and resources that Claude loads
> dynamically to improve performance on specialized tasks."

They enable Claude to handle specific workflows repeatably—from brand-compliant
document creation to organization-specific data analysis processes.

## Repository Structure

### Categories of Example Skills

**Creative & Design:**

- Algorithmic art generation using p5.js
- Canvas-based visual design (PNG/PDF output)
- Slack-optimized animated GIF creation

**Development & Technical:**

- HTML artifact building with React and Tailwind CSS
- MCP server creation guidance
- Web application testing via Playwright

**Enterprise & Communication:**

- Brand guideline application
- Internal communications templates
- Professional theme styling system

**Meta Skills:**

- Skill creation guidance
- Template starter files

### Source-Available Document Skills

The repository includes **source-available** (not open source) document
manipulation skills:

- **Word**: `docx` skill implementation
- **PDF**: `pdf` skill implementation
- **PowerPoint**: `pptx` skill implementation
- **Excel**: `xlsx` skill implementation

These represent "point-in-time snapshots" and serve as **reference
implementations** for complex file format handling.

**Note**: These document Skills are maintained by Anthropic and updated
regularly. The repository versions show implementation patterns but may not
match current production versions.

## Getting Started with Skills

### Minimal Structure

Skills require minimal structure to work:

**Directory**:

```
my-skill/
└── SKILL.md
```

**SKILL.md**:

```yaml
---
name: My Skill Name
description: What this skill does and when to activate
---
# My Skill Name

## Instructions

[Detailed markdown instructions Claude will follow]
```

That's it! Claude will load and execute these instructions when the description
matches the task context.

## Access Methods

### Claude Code (CLI)

Register via plugin marketplace:

```bash
/plugin marketplace add anthropics/skills
```

After installation, all Skills in the repository become available in Claude Code
sessions.

### Claude.ai (Web)

Available to paid plan users:

- Navigate to Settings > Capabilities > Skills
- Toggle on Skills preview
- Anthropic Skills available automatically

### Claude API

Upload Skills through the Skills API:

```python
import anthropic

client = anthropic.Anthropic(api_key="your-api-key")

with open("my-skill/SKILL.md", "rb") as f:
    skill = client.beta.skills.create(
        files=[f],
        name="My Skill",
        description="What it does"
    )
```

## Example Skills Analysis

### 1. p5.js Algorithmic Art

**Purpose**: Generate generative art using p5.js library

**Key Features**:

- Canvas-based rendering
- Mathematical pattern generation
- Color palette management
- Export to PNG/SVG

**Implementation Pattern**:

````yaml
---
name: p5.js Art Generator
description: Create generative art and visualizations using p5.js
---

# p5.js Art Generator

## Setup

Create canvas with p5.js:
```javascript
function setup() {
    createCanvas(800, 600);
    background(255);
}

function draw() {
    // Generative art logic
}
````

## Common Patterns

### Parametric Equations

```javascript
let t = 0;
function draw() {
  let x = width / 2 + 200 * cos(t);
  let y = height / 2 + 200 * sin(t);
  ellipse(x, y, 10, 10);
  t += 0.1;
}
```

### Perlin Noise

```javascript
let xoff = 0;
function draw() {
  let n = noise(xoff) * width;
  ellipse(n, height / 2, 10, 10);
  xoff += 0.01;
}
```

````

**Use Case**: Data visualization, generative art, creative coding

### 2. React + Tailwind HTML Artifacts

**Purpose**: Build responsive web UIs with React and Tailwind CSS

**Key Features**:
- Component-based architecture
- Utility-first styling
- Responsive design patterns
- Accessibility built-in

**Implementation Pattern**:
```yaml
---
name: React Tailwind Builder
description: Create modern web UIs using React and Tailwind CSS
---

# React Tailwind Builder

## Component Structure

```jsx
export default function Component() {
    return (
        <div className="container mx-auto px-4">
            <h1 className="text-4xl font-bold text-gray-900">
                Title
            </h1>
            <p className="text-lg text-gray-600">
                Content
            </p>
        </div>
    );
}
````

## Common Patterns

### Card Component

```jsx
<div className="bg-white rounded-lg shadow-md p-6 hover:shadow-lg transition-shadow">
  <h2 className="text-2xl font-semibold mb-2">{title}</h2>
  <p className="text-gray-600">{description}</p>
</div>
```

### Responsive Grid

```jsx
<div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
  {items.map((item) => (
    <Card key={item.id} {...item} />
  ))}
</div>
```

## Tailwind Best Practices

- Use semantic color names: `text-gray-900` not `text-black`
- Responsive modifiers: `md:`, `lg:`, `xl:`
- Hover states: `hover:bg-blue-600`
- Transitions: `transition-all duration-300`

````

**Use Case**: Rapid UI prototyping, landing pages, dashboards

### 3. MCP Server Creator

**Purpose**: Guide creation of Model Context Protocol servers

**Key Features**:
- MCP protocol implementation
- Tool definition patterns
- Resource providers
- Prompt templates

**Implementation Pattern**:
```yaml
---
name: MCP Server Creator
description: Guide creation of Model Context Protocol servers for extending Claude's capabilities
---

# MCP Server Creator

## Basic Server Structure

```typescript
import { MCPServer } from '@modelcontextprotocol/sdk';

const server = new MCPServer({
    name: 'my-mcp-server',
    version: '1.0.0'
});

// Register tools
server.tool({
    name: 'my_tool',
    description: 'What this tool does',
    parameters: {
        type: 'object',
        properties: {
            input: { type: 'string' }
        },
        required: ['input']
    }
}, async ({ input }) => {
    // Tool implementation
    return { result: processInput(input) };
});

// Start server
server.listen();
````

## Tool Definition Pattern

```typescript
server.tool(
  {
    name: 'search_documents',
    description: 'Search internal documentation',
    parameters: {
      type: 'object',
      properties: {
        query: {
          type: 'string',
          description: 'Search query',
        },
        limit: {
          type: 'number',
          description: 'Max results',
          default: 10,
        },
      },
      required: ['query'],
    },
  },
  async ({ query, limit = 10 }) => {
    const results = await searchDocs(query, limit);
    return { results };
  }
);
```

## Resource Provider Pattern

```typescript
server.resource(
  {
    uri: 'docs://{docId}',
    name: 'Documentation',
    description: 'Access internal docs',
  },
  async ({ docId }) => {
    const doc = await fetchDoc(docId);
    return {
      contents: [
        {
          uri: `docs://${docId}`,
          mimeType: 'text/markdown',
          text: doc.content,
        },
      ],
    };
  }
);
```

````

**Use Case**: Extend Claude with custom data sources and capabilities

### 4. Playwright Web Testing

**Purpose**: Automate browser testing for web applications

**Key Features**:
- Cross-browser testing
- UI interaction automation
- Screenshot capture
- Assertion patterns

**Implementation Pattern**:
```yaml
---
name: Playwright Web Tester
description: Create automated browser tests using Playwright
---

# Playwright Web Tester

## Basic Test Structure

```typescript
import { test, expect } from '@playwright/test';

test('user can log in', async ({ page }) => {
    // Navigate
    await page.goto('https://example.com/login');

    // Interact
    await page.fill('input[name="email"]', 'user@example.com');
    await page.fill('input[name="password"]', 'password123');
    await page.click('button[type="submit"]');

    // Assert
    await expect(page).toHaveURL('https://example.com/dashboard');
    await expect(page.locator('h1')).toContainText('Welcome');
});
````

## Common Patterns

### Form Testing

```typescript
test('form validation', async ({ page }) => {
  await page.goto('/form');

  // Submit empty form
  await page.click('button[type="submit"]');

  // Verify error messages
  await expect(page.locator('.error')).toHaveText('Email is required');
});
```

### API Mocking

```typescript
test('with mocked API', async ({ page }) => {
  await page.route('**/api/users', (route) => {
    route.fulfill({
      status: 200,
      body: JSON.stringify([{ id: 1, name: 'Test User' }]),
    });
  });

  await page.goto('/users');
  await expect(page.locator('.user-name')).toHaveText('Test User');
});
```

### Screenshot Comparison

```typescript
test('visual regression', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveScreenshot('homepage.png');
});
```

````

**Use Case**: End-to-end testing, visual regression, CI/CD integration

### 5. Brand Guidelines Skill

**Purpose**: Apply consistent brand standards across all outputs

**Key Features**:
- Color palette enforcement
- Typography standards
- Logo usage rules
- Voice and tone guidelines

**Implementation Pattern**:
```yaml
---
name: Brand Guidelines
description: Apply company brand guidelines to all design and communication work
---

# Brand Guidelines

## Color Palette

Primary colors:
```json
{
    "primary-blue": "#0066CC",
    "primary-green": "#00CC66",
    "neutral-gray": "#F5F5F5"
}
````

Load from file:

```bash
cat colors.json
```

## Typography

- **Headings**: Montserrat Bold
- **Body**: Open Sans Regular
- **Code**: Fira Code

Size scale: 12, 14, 16, 20, 24, 32, 48

## Logo Usage Rules

Reference detailed guidelines:

```bash
cat logo-guidelines.md
```

Quick rules:

- Minimum size: 120px width
- Clear space: 1x logo height
- Never stretch or distort

## Voice and Tone

Load voice guidelines:

```bash
cat voice-and-tone.md
```

Quick reference:

- **Voice**: Professional, innovative, approachable
- **Marketing**: Enthusiastic, benefit-focused
- **Documentation**: Clear, concise, helpful
- **Support**: Empathetic, solution-oriented

```

**Use Case**: Marketing materials, documentation, presentations

## Advanced Patterns

### Progressive Disclosure

Structure large Skills with core instructions in SKILL.md and detailed references in supporting files:

**Directory structure**:
```

skills/enterprise-architecture/ ├── SKILL.md (core overview) ├── patterns/ │ ├──
microservices.md │ ├── event-driven.md │ └── api-gateway.md ├── reference/ │ ├──
aws-best-practices.md │ ├── security-standards.md │ └── performance-targets.md
└── templates/ ├── architecture-decision-record.md └── system-design-doc.md

````

**SKILL.md**:
```yaml
---
name: Enterprise Architecture
description: Design enterprise-scale architectures following company standards
---

# Enterprise Architecture

## Quick Start

1. Review high-level patterns in this file
2. Load specific patterns as needed
3. Use templates for documentation

## Architecture Patterns

### Microservices
```bash
cat patterns/microservices.md
````

### Event-Driven

```bash
cat patterns/event-driven.md
```

## Reference Materials

Load as needed:

- AWS best practices: `cat reference/aws-best-practices.md`
- Security standards: `cat reference/security-standards.md`

## Templates

```bash
cat templates/architecture-decision-record.md
```

```

### Executable Scripts

Include Python/JavaScript for deterministic operations:

**Directory structure**:
```

skills/data-analysis/ ├── SKILL.md └── scripts/ ├── statistical-analysis.py ├──
data-cleaning.py └── visualization.py

````

**SKILL.md**:
```yaml
---
name: Data Analysis
description: Perform comprehensive data analysis with statistical rigor
---

# Data Analysis

## Statistical Analysis

For statistical tests, use the analysis script:

```python
# scripts/statistical-analysis.py
import pandas as pd
from scipy import stats

def t_test(group1, group2):
    t_stat, p_value = stats.ttest_ind(group1, group2)
    return {"t_statistic": t_stat, "p_value": p_value}

# Load data
data = pd.read_csv('data.csv')
result = t_test(data['group_a'], data['group_b'])
print(result)
````

Execute:

```bash
python scripts/statistical-analysis.py
```

## Data Cleaning

Clean messy data:

```bash
python scripts/data-cleaning.py --input raw.csv --output clean.csv
```

## Visualization

Generate charts:

```bash
python scripts/visualization.py --data clean.csv --type scatter --output chart.png
```

````

### Tool Restrictions

Enforce security with `allowed-tools`:

**Read-only analysis Skill**:
```yaml
---
name: Security Auditor
description: Analyze code for security vulnerabilities without making changes
allowed-tools: Read, Grep, Glob
---
````

**Full development Skill**:

```yaml
---
name: Full Stack Developer
description: Complete application development with all tools
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, WebFetch
---
```

## Community Contributions

### How to Contribute

1. **Fork the repository**

```bash
git clone https://github.com/anthropics/skills
cd skills
git checkout -b my-new-skill
```

2. **Create Skill directory**

```bash
mkdir -p skills/my-skill
cd skills/my-skill
```

3. **Write SKILL.md**

```yaml
---
name: My Skill
description: What it does and when to use it
---
# My Skill

[Instructions]
```

4. **Test thoroughly**

```bash
# Test in Claude Code
claude "Use my-skill to [task]"
```

5. **Submit pull request**

```bash
git add skills/my-skill
git commit -m "feat: add my-skill for [use case]"
git push origin my-new-skill
```

### Contribution Guidelines

**Required**:

- Clear, descriptive Skill name
- Precise description with activation triggers
- Comprehensive instructions
- Working examples
- Testing evidence

**Best Practices**:

- Follow progressive disclosure pattern
- Include supporting files for complex Skills
- Use tool restrictions when appropriate
- Provide real-world examples
- Document edge cases

## Related Documentation

- [Skills API Guide](skills-api-guide.md) - API integration
- [Skills in Claude Code](skills-claude-code.md) - CLI usage
- [Skills User Guide](skills-user-guide.md) - Getting started
- [What Are Skills](skills-what-are-skills.md) - Concepts overview
- [Skills Engineering Blog](skills-engineering-blog.md) - Technical architecture

## See Also

- [Agent SDK Overview](overview.md) - Complete SDK architecture
- [Custom Tools](custom-tools.md) - Building custom agent tools
- [MCP Integration](mcp-integration.md) - Model Context Protocol servers

## External Resources

- **GitHub Repository**: https://github.com/anthropics/skills
- **Official Documentation**: https://docs.claude.com/
- **Community Forums**: https://community.anthropic.com/
- **Support**: https://support.claude.com/
