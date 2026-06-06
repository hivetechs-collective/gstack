# goal-evaluator escaped-quotes fixtures

Realistic Claude Code transcript JSONL fixtures used by
`tests/skill/scenarios/goal-evaluator-escaped-quotes.bats`. Each file
reproduces one transcript-storage shape the Stop hook
(`.claude/hooks/plan-w-team-goal-evaluator.sh`) must recognize.

All fixtures use slug `escq-feature` unless the filename says otherwise.

Claude Code stores message content as JSON-encoded strings inside the
transcript JSONL. A status block emitted as assistant text therefore lands on
disk with **escaped quotes** (`\"stage\":\"retro-complete\"`). The pre-fix
detector ran `grep -F '"stage":"retro-complete"'` against the raw file and
never matched the escaped form — a false-negative that trapped autonomous
runs. The fix decodes each transcript entry with `jq` before matching.

| Fixture                                 | Transcript shape                                                        | Expected terminal       |
| --------------------------------------- | ----------------------------------------------------------------------- | ----------------------- |
| `success-escaped-assistant-text.jsonl`  | Status block as escaped assistant `.message.content[].text`             | `SUCCESS`               |
| `success-fenced-codeblock.jsonl`        | Status block inside a ` ```json ` fence in assistant text               | `SUCCESS`               |
| `success-raw-direct-write.jsonl`        | Raw (unescaped) status block — direct file-write path (backward-compat) | `SUCCESS`               |
| `success-tool-result-string.jsonl`      | Status block in a `tool_result.content` **string**                      | `SUCCESS`               |
| `success-tool-result-array.jsonl`       | Status block in a `tool_result.content` **array** of `{type:text}`      | `SUCCESS`               |
| `escalation-push-ack.jsonl`             | `pending_escalations:[push-ack]` near slug (escaped assistant text)     | `USER_ESCALATION_HALT`  |
| `low-confidence-streak.jsonl`           | `low_confidence_routes:4` near slug (escaped assistant text)            | `LOW_CONFIDENCE_STREAK` |
| `false-positive-different-slug.jsonl`   | Full status block but for a DIFFERENT slug (documentation quote)        | none (block)            |
| `false-positive-anchor-elsewhere.jsonl` | Escalation site and this-slug anchor in SEPARATE entries                | none (block)            |
| `non-terminal-plain.jsonl`              | Ordinary progress chatter, no status block                              | none (block)            |
| `malformed.jsonl`                       | Garbage / truncated JSON lines                                          | none (block), no crash  |
