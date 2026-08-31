# plan-w-team — Known Issues & Upgrade Backlog

Durable, version-controlled record of observed defects and workarounds for the
`/plan-w-team` skill. This is the canonical reference so findings are not lost in
a session's ephemeral memory. When a fix ships, move the entry to "Resolved" with
the version and bump `VERSION` + `CHANGELOG.md`.

> Provenance: consolidated 2026-08-30 during the all-surfaces BDD-gap greening
> campaign (cleanrev), which exercised the autonomous bg-worker fleet hard across
> two machines and surfaced the items below.

## Open

### KI-1 — bg daemon pins every `--bg` worker to the account it started under (#1703)
- **Symptom:** an autonomous `--bg` lane dies 15–23 min in (or is dead-on-spawn while the picked account is green). Looks like a stall: session goes `waiting`, zero file writes, `terminal_state` stays null.
- **Root cause:** the bg-session daemon reads auth ONCE at startup. A per-invocation token (e.g. `with-account-token.sh <label> -- claude --bg …`) is IGNORED by an already-running daemon — the worker inherits the daemon's (possibly stale/expired) account and dies when that token can't refresh.
- **Workaround:** before spawning, `pkill -f claude` to drop the daemon, then launch the FIRST worker through the account relay so the fresh daemon inherits the live account (`with-account-token.sh knox -- bash pwt-goal.sh --worker-only "<goal>"`). Verify auth first with a bounded `claude -p` probe.
- **Durable fix:** per-lane `settings.local.json` credential (the `--lane-settings-json` / `PWT_LANE_SETTINGS_JSON` seam already in pwt-goal.sh) so each worker authenticates with its own account from its first API call, independent of the daemon.

### KI-2 — `--worker-only` (and other flags) must precede the positional goal argument
- **Symptom:** `pwt-goal.sh "<goal>" --worker-only` prints the assembled `/goal` prompt and exits 0 WITHOUT spawning — no worktree, no worker, no error.
- **Root cause:** the trailing flag after the positional request is not parsed; LAUNCH/WORKER_ONLY stay 0 and the script falls back to print-for-manual-paste mode silently.
- **Workaround:** always put flags FIRST: `pwt-goal.sh --worker-only "<goal>"`.
- **Durable fix:** accept flags in any position, or emit a loud warning when trailing args go unparsed instead of silently degrading to print mode.

### KI-3 — `pwt-steer.sh` default worker_sid is the short 8-char handle, not the full UUID
- **Symptom:** steer refuses with "'<handle>' is not a full session UUID"; a handle strands the resume at a picker while the worker still reports `working`.
- **Workaround:** resolve the full 36-char UUID from `claude agents --json` (`.sessionId`) and pass `--worker-sid <uuid>`.
- **Durable fix:** goal-state should persist the full UUID; steer should auto-resolve handle→UUID.

### KI-4 — steer/resume loses launch-time env unless re-supplied
- **Symptom:** a resumed lane loses `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` and then dead-ends at the push-ack pause site (waits on a human that never comes).
- **Workaround:** pass `--env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` on every steer; `export` the guard-shaped `*DISABLE*` envs (steer's `--env` refuses those by name shape).
- **Durable fix:** persist the launch env with the goal-state and re-apply it automatically on resume.

### KI-5 — generic push-ack "halt" wording alarms operators; auto-push is mode-dependent
- **Note:** `--worker-only`/`--launch` set `AUTO_PUSH=1` (`PLAN_W_TEAM_AUTO_APPROVE_PUSH=1`) so push-ack auto-approves and does NOT dead-end. But a bare `/goal` bg worker, or a resume that dropped the env (KI-4), WILL halt at push. The printed contract lists push-ack as a halt regardless of mode, which reads as "it will wait on me."
- **Durable fix:** make auto-push the default for autonomous bg `/goal`, and word the contract per-mode so an auto-push run does not advertise a halt it won't take.

### KI-6 — lane-guard false-positives on legitimate operator commands
- **Symptom:** the PreToolUse lane guard (PWT-LANE1) blocks the supervisor session's own orchestration Bash calls (gate injection, rsync) while a lane is live.
- **Workaround:** prefix legitimate operator commands with `PLAN_W_TEAM_DISABLE_LANE_GUARD=1`.
- **Durable fix:** narrow the guard so operator orchestration (vs. cross-lane worker writes) is not caught.

### KI-7 — F7 completeness gate absent in fresh worktrees when uncommitted
- **Symptom:** an armed completeness gate is IGNORED in a new worktree.
- **Root cause:** `git worktree add` checks out committed HEAD; if the F7 evaluator is uncommitted in main, the worktree gets the OLD evaluator (gate not honored). The evaluator hook runs the WORKTREE's copy.
- **Workaround (per new worktree/respawn):** copy main's F7 evaluator into the worktree's `.claude/hooks/plan-w-team-goal-evaluator.sh` and `git -C <wt> update-index --skip-worktree` it; inject `completeness_gate` into the worktree's goal-state.
- **Durable fix:** commit the F7 evaluator, or have worktree creation propagate the working-tree evaluator.

## Resolved

### KI-R1 — enumerated-universe scope-collapse → false SUCCESS (fixed v2.22.0)
- **Was:** a "for each of N" goal reached terminal SUCCESS after covering ~19 of 359 because `feature_specific_done_criteria` measured completion against the criteria array's OWN length.
- **Fix:** F7 completeness gate — opt-in goal-state `completeness_gate {label,file,jq|grep_count,max_remaining}`; the evaluator re-measures REMAINING from the SSoT live at every terminal anchor and VETOES SUCCESS while remaining > max. Kill switch `PWT_DISABLE_COMPLETENESS_GATE=1`.
