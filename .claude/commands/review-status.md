---
description: Check executive review status and upcoming reviews
allowed-tools: Read
---

Check review status from available sources.

## Check Configuration

1. **Project configuration:**
   - Read `.claude/project.json`
   - Check `features` array for status values
   - Check `governance.requireExecutiveReview` setting

2. **Review status file (if exists):**
   - `/docs/review-status.md`
   - `/docs/governance/review-status.md`

## Executive Review Dashboard

### Features by Status

List features from project.json showing:
- Feature ID and name
- Status (blocked/unblocked)
- Associated path pattern
- Review ID (if applicable)

### Upcoming Reviews (if review-status.md exists)

List reviews in chronological order with:
- Review ID
- Feature area
- Scheduled date
- Days until review
- Preparation status

### Completed Reviews

List any reviews marked as COMPLETED with:
- Completion date
- Key decisions made
- Features now unblocked

### Action Items

- Reviews within 7 days that need preparation
- Any blocked work that could start after upcoming review
- Suggested preparation tasks

If no review-status.md exists:
- Note that executive review tracking is not configured
- Suggest creating `/docs/review-status.md` if needed
