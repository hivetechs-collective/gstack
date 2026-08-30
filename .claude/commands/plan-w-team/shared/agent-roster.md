# Agent Roster — Quick Reference for Task Assignment

Two different things live here, and confusing them is the mistake this file exists to
prevent.

- **Agents** are separate sessions. You spawn one with `subagent_type` in Step 3. An
  agent exists only when a session boundary does real work: an isolated context, a
  binding tool restriction, a model/effort pin, or a stage-file spawn mandate.
- **Skills** are knowledge. Nothing spawns them. They trigger on the task's own wording
  inside whatever session is already running, and load progressively (a lean router
  plus per-technology reference files).

**Default task assignment is `builder`, or `builder-opus` when the task carries
`metadata.difficulty: hard`. The domain skill auto-triggers inside that lane.** Write
assignments that way — `builder; the backend-frameworks skill auto-triggers
(/backend-frameworks to force-load)` — not as a specialist name. A named agent belongs
in a task's assignee field only when one of the four reasons above applies.

## Keep-tier agents (33)

Tags: **RESTRICT** = binding tool restriction · **PIN** = model/effort pin ·
**MANDATE** = a stage file spawns it by name · **GF** = grandfathered.

**Model tier per agent (Model Tiering v6, 2026-08-30).** The execution lanes FOLLOW THE
LANE — `builder`, `builder-opus`, the spec/review fan-out agents (`silent-failure-hunter`,
`research-planning/test-gap-analyzer`, `research-planning/security-gap-analyzer`) and the
Hands specialists (`implementation/react-typescript-specialist`, `rust-backend-specialist`)
carry `model: inherit`, running on the launching session's model (`PWT_PRIMARY_MODEL` in an
autonomous run; the consumer's per-item tier). Held at a **hardcoded pin**: the singleton
verdict/supervisor floor `evaluator` / `validator` / `supervisor` (`claude-opus-4-8`); the
four **design** agents `system-architect` / `ui-designer` / `style-theme-expert` /
`fable-spec-consult` (the design tier, Fable 5); the three **mechanical** agents (`haiku`). The skill
never hardcodes Fable into a spawnable role (the 2026-07 fan-out lockout); the consumer
decides judge→Fable its own way. Seams: `PWT_SUBAGENT_MODEL_BUILDER` /
`PWT_SUBAGENT_MODEL_MECHANICAL` (alias-validated, `sonnet`/`haiku` only). Full map: the
Model Strategy table in `plan-w-team.md`.

### Coordination (4)

| subagent_type                  | Tag      | Role                                                                                                      |
| ------------------------------ | -------- | --------------------------------------------------------------------------------------------------------- |
| `orchestrator`                 | MANDATE  | Multi-agent coordination (see `shared/orchestrator-interception.md` for the in-pipeline routing contract) |
| `release-orchestrator`         | MANDATE  | Release pipelines, one-way-door quality gates                                                             |
| `meta-agent`                   | MANDATE  | `/create-agent` engine; applies the agent-vs-skill taxonomy gate                                          |
| `github-security-orchestrator` | RESTRICT | Repo security, secret scanning, access-control audit — read-only auditor                                  |

### Execution team (7)

| subagent_type           | Tag              | Role                                                                                                                                                |
| ----------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `builder`               | PIN              | Routine implementation — FOLLOWS THE LANE (v6: `model: inherit` → `PWT_PRIMARY_MODEL`; consumer's low-risk items → Sonnet 5); `effort: high` pinned |
| `builder-opus`          | PIN              | Hard lane (`difficulty: hard`) — FOLLOWS THE LANE (v6: `model: inherit`; intelligent work → Opus 4.8); `effort: high` pinned                        |
| `supervisor`            | PIN              | Owns Step 3-4 dispatch for one run — Brain floor (`claude-opus-4-8`; singleton, not fan-out)                                                        |
| `evaluator`             | PIN+RESTRICT     | Evaluates output against acceptance criteria (read-only) — judge, Brain floor (`claude-opus-4-8`)                                                   |
| `validator`             | PIN+RESTRICT     | Read-only code inspection — judge, Brain floor (`claude-opus-4-8`)                                                                                  |
| `silent-failure-hunter` | RESTRICT+MANDATE | Pass-1 reviewer for silent failures/fallbacks — FOLLOWS THE LANE (v6: `model: inherit`)                                                             |
| `fable-spec-consult`    | PIN+RESTRICT     | §1b-pre read-only spec consult — the one Fable design pin (Fable 5)                                                                                 |

### Mechanical (3)

| subagent_type  | Tag          | Role                                                                             |
| -------------- | ------------ | -------------------------------------------------------------------------------- |
| `build-runner` | PIN+RESTRICT | Run builds/tests — Haiku (`haiku`; seam `PWT_SUBAGENT_MODEL_MECHANICAL`)         |
| `file-scanner` | PIN+RESTRICT | File listing/search — Haiku (`haiku`; seam `PWT_SUBAGENT_MODEL_MECHANICAL`)      |
| `log-parser`   | PIN+RESTRICT | Log filtering/extraction — Haiku (`haiku`; seam `PWT_SUBAGENT_MODEL_MECHANICAL`) |

### Implementation (4)

| subagent_type                 | Tag              | Role                                                  |
| ----------------------------- | ---------------- | ----------------------------------------------------- |
| `react-typescript-specialist` | PIN              | React components, TSX, hooks                          |
| `rust-backend-specialist`     | PIN              | Rust, Tokio, async APIs                               |
| `stagehand-expert`            | RESTRICT+MANDATE | E2E tests, Stagehand/Playwright — `tools: Read,Write` |
| `claude-code-docs-updater`    | MANDATE+GF       | Claude Code documentation maintenance                 |

### Research, review & planning (15)

| subagent_type                    | Tag              | Role                                                  |
| -------------------------------- | ---------------- | ----------------------------------------------------- |
| `system-architect`               | MANDATE          | System design, tech decisions; §1b-pre reviewer       |
| `security-expert`                | RESTRICT+MANDATE | OWASP, auth, encryption, audit — Pass-1 slot 1        |
| `code-review-expert`             | RESTRICT+MANDATE | Code quality, coverage, linting — Pass-1 slot 2       |
| `security-gap-analyzer`          | MANDATE          | §5d-bis security-coverage analyzer                    |
| `test-gap-analyzer`              | MANDATE          | §5c-bis test-coverage analyzer                        |
| `api-expert`                     | MANDATE          | REST, GraphQL, OAuth, OpenAPI — slot-3 reviewer       |
| `database-expert`                | MANDATE          | SQLite, PostgreSQL, schemas — slot-3 reviewer         |
| `documentation-expert`           | MANDATE          | Docs, diagrams, Mermaid — slot-3 reviewer             |
| `kubernetes-specialist`          | RESTRICT+MANDATE | K8s manifests, Helm, HPA — slot-3 reviewer            |
| `terraform-specialist`           | RESTRICT+MANDATE | IaC, modules, state — slot-3 reviewer                 |
| `llm-application-specialist`     | MANDATE          | RAG, embeddings, AI agents — slot-3 reviewer          |
| `style-theme-expert`             | MANDATE          | Tailwind, design tokens, a11y — slot-3 reviewer       |
| `unit-testing-specialist`        | MANDATE          | Jest, pytest, TDD — N.a slots + retro coverage        |
| `performance-testing-specialist` | MANDATE          | K6, load testing, bottlenecks — N.p benchmark slot    |
| `ui-designer`                    | RESTRICT+MANDATE | Visual specs, color theory — `tools: Read,Write,Edit` |

## Domain skills (16)

You never put these in `subagent_type`. They trigger on the task's wording inside
whichever session is running; `/<skill-name>` force-loads one when the routing misses.

| Skill                   | Trigger domain                                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `frontend-web`          | Next.js App Router/RSC, Angular 18+ and RxJS, Vue 3 and Pinia, Svelte 5 and SvelteKit, shadcn/ui                               |
| `backend-frameworks`    | Express and Node/TypeScript, FastAPI and Pydantic, Django 5 and DRF, Spring Boot and JPA, ASP.NET Core and EF Core, Go         |
| `mobile`                | Flutter and Dart, React Native and Expo, native iOS (Swift/SwiftUI), native Android (Kotlin/Compose)                           |
| `native-platforms`      | macOS AppKit/SwiftUI, Windows WPF and WinUI 3, WebAssembly                                                                     |
| `data-stores`           | MongoDB, Redis, Elasticsearch/ELK, Kafka and CDC, vector DBs, Snowflake, Databricks, Airflow/dbt pipelines                     |
| `api-protocols`         | GraphQL schema design, Apollo, federation; gRPC and Protocol Buffers                                                           |
| `cloud-platforms`       | AWS (Lambda/ECS/RDS), Azure (Functions/Cosmos), GCP (Cloud Run/BigQuery), Cloudflare Workers/D1/R2/KV                          |
| `devops-delivery`       | Dockerfiles and image hardening, GitHub Actions, GitLab CI, ArgoCD/GitOps, Grafana/Prometheus/OpenTelemetry, incident response |
| `release-publishing`    | npm publishing, Homebrew casks, macOS signing and notarization, pre-release governance gates                                   |
| `ai-engineering`        | Claude Agent SDK, MCP servers, Claude Skills authoring, PyTorch/Transformers, MLOps, OpenCode                                  |
| `media-processing`      | Remotion programmatic video, Whisper transcription                                                                             |
| `integrations`          | SMTP2Go transactional email, YouTube Data API v3, Reddit API (NOT Discord — retired 2026-08, nothing absorbed)                 |
| `microsoft-ecosystem`   | Power Automate, Power BI and DAX, Microsoft 365 and Graph API, Azure Logic Apps                                                |
| `git-workflows`         | Branching strategy, conflict prevention and resolution, merge coordination, history rewrite                                    |
| `product-planning`      | PRDs, user stories, acceptance criteria, success metrics                                                                       |
| `code-review-standards` | Deep security/compliance review checklists                                                                                     |

## Adding an agent

Before writing one, answer the taxonomy question: **would a skill do?** Knowledge and
procedures are a skill. Only isolation, a tool restriction, or a model pin justifies an
agent. If it really is an agent, adding it is a deliberate act — the 33-name set is
asserted by `tests/skill/cases/agent-roster-keep-list.bats`, and a new agent means
editing that keep list on purpose, in the same commit.
