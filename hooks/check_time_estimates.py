#!/usr/bin/env python3
"""Stop hook: reject assistant turns that contain time estimates.

Reads the Claude Code Stop-hook JSON from stdin, extracts
`last_assistant_message`, and blocks the turn (by emitting
`{"decision":"block","reason":"..."}`) if the text contains
duration estimates like "takes 5 minutes", "1-2 hours", "half a
day", "ETA", "~30 min", etc.

Whitelists common trading / ML timeframe references (e.g.
"15-minute bars", "10-week SMA", "60-bar max hold") via negative
lookahead against a set of safe follow-on words.
"""
from __future__ import annotations

import json
import re
import sys


NUMBER = r"(?:~?\s*)?[0-9]+(?:\s*[-–—~]\s*[0-9]+)?"
UNIT = r"(?:sec(?:ond)?|min(?:ute)?|hour|hr|day|week|month|year)s?"
SAFE_FOLLOW = (
    r"bar|bars|candle|candles|timeframe|period|sma|ema|atr|ma|"
    r"window|lookback|moving|chart|data|horizon|hold|max|rsi|macd|"
    r"ago|old|span"
)

ESTIMATE_PATTERNS = [
    # "ETA" / "eta:" as a standalone acronym
    r"\bETA\b",
    # "half a day", "half a week", "half an hour"
    r"\bhalf\s+an?\s*(?:day|week|hour|month|year|minute)\b",
    # "a couple of hours", "a few days"
    r"\ba\s+(?:couple|few)\s+of\s+(?:hour|day|week|minute|month)s?\b",
    # verb-gated: "takes 5 minutes", "will take 2 hours"
    rf"\b(?:takes?|took|will\s+take|should\s+take|it\s+takes)\s+"
    rf"{NUMBER}\s*{UNIT}\b",
    # "2 hours of work", "3 days to build/ship/train/...
    rf"\b{NUMBER}\s*{UNIT}\s+(?:of\s+work|to\s+(?:build|implement|"
    rf"port|deploy|ship|train|finish|complete|get))\b",
    # "approximately 2 hours", "around 3 days", "roughly 1 week",
    # "~30 min"
    rf"\b(?:approx|approximately|around|roughly|~)\s*{NUMBER}\s*{UNIT}\b",
    # Standalone "<number> <unit>" not followed by a safe trading/ML word.
    # Catches "30 min", "1-2 hours", "2 days" while letting "15-minute bars",
    # "10-week SMA", "60-bar hold" through.
    rf"\b{NUMBER}\s*{UNIT}\b(?!\s+(?:{SAFE_FOLLOW})\b)",
]

COMPILED = [re.compile(p, flags=re.IGNORECASE) for p in ESTIMATE_PATTERNS]


def find_hits(text: str) -> list[str]:
    hits: list[str] = []
    for regex in COMPILED:
        for match in regex.finditer(text):
            hits.append(match.group(0).strip())
    # Preserve order, dedup
    return list(dict.fromkeys(hits))


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0
    if payload.get("stop_hook_active"):
        return 0
    msg = payload.get("last_assistant_message") or ""
    if not isinstance(msg, str) or not msg.strip():
        return 0
    hits = find_hits(msg)
    if not hits:
        return 0
    reason = (
        "BLOCKED: Your response contains time estimate(s): "
        + "; ".join(hits[:5])
        + ". Remove all durations (minutes, hours, days, ETAs, "
        '"half a day", etc.) and respond again without guessing '
        "how long work will take."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
