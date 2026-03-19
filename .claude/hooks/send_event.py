# /// script
# dependencies = ["httpx"]
# requires-python = ">=3.11"
# ///
"""
Universal event dispatcher for Claude Code observability.

Reads hook event data from stdin (JSON) and POSTs it to the observability
server. Always exits 0 so it never blocks Claude Code, even if the server
is down.

Usage in .claude/settings.json:
  "command": "uv run --script .claude/hooks/send_event.py"

Based on IndyDevDan's claude-code-hooks-multi-agent-observability pattern.
"""

import json
import os
import sys

import httpx

SERVER_URL = os.environ.get("OBS_SERVER_URL", "http://localhost:4000")
TIMEOUT = 2.0  # seconds - short timeout to avoid blocking Claude Code


def promote_fields(payload: dict) -> dict:
    """Promote key fields from nested payload to top-level for easier querying."""
    promoted = {}

    # Extract tool_name from various locations
    if "tool_name" in payload:
        promoted["tool_name"] = payload["tool_name"]
    elif "tool" in payload and isinstance(payload["tool"], dict):
        promoted["tool_name"] = payload["tool"].get("name")
    elif "tool" in payload and isinstance(payload["tool"], str):
        promoted["tool_name"] = payload["tool"]

    # Extract agent_id
    if "agent_id" in payload:
        promoted["agent_id"] = payload["agent_id"]
    elif "agentId" in payload:
        promoted["agent_id"] = payload["agentId"]

    # Extract error
    if "error" in payload:
        promoted["error"] = str(payload["error"])
    elif "stderr" in payload and payload["stderr"]:
        promoted["error"] = str(payload["stderr"])[:500]

    # Extract file_path
    if "file_path" in payload:
        promoted["file_path"] = payload["file_path"]
    elif "filePath" in payload:
        promoted["file_path"] = payload["filePath"]
    elif "tool_input" in payload and isinstance(payload["tool_input"], dict):
        promoted["file_path"] = payload["tool_input"].get("file_path") or payload["tool_input"].get("filePath")

    return promoted


def main():
    try:
        # Read hook data from stdin
        raw = sys.stdin.read()
        if not raw.strip():
            sys.exit(0)

        data = json.loads(raw)

        # Determine hook_type from environment or payload
        # Claude Code sends it as "hook_event_name" in the JSON payload
        hook_type = (
            os.environ.get("CLAUDE_HOOK_TYPE")
            or data.get("hook_event_name")
            or data.get("hook_type")
            or data.get("hookType")
            or "unknown"
        )

        # Get session_id from environment or payload
        session_id = (
            os.environ.get("CLAUDE_SESSION_ID")
            or data.get("session_id")
            or data.get("sessionId")
            or "unknown"
        )

        # Promote key fields for easier querying
        promoted = promote_fields(data)

        event = {
            "session_id": session_id,
            "hook_type": hook_type,
            "payload": data,
            **{k: v for k, v in promoted.items() if v is not None},
        }

        # POST to observability server
        with httpx.Client(timeout=TIMEOUT) as client:
            client.post(f"{SERVER_URL}/events", json=event)

    except Exception:
        # Never fail - observability is optional
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
