# Agent Roster — Quick Reference for Task Assignment

Use `subagent_type` value when spawning builders in Step 3.

## Implementation Specialists

| subagent_type                      | Domain                               | Color  |
| ---------------------------------- | ------------------------------------ | ------ |
| `nodejs-specialist`                | Node.js, Express, TypeScript backend | green  |
| `react-typescript-specialist`      | React components, TSX, hooks         | cyan   |
| `nextjs-expert`                    | Next.js App Router, SSR, RSC         | black  |
| `vue-specialist`                   | Vue 3, Pinia, Vite                   | green  |
| `svelte-specialist`                | Svelte 5, SvelteKit                  | purple |
| `angular-specialist`               | Angular 18+, RxJS                    | red    |
| `rust-backend-specialist`          | Rust, Tokio, async APIs              | orange |
| `go-specialist`                    | Go, goroutines, high-perf APIs       | cyan   |
| `fastapi-specialist`               | FastAPI, Pydantic, async Python      | green  |
| `django-specialist`                | Django 5, DRF, ORM                   | green  |
| `spring-boot-specialist`           | Spring Boot, JPA, Java               | orange |
| `dotnet-backend-specialist`        | ASP.NET Core, EF Core, C#            | purple |
| `flutter-specialist`               | Flutter, Dart, cross-platform        | blue   |
| `react-native-specialist`          | React Native, Expo                   | blue   |
| `ios-specialist`                   | Swift, SwiftUI, UIKit                | cyan   |
| `android-specialist`               | Kotlin, Jetpack Compose              | green  |
| `macos-native-specialist`          | Swift, AppKit, macOS APIs            | blue   |
| `windows-native-specialist`        | .NET 8+, WPF, WinUI 3                | purple |
| `python-ml-expert`                 | PyTorch, Transformers, ML            | orange |
| `remotion-specialist`              | Programmatic video, React            | blue   |
| `webassembly-specialist`           | WASM, Rust/C++ to browser            | orange |
| `whisper-transcription-specialist` | Audio transcription, yt-dlp          | purple |
| `stagehand-expert`                 | E2E tests, Stagehand/Playwright      | cyan   |

## API & Data

| subagent_type                | Domain                            | Color  |
| ---------------------------- | --------------------------------- | ------ |
| `api-expert`                 | REST, GraphQL, OAuth, OpenAPI     | red    |
| `graphql-specialist`         | Schema design, Apollo, federation | purple |
| `grpc-specialist`            | Protocol Buffers, streaming       | blue   |
| `database-expert`            | SQLite, PostgreSQL, schemas       | purple |
| `mongodb-specialist`         | Document modeling, aggregation    | green  |
| `redis-specialist`           | Caching, pub/sub, sessions        | red    |
| `elasticsearch-specialist`   | Full-text search, ELK stack       | yellow |
| `kafka-specialist`           | Event streaming, CDC, topics      | purple |
| `vector-database-specialist` | Pinecone, Chroma, embeddings      | purple |
| `snowflake-specialist`       | Data warehouse, SQL, Cortex AI    | cyan   |
| `databricks-specialist`      | Spark, Delta Lake, lakehouse      | orange |
| `etl-specialist`             | Airflow, dbt, data pipelines      | purple |

## Cloud & Infrastructure

| subagent_type                | Domain                               | Color   |
| ---------------------------- | ------------------------------------ | ------- |
| `aws-specialist`             | Lambda, ECS, RDS, CloudFormation     | orange  |
| `azure-specialist`           | Functions, Cosmos DB, ARM            | blue    |
| `gcp-specialist`             | Cloud Run, BigQuery, Firestore       | green   |
| `cloudflare-expert`          | Workers, D1, R2, KV, edge            | cyan    |
| `docker-advanced-specialist` | Dockerfile, multi-stage, security    | cyan    |
| `kubernetes-specialist`      | K8s manifests, Helm, HPA             | purple  |
| `terraform-specialist`       | IaC, modules, state management       | blue    |
| `argocd-specialist`          | GitOps, ApplicationSets              | blue    |
| `gitlab-cicd-specialist`     | .gitlab-ci.yml, pipelines            | orange  |
| `devops-automation-expert`   | GitHub Actions, shell scripts, CI/CD | magenta |

## Quality & Security

| subagent_type                    | Domain                             | Color  |
| -------------------------------- | ---------------------------------- | ------ |
| `security-expert`                | OWASP, auth, encryption, audit     | red    |
| `code-review-expert`             | Code quality, coverage, linting    | cyan   |
| `unit-testing-specialist`        | Jest, pytest, TDD, property tests  | green  |
| `performance-testing-specialist` | K6, load testing, bottlenecks      | orange |
| `observability-specialist`       | Grafana, Prometheus, OpenTelemetry | yellow |

## Architecture & Planning

| subagent_type                | Domain                               | Color  |
| ---------------------------- | ------------------------------------ | ------ |
| `system-architect`           | System design, tech decisions        | green  |
| `prd-writer`                 | Product requirements documents       | purple |
| `documentation-expert`       | Docs, diagrams, Mermaid              | pink   |
| `ui-designer`                | Visual specs, color theory (no code) | pink   |
| `style-theme-expert`         | Tailwind, design tokens, a11y        | yellow |
| `shadcn-expert`              | shadcn/ui component selection        | purple |
| `llm-application-specialist` | RAG, embeddings, AI agents           | purple |

## Integration Specialists

| subagent_type           | Domain                              | Color  |
| ----------------------- | ----------------------------------- | ------ |
| `discord-expert`        | Webhooks, bots, notifications       | purple |
| `paddle-expert`         | Billing, subscriptions, checkout    | orange |
| `smtpgo-expert`         | Transactional email, deliverability | green  |
| `youtube-api-expert`    | YouTube Data API v3, quota mgmt     | red    |
| `reddit-api-expert`     | Reddit API, rate limiting           | orange |
| `openrouter-expert`     | Multi-model AI routing, fallback    | purple |
| `chatgpt-expert`        | OpenAI API, sentiment analysis      | purple |
| `claude-sdk-expert`     | Claude Agent SDK, adapters          | purple |
| `mcp-expert`            | MCP servers, tool selection         | blue   |
| `power-automate-expert` | Power Automate, 500+ connectors     | green  |
| `power-bi-expert`       | DAX, Power Query, dashboards        | yellow |
| `microsoft-365-expert`  | Graph API, Teams, SharePoint        | cyan   |
| `logic-apps-expert`     | Azure Logic Apps, iPaaS             | blue   |

## Coordination & Mechanical

| subagent_type  | Domain                                                     | Color  |
| -------------- | ---------------------------------------------------------- | ------ |
| `orchestrator` | Multi-agent coordination                                   | blue   |
| `git-expert`   | Branching, conflict resolution                             | green  |
| `builder`      | General implementation                                     | red    |
| `evaluator`    | Quality evaluation against acceptance criteria (read-only) | orange |
| `validator`    | Read-only code inspection                                  | green  |
| `build-runner` | Run builds/tests (haiku, cheap)                            | cyan   |
| `file-scanner` | File listing/search (haiku, cheap)                         | cyan   |
| `log-parser`   | Log filtering/extraction (haiku, cheap)                    | cyan   |

## Release & Publishing

| subagent_type                  | Domain                           | Color  |
| ------------------------------ | -------------------------------- | ------ |
| `release-orchestrator`         | Release pipelines, quality gates | purple |
| `homebrew-publisher`           | Cask publishing, tap management  | green  |
| `npm-publisher`                | NPM versioning, publishing       | green  |
| `macos-signing-expert`         | Code signing, notarization       | blue   |
| `electron-debug-expert`        | Electron crash diagnosis         | red    |
| `governance-expert`            | Quality gates, compliance        | green  |
| `github-security-orchestrator` | Repo security, secret scanning   | red    |
