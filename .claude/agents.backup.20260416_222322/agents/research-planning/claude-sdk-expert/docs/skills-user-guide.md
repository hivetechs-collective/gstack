# Teaching Claude Using Skills: User Guide

**Last Updated**: 2025-10-17 **Source**:
https://support.claude.com/en/articles/12580051-teach-claude-your-way-of-working-using-skills
**Category**: Agent Skills / User Guide

## What Are Skills?

Skills enable you to package your refined approaches to tasks so Claude applies
them automatically. As the guide explains:

> "Instead of having to repeat this process the next time you complete a similar
> task, Skills let you package what you've learned."

Rather than repeatedly explaining your standards, you create a skill once and
Claude recognizes when to apply it across all conversations.

## Why Skills Matter

You've likely developed effective methods for specific work—report structures,
analysis frameworks, communication styles. Skills eliminate the need to
re-explain these preferences constantly.

### The Old Way

"You could document guidelines in a Project, but they don't automatically apply
when you need them."

- Write guidelines in Project knowledge
- Remember to reference them in every conversation
- Manually explain standards each time
- Inconsistent application

### The New Way

With Skills, Claude automatically loads your QBR skill and applies your brand
guidelines from the start.

- Create Skill once
- Claude detects when it's relevant
- Automatic activation
- Consistent application everywhere

## How Skills Fit Your Workflow

### Skills vs. Projects

**Projects**: Accumulate context over time for specific initiatives

- Product launches
- Research projects
- Long-term development

**Skills**: Work everywhere—regular chats, inside Projects, across all work

- Report templates
- Analysis frameworks
- Communication styles
- Brand guidelines

**Use both together**: Projects for persistent context + Skills for standardized
procedures

### Skills vs. Custom Instructions

**Custom Instructions**: Set universal preferences

- "Ask clarifying questions"
- "Use formal tone"
- "Prefer TypeScript over JavaScript"

**Skills**: Contain far more detail

- Complete reference libraries
- Multi-page frameworks
- Executable scripts
- Activate only for relevant work types

### Skills vs. Regular Prompting

**Regular Prompting**: One-off tasks with good prompts

- Single conversation
- Doesn't persist
- Manual effort each time

**Skills**: Active everywhere

- Combine automatically when multiple expertise areas apply
- Higher-quality outputs than prompting alone
- Consistent behavior across all conversations

## When to Create Skills

Create skills when you've figured out how you want something done consistently:

### Refined Approaches

Tasks you do regularly with established patterns:

- Weekly team updates
- Customer feedback analysis
- Sales call prep
- Research synthesis
- Code reviews
- Documentation generation

### Quality-Dependent Work

Work where consistency and standards are critical:

- **Brand compliance**: Logos, colors, fonts, voice
- **Technical documentation**: API docs, architecture diagrams
- **Legal contracts**: Templates, clauses, review checklists
- **Financial reports**: Formatting, calculations, visualizations

### Multi-Piece Setup

Complex workflows requiring multiple steps:

- Product launches (competitive analysis + messaging + launch plan)
- Market analysis (data collection + analysis + visualization + recommendations)
- Board presentations (research + slides + speaker notes + Q&A prep)

## Getting Started

### Prerequisites

Skills are available as a preview to all paid plans:

- Claude Pro
- Claude Max (formerly Team)
- Claude Team
- Claude Enterprise

### Enabling Skills

1. Navigate to **Settings > Capabilities > Skills**
2. Toggle on pre-built example Skills
3. Start using Skills immediately

### How Skills Activate

When you mention a task matching a skill's name or purpose, Claude recognizes
and loads it automatically.

**Example**:

```
You: "Create a weekly status report for the engineering team"

Claude: "Using Skills: Weekly Team Update, Engineering Standards
I'll create your status report following the established format..."
```

## Creating Custom Skills

You can create custom skills through three methods:

### 1. Write Your Own Custom Skills

Create a folder with a `SKILL.md` file containing YAML frontmatter:

```yaml
---
name: Weekly Team Update
description: Generate weekly team update emails following our standard format
---

# Weekly Team Update

## Format

Every weekly update should include:

1. **Highlights** (3-5 bullet points)
   - Major accomplishments
   - Product launches
   - Team achievements

2. **Metrics** (table format)
   - Key performance indicators
   - Week-over-week changes
   - Month-over-month trends

3. **Challenges** (2-3 items)
   - Current blockers
   - Resource needs
   - Timeline risks

4. **Next Week** (3-5 priorities)
   - Upcoming milestones
   - Important meetings
   - Decision points

## Tone

- Professional but conversational
- Celebrate wins enthusiastically
- Present challenges constructively
- End on optimistic note

## Example

[Include full example update]
```

### 2. Use Claude to Build Skills

Have a conversation with Claude to create a Skill:

**You**: "Help me create a Skill for generating customer feedback analysis
reports. Our reports should categorize feedback into themes, identify trends,
quantify sentiment, and recommend action items. We focus on feature requests,
usability issues, and integration needs."

**Claude**: "I'll help you create a comprehensive customer feedback analysis
Skill. Let me draft a SKILL.md file..."

Claude will:

- Ask clarifying questions about your process
- Draft the SKILL.md content
- Include examples and templates
- Iterate based on your feedback

### 3. Adapt Working Examples

Start with Skills from the community cookbook:

1. Find a similar Skill example
2. Copy the structure
3. Customize for your needs
4. Test and refine

## Skill Storage Locations

### Personal Skills

**Location**: `~/.claude/skills/skill-name/`

Use for:

- Individual workflows
- Experimental Skills
- Personal preferences
- Cross-project utilities

### Project Skills

**Location**: `.claude/skills/skill-name/` (in your project)

Use for:

- Team conventions
- Project-specific standards
- Shared templates
- Collaborative workflows

Commit to git so your entire team uses the same Skills.

## Real-World Examples

### Example 1: Brand Guidelines Skill

**Use case**: Marketing team needs consistent brand application

**SKILL.md**:

```yaml
---
name: Brand Guidelines
description: Apply Acme Corp brand guidelines to all design and communication work
---

# Acme Corp Brand Guidelines

## Color Palette

Primary colors:
- Brand Blue: #0066CC
- Brand Green: #00CC66
- Neutral Gray: #F5F5F5

Accent colors:
- Warning Red: #CC0000
- Success Green: #00AA00

## Typography

- **Headings**: Montserrat Bold
- **Body**: Open Sans Regular
- **Code**: Fira Code

Size scale: 12, 14, 16, 20, 24, 32, 48

## Logo Usage

- Minimum size: 120px width
- Clear space: 1x logo height on all sides
- Never stretch or distort
- Use white logo on dark backgrounds
- Use color logo on light backgrounds

## Voice and Tone

- **Voice**: Professional, innovative, approachable
- **Tone variations**:
  - Marketing: Enthusiastic, benefit-focused
  - Documentation: Clear, concise, helpful
  - Support: Empathetic, solution-oriented

## Supporting Files

`reference.md` - Full brand guidelines PDF content
`logo-files/` - All logo variations
`templates/` - Presentation and document templates
```

**Result**: All team members get brand-compliant outputs automatically

### Example 2: Code Review Skill

**Use case**: Engineering team wants consistent code review standards

**SKILL.md**:

````yaml
---
name: Code Review Standards
description: Perform code reviews following our engineering team's standards for security, performance, and best practices
allowed-tools: Read, Grep, Glob
---

# Code Review Standards

## Review Checklist

### Security
- [ ] No hardcoded secrets or API keys
- [ ] Input validation on all user data
- [ ] SQL injection prevention (parameterized queries)
- [ ] XSS prevention (escaped outputs)
- [ ] Authentication/authorization checks
- [ ] HTTPS for all external requests

### Performance
- [ ] Efficient algorithms (O(n) or better where possible)
- [ ] Database queries optimized with indexes
- [ ] No N+1 query problems
- [ ] Proper caching strategy
- [ ] Lazy loading for large data sets

### Code Quality
- [ ] Clear, descriptive variable names
- [ ] Functions under 50 lines
- [ ] Single responsibility principle
- [ ] Error handling for all edge cases
- [ ] Comprehensive test coverage (>80%)
- [ ] Documentation for complex logic

### TypeScript Specific
- [ ] Proper type definitions (no `any`)
- [ ] Null safety checks
- [ ] Async/await over promises
- [ ] Proper error types

## Review Format

```markdown
## Summary
[Overall assessment]

## Critical Issues (Must Fix)
1. [Issue with file:line reference]

## Recommendations (Should Fix)
1. [Suggestion with file:line reference]

## Nice to Have (Optional)
1. [Enhancement idea]

## Positive Highlights
- [Good patterns observed]
````

## Test Coverage Requirements

Minimum requirements:

- Unit tests: 80% coverage
- Integration tests: Key user flows
- Edge cases: Error conditions, boundary values
- Mock external dependencies

## Example Review

[Include full example review output]

````

**Result**: Consistent, thorough code reviews across all PRs

### Example 3: Customer Support Skill

**Use case**: Support team needs consistent response quality

**SKILL.md**:
```yaml
---
name: Customer Support Response
description: Generate empathetic, solution-oriented customer support responses following our support standards
---

# Customer Support Response Standards

## Response Structure

1. **Acknowledge** - Show you understand the issue
2. **Empathize** - Recognize impact on customer
3. **Explain** - Provide context (if needed)
4. **Solve** - Offer clear solution or next steps
5. **Confirm** - Ensure resolution is clear

## Tone Guidelines

- **Always**: Empathetic, professional, solution-focused
- **Never**: Defensive, dismissive, overly technical
- **Balance**: Warmth + competence

## Response Templates

### Bug Report
````

Hi [Name],

Thank you for reporting this issue. I understand how frustrating it must be when
[restate problem].

I've investigated and found that [explanation]. Here's how we can fix this:

1. [Step 1]
2. [Step 2]
3. [Step 3]

This should resolve the issue within [timeframe]. I'll follow up to confirm
everything is working correctly.

Is there anything else I can help with?

Best regards, [Your name]

```

### Feature Request
```

Hi [Name],

Thanks for this suggestion! I can see how [feature] would be valuable for [use
case].

I've added this to our feature request tracker. While I can't commit to a
specific timeline, I'll make sure our product team sees this feedback.

In the meantime, here's a workaround you might find helpful: [alternative
solution]

I'll update you if this gets scheduled for development.

Best regards, [Your name]

```

## Escalation Criteria

Escalate immediately if:
- Customer is threatening legal action
- Security or data privacy concern
- High-value account (Enterprise tier)
- Issue impacts multiple customers
- Solution requires engineering team

## Follow-up Schedule

- Critical issues: Same day
- High priority: Within 24 hours
- Normal priority: Within 48 hours
- Feature requests: Weekly digest
```

**Result**: Consistent, high-quality customer support at scale

## Best Practices

### 1. Start Simple

Begin with a basic Skill and refine over time:

**Version 1**:

```yaml
---
name: Meeting Notes
description: Generate structured meeting notes
---
# Meeting Notes

## Format
- Date and attendees
- Key decisions
- Action items
- Next steps
```

**Version 2** (after using it):

```yaml
---
name: Meeting Notes
description: Generate comprehensive meeting notes following our team format
---

# Meeting Notes

## Format

### Header
- **Date**: [Date]
- **Attendees**: [Names]
- **Duration**: [Start - End]
- **Type**: [Weekly sync / Planning / Retrospective]

### Agenda
- [Agenda items discussed]

### Key Decisions
1. [Decision with rationale]

### Action Items
| Owner | Task | Deadline | Priority |
|-------|------|----------|----------|
| [Name] | [Task] | [Date] | [H/M/L] |

### Parking Lot
- [Items deferred for later]

### Next Meeting
- **Date**: [Date]
- **Focus**: [Topics]
```

### 2. Include Examples

Always include concrete examples in your Skills:

```markdown
## Example Output

**Input**: "Generate meeting notes for our product planning session"

**Output**: [Show complete example of what you want Claude to produce]
```

### 3. Test Thoroughly

Before deploying a Skill to your team:

1. Test with multiple scenarios
2. Verify edge cases
3. Get feedback from colleagues
4. Iterate based on real usage

### 4. Document Clearly

Include comprehensive documentation in your Skill:

- When to use this Skill
- What inputs are needed
- What output to expect
- Common variations

### 5. Version Control

If using project Skills:

```bash
git add .claude/skills/
git commit -m "feat: add customer support response Skill"
git push
```

Team members automatically get updated Skills when they pull.

## Troubleshooting

### Skill Not Activating

**Problem**: Claude doesn't use your Skill when you expect it to

**Solutions**:

1. **Improve description**: Make it more specific about when to activate
2. **Explicit trigger**: Say "Use the [Skill Name] skill to..."
3. **Check location**: Ensure Skill is in `~/.claude/skills/` or
   `.claude/skills/`
4. **Verify format**: YAML frontmatter must be valid

### Inconsistent Results

**Problem**: Skill produces varying outputs

**Solutions**:

1. **Add more examples**: Show exactly what you want
2. **Be more prescriptive**: Specify format in detail
3. **Include templates**: Provide exact structure to follow
4. **Clarify edge cases**: Document how to handle variations

### Skill Too Generic

**Problem**: Skill activates when it shouldn't

**Solutions**:

1. **Narrow description**: Be more specific about use case
2. **Add constraints**: Specify when NOT to use the Skill
3. **Split into multiple Skills**: Create focused Skills for different scenarios

## Advanced Techniques

### Combining Multiple Skills

Skills can work together automatically:

**Example**:

```
You: "Create a branded sales presentation for enterprise prospects"

Claude: "Using Skills: Brand Guidelines, Sales Presentation Template, Enterprise Messaging

I'll create a presentation that combines our brand standards, proven sales structure, and enterprise-focused messaging..."
```

### Dynamic Content Loading

Reference external files that update over time:

````yaml
---
name: Product Pricing
description: Provide accurate product pricing information
---

# Product Pricing

## Current Pricing

Load latest pricing:
```bash
cat pricing-data.json
````

## Discount Rules

[Discount logic based on pricing data]

````

Update `pricing-data.json` externally, Skill always has current data.

### Team Collaboration

Share Skills across your organization:

1. **Create organization skills repository**
```bash
git init company-skills
cd company-skills
mkdir -p .claude/skills/
````

2. **Team members clone and symlink**

```bash
git clone company-skills ~/company-skills
ln -s ~/company-skills/.claude/skills/* ~/.claude/skills/
```

3. **Update skills centrally**

```bash
cd ~/company-skills
git pull
# New skills automatically available
```

## Related Documentation

- [Skills API Guide](skills-api-guide.md) - Using Skills via API
- [Skills in Claude Code](skills-claude-code.md) - CLI usage
- [What Are Skills](skills-what-are-skills.md) - Concepts and overview
- [Skills Engineering Blog](skills-engineering-blog.md) - Technical architecture
- [Skills Examples](skills-github-examples.md) - Community examples

## Additional Resources

- [Skills Cookbook](https://github.com/anthropics/skills) - Example Skills
- [Community Forums](https://community.anthropic.com/) - Share Skills
- [Support Documentation](https://support.claude.com/) - Troubleshooting help
