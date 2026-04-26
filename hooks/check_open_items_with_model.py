#!/usr/bin/env python3
"""Stop hook (model-gated). Reads the assistant's last message and asks a
small fast model — via Wisent's OpenAI-compatible router — whether the
assistant just enumerated work it could have done in the same turn but
stopped instead.

Runs AFTER the regex hooks (check_stop_asking.py, check_time_estimates.py).
Catches paraphrased premature-stops the regex layer can't anticipate.

Auth: routes through MODEL_ROUTER_URL (the Wisent router exposes an
OpenAI-compatible /v1/chat/completions endpoint and dispatches to the
configured backend). MODEL_ROUTER_API_KEY is sent as Bearer auth when set.

Failure mode:
  - any network / parse / timeout error → log to stderr and exit 0.
  - never block on infrastructure issues; only block when the model
    explicitly classifies the message as a premature stop.

Skips when:
  - stop_hook_active = true (re-entry from a prior block).
  - message is shorter than 200 chars (trivial answers).
  - CHECK_OPEN_ITEMS_MODEL_DISABLED env var is set to "1".
  - MODEL_ROUTER_URL is not set.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request
import urllib.error
import http.client


MODEL_NAME = "haiku"  # router maps this to the configured haiku-tier backend
MAX_MSG_CHARS = 6000  # truncate longer messages to last N chars
MIN_MSG_CHARS = 200   # don't bother analyzing very short replies
TIMEOUT_SEC = 12      # cap network wait — never hang the turn

PROMPT = """You are a strict gate that decides whether an AI assistant just stopped its turn prematurely.

The assistant's last message is between <message> tags below. The user's project rules say: if the assistant knows what to do next, it must execute that work in the SAME turn rather than enumerate it and stop. Listing work as "next steps", "highest-leverage gaps", "what's left", "ranked by impact", etc. — and then ending the turn — is a premature stop and must be blocked.

Legitimate stops (DO NOT block):
- The assistant just finished work and reported the result, with no remaining items the assistant itself could execute.
- The assistant ASKED a clarifying question that genuinely needs the user's input (a credential, a creative preference, a decision the user owns, an external action like signing into a vendor portal).
- The assistant's reply is a direct answer to a question that didn't entail follow-on work (a fact lookup, a yes/no, an explanation of how something works).

Premature stops (DO block):
- The assistant lists 2+ concrete tasks, fixes, gaps, or follow-ups that are within its capability (writing code, running shell commands, editing files in the local repo, calling local tools) and stops without doing any of them.
- The assistant says "I'd next add X" / "the natural next step is Y" / "to make this complete you'd Z" — describing future work in second or third person rather than executing.
- The assistant frames remaining work as a separate session, future iteration, follow-up turn, or a job for the user.
- The assistant lists "options" or "approaches" and asks the user to pick when picking-and-trying is itself the obvious next action.

Reply with EXACTLY one of these two formats and nothing else:
PASS
or
BLOCK: <one short sentence describing what the assistant should have executed instead of stopping>

<message>
{message}
</message>
"""


def log(s: str) -> None:
    print(s, file=sys.stderr)


def call_router(router_url: str, prompt: str) -> str | None:
    body = json.dumps({
        "model": MODEL_NAME,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 200,
    }).encode("utf-8")
    headers = {"content-type": "application/json"}
    bearer = os.environ.get("MODEL_ROUTER_API_KEY")
    if bearer:
        headers["authorization"] = f"Bearer {bearer}"
    url = router_url.rstrip("/") + "/v1/chat/completions"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("choices", [{}])[0].get("message", {}).get("content", "").strip()
    except (urllib.error.URLError, http.client.HTTPException, json.JSONDecodeError, OSError) as e:
        log(f"check_open_items_with_model: router call failed: {e}")
        return None


def classify(message: str) -> str | None:
    """Returns the model's verdict text (starting with PASS or BLOCK:) or
    None if no router was reachable."""
    truncated = message if len(message) <= MAX_MSG_CHARS else message[-MAX_MSG_CHARS:]
    prompt = PROMPT.format(message=truncated)

    router_url = os.environ.get("MODEL_ROUTER_URL")
    if not router_url:
        return None
    return call_router(router_url, prompt)


def main() -> int:
    if os.environ.get("CHECK_OPEN_ITEMS_MODEL_DISABLED") == "1":
        return 0

    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError) as e:
        log(f"check_open_items_with_model: bad stdin json: {e}")
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
        # "BLOCK: <reason>" — strip the prefix for the user-facing reason.
        reason = verdict[len("BLOCK"):].lstrip(": ").strip()
        if not reason:
            reason = "model judged this as a premature stop with executable work still listed."
        out = {
            "decision": "block",
            "reason": (
                f"BLOCKED (model-gated): {reason} "
                "If you know what to do next, do it in this turn rather than ending it. "
                "Set CHECK_OPEN_ITEMS_MODEL_DISABLED=1 to bypass this gate temporarily."
            ),
        }
        sys.stdout.write(json.dumps(out))

    return 0


if __name__ == "__main__":
    sys.exit(main())
