# Artifact Storage Convention

All workflow artifacts are stored under a canonical project slug derived from the git remote URL. This ensures consistent cross-session artifact lookup regardless of local directory name.

## Slug Derivation

```bash
# Derive slug from git remote (owner-repo format)
SLUG=$(git remote get-url origin 2>/dev/null | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$|\1|' | tr '/' '-')
# Sanitize branch name
BRANCH=$(git branch --show-current | tr '/' '-')
```

## Directory Structure

```
~/.claude/plan-w-team/
├── projects/
│   └── <SLUG>/                          # e.g., veronelazio-myapp
│       ├── reviews/
│       │   └── <BRANCH>-review.jsonl    # Append-only review log per branch
│       ├── retros/
│       │   └── <DATE>-retro.json        # Retro snapshots for trend analysis
│       ├── overrides/
│       │   └── <BRANCH>-overrides.json  # Review gate override decisions
│       └── streaks.json                 # Streak tracking across features
└── self-assessments/
    └── <DATE>-assessment.md             # Self-improvement friction reports
```

## Review JSONL Log Format

Append-only, one entry per review event:

```jsonl
{"step":"review","branch":"feat/alerting","status":"pass","critical":0,"informational":3,"auto_fixed":3,"timestamp":"2026-03-18T14:00:00Z"}
{"step":"design-review-lite","branch":"feat/alerting","status":"skipped","reason":"no FRONTEND scope","timestamp":"2026-03-18T14:00:05Z"}
{"step":"ship","branch":"feat/alerting","status":"complete","version":"1.4.0","commits":5,"timestamp":"2026-03-18T14:30:00Z"}
```

## Override Persistence

When a user overrides a review gate (Step 6a), store it:

```json
{
  "branch": "feat/alerting",
  "gate": "design-review",
  "decision": "override",
  "reason": "backend-only change",
  "timestamp": "2026-03-18T14:00:00Z"
}
```

On re-run, read this file and skip re-asking for the same gate on the same branch.

## Retro Snapshot Format

JSON, one per retro run:

```json
{
  "date": "2026-03-18",
  "feature": "alerting-system",
  "commits": 18,
  "lines_added": 847,
  "lines_removed": 23,
  "fix_ratio": 0.11,
  "ai_assisted_ratio": 1.0,
  "sessions": [
    { "type": "Deep", "duration_min": 65 },
    { "type": "Deep", "duration_min": 52 },
    { "type": "Medium", "duration_min": 35 }
  ],
  "wtf_scores": { "rules-builder": 0, "channels-builder": 0 },
  "self_assessment": 9,
  "friction_notes": "Shadow path analysis for email service was too thorough for a simple SMTP call"
}
```

## Streak Tracking

JSON, updated after each ship:

```json
{
  "features_without_p0": 4,
  "longest_deep_session_min": 65,
  "features_this_week": 2,
  "features_this_month": 7,
  "last_updated": "2026-03-18T14:30:00Z"
}
```

## Artifact Lifecycle

- Review logs: Keep indefinitely (small, useful for trend analysis)
- Retro snapshots: Keep indefinitely (used for week-over-week comparison)
- Override decisions: Delete when branch is merged/deleted
- Streak data: Continuously updated, never deleted
- Self-assessments: Keep indefinitely (used to improve the workflow)
