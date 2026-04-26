#!/usr/bin/env python3
"""Stop hook (model-gated). Reads the assistant's last message and asks
`claude -p` whether the assistant made factual claims about code state,
file contents, system behavior, third-party services, or external state
WITHOUT grounding them in cited evidence (error logs, file reads,
command output, search results, documentation lookups).

Runs alongside check_open_items_with_model.py. Different failure mode:
that hook catches premature stops; this one catches confident assertions
not backed by evidence.

Auth: shells out to `claude -p`, no router or external API needed.

Failure mode:
  - any subprocess / parse error -> exit 0 (never break the gate on
    infrastructure issues; only block on explicit BLOCK verdict).

Skips when:
  - stop_hook_active = true (re-entry from a prior block).
  - message is shorter than 200 chars (trivial answers).
  - CHECK_SUBSTANTIATION_DISABLED env var is set to "1".
  - CHECK_SUBSTANTIATION_ACTIVE env var is set to "1" (anti-recursion).
  - `claude` CLI is not on PATH.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys


MAX_MSG_CHARS = 6000
MIN_MSG_CHARS = 200

PROMPT = """You are a strict gate that decides whether an AI assistant just made factual claims WITHOUT grounding them in cited evidence.

The assistant's last message is between <message> tags. The user's project rules say: any claim about code state, file contents, system behavior, configuration, third-party services, or external state must be backed by evidence the assistant actually obtained — error logs, file reads, command output, search results, documentation lookups. Confident assertions made without showing the evidence are forbidden.

Properly grounded claims (DO NOT block):
- The assistant just ran a command and is reporting actual stdout / exit code.
- The assistant cites a file path + line number from a Read.
- The assistant searched the web or docs and is reporting findings (URLs, doc paths).
- The assistant says "I do not know" or "Need to check" when missing evidence.
- The assistant explains a generic concept that does not require substantiation (a definition, a well-known protocol behavior, a math identity).
- The message is purely about meta-coordination ("doing X now", "pushed Y") with no factual claims about state.

Unsubstantiated claims (DO block):
- "The system is doing X" / "X is configured for Y" / "the bug is in Z" with no log line, no file content, no command output, no link cited.
- "Probably / likely / might / I think" used in place of running a check.
- Confident statements about a third-party API / library without showing a doc lookup or example output.
- Claims that a specific function / field / endpoint exists or does not exist without a search or grep result.
- Diagnoses of error causes without showing the error message or relevant code.

Reply with EXACTLY one of these two formats and nothing else:
PASS
or
BLOCK: <one short sentence describing what claim was unsubstantiated and what evidence was missing>

<message>
{message}
</message>
"""


def log(s: str) -> None:
    print(s, file=sys.stderr)


def call_claude(prompt: str) -> str | None:
    env = os.environ.copy()
    env["CHECK_SUBSTANTIATION_ACTIVE"] = "1"
    try:
        proc = subprocess.run(
            ["claude", "-p", prompt],
            capture_output=True,
            text=True,
            env=env,
        )
    except (FileNotFoundError, OSError) as e:
        log(f"check_substantiation_with_model: claude -p failed: {e}")
        return None
    if proc.returncode != 0:
        log(f"check_substantiation_with_model: claude -p rc={proc.returncode}")
        return None
    return (proc.stdout or "").strip() or None


def classify(message: str) -> str | None:
    truncated = message if len(message) <= MAX_MSG_CHARS else message[-MAX_MSG_CHARS:]
    prompt = PROMPT.format(message=truncated)
    if shutil.which("claude") is None:
        return None
    return call_claude(prompt)


def main() -> int:
    if os.environ.get("CHECK_SUBSTANTIATION_DISABLED") == "1":
        return 0
    if os.environ.get("CHECK_SUBSTANTIATION_ACTIVE") == "1":
        return 0

    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError) as e:
        log(f"check_substantiation_with_model: bad stdin json: {e}")
        return 0

    if payload.get("stop_hook_active") is True:
        return 0

    msg = payload.get("last_assistant_message") or ""
    if len(msg) < MIN_MSG_CHARS:
        return 0

    verdict = classify(msg)
    if not verdict:
        return 0

    if verdict.startswith("BLOCK"):
        reason = verdict[len("BLOCK"):].lstrip(": ").strip()
        if not reason:
            reason = "model judged this as containing unsubstantiated claims with no cited evidence."
        out = {
            "decision": "block",
            "reason": (
                f"BLOCKED (substantiation): {reason} "
                "Run a command, read a file, or search before stating it as fact. "
                "Set CHECK_SUBSTANTIATION_DISABLED=1 to bypass this gate temporarily."
            ),
        }
        sys.stdout.write(json.dumps(out))

    return 0


if __name__ == "__main__":
    sys.exit(main())
