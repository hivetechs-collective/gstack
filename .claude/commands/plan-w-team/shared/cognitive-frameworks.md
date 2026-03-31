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

## Plan Approval vs Direct Build

Plan approval is **optional and reserved for security-critical work**. With `mode: "auto"`, builders execute immediately. Use `mode: "plan"` when the lead needs to review each builder's approach before coding starts.

**Skip plan approval for**: most feature work, single-task bug fixes, tasks where the lead provides explicit implementation instructions, trivial changes.
