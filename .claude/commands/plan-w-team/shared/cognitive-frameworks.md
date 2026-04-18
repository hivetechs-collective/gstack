# Cognitive Frameworks

Named frameworks referenced throughout the workflow. Use them to ground subjective decisions in established principles rather than arbitrary judgment.

| Framework                                       | Source      | When to Apply                               |
| ----------------------------------------------- | ----------- | ------------------------------------------- |
| One-way vs two-way doors                        | Bezos       | Step 0d, Step 5 review scrutiny             |
| Inversion reflex                                | Munger      | Step 0a ("how would we guarantee failure?") |
| Essential vs accidental complexity              | Brooks      | Step 0c complexity smell                    |
| Make the change easy, then make the easy change | Beck        | Step 1 technical design                     |
| Boring technology                               | McKinley    | Step 1 technology choices                   |
| Focus as subtraction                            | Jobs/Rams   | Step 0 scope challenge, REDUCE mode         |
| Strangler fig pattern                           | Fowler      | Step 1 when replacing existing systems      |
| Error budgets                                   | Google SRE  | Step 6c coverage thresholds                 |
| Single-writer principle                         | Concurrency | Step 2 shared file analysis, Step 5d fixes  |

## Concrete Examples

One-line examples to make the "When to Apply" column actionable:

- **One-way vs two-way doors** — DB migration that drops a column = one-way (needs scrutiny). Adding a feature flag = two-way (proceed).
- **Inversion reflex** — "How would we guarantee this auth rewrite leaks tokens?" → that list becomes the threat model.
- **Essential vs accidental complexity** — Email delivery = essential. Custom retry queue when SES already retries = accidental, cut it.
- **Make the change easy, then make the easy change** — Refactor the notification dispatcher to take a channel arg first, _then_ add the email channel.
- **Boring technology** — Pick Postgres over a new vector DB unless the embedding workload justifies the second system.
- **Focus as subtraction** — In REDUCE mode, the question is "what cuts and still ships?" not "what's nice to add?"
- **Strangler fig pattern** — New `auth_v2` routes proxy to old service; flip traffic per-route; delete old service when zero traffic remains.
- **Error budgets** — 80% line coverage is the budget, not a target — failing it blocks ship; exceeding it does not warrant celebration.
- **Single-writer principle** — Only `migrations/` writes to schema, only `notification_service.ts` writes to `notifications` table — no cross-writes from controllers.

## Plan Approval vs Direct Build

Plan approval is **optional and reserved for security-critical work**. With `mode: "auto"`, builders execute immediately. Use `mode: "plan"` when the lead needs to review each builder's approach before coding starts.

**Skip plan approval for**: most feature work, single-task bug fixes, tasks where the lead provides explicit implementation instructions, trivial changes.
