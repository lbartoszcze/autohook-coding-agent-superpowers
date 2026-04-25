#!/usr/bin/env python3
"""Stop hook: reject assistant turns that end with a 'what next?' style
ask-the-user question when there is obviously more work to do.

Reads the Claude Code Stop-hook JSON from stdin, extracts
`last_assistant_message`, looks at the last ~1000 characters (where the
'should I continue?' phrasing tends to live), and blocks the turn if it
contains a pattern that signals premature hand-off.

Whitelists genuine disambiguation questions ("which file did you mean?",
"did you want the dark or light theme?") by only flagging forward-momentum
asks — questions that could be answered by just picking and executing.
"""
from __future__ import annotations

import json
import re
import sys


TAIL_CHARS = 1200

# End-of-turn phrases that signal "I stopped — tell me what to do next".
# These are all patterns the user has explicitly called out as wasteful.
STOP_PATTERNS = [
    # Direct "want me to X" asks
    r"\bwant me to\b[^.?!]*\?",
    r"\bshould i\b[^.?!]*\?",
    r"\bwould you like me to\b[^.?!]*\?",
    r"\bdo you want me to\b[^.?!]*\?",
    r"\bshall i\b[^.?!]*\?",
    # "Which X — A or B or C?" style multi-option asks
    r"\bwhich (one|of these|option|should i|do you want|would you)\b",
    r"\b(a|b|c)\s*[\)\.]\s*\w+\s+\b(or|vs\.?)\b",
    # "Pick one", "tell me"
    r"\btell me (which|if|what|whether)\b",
    r"\blet me know (if|which|whether|what|when)\b",
    r"\bpick (one|whichever|which)\b",
    # "Up next" style teasers
    r"\b(next up|up next|coming next|what['']s next)\b[^.]*\?",
    r"\b(or|alternatively)[,]?\s+(should|would|do|could) (you|i|we)\b",
    r"\bhow (do you|would you) want\b",
    # "Ready to continue?"
    r"\bready to (continue|proceed|move on|ship|deploy)\b[^.]*\?",
    # Three-option / listing and then asking
    r"\b(options?|paths?|approaches?|ways?)[^.]*:\s*\n(?:.|\n){0,500}\?\s*$",
    # "Remaining steps for you", "Here's what's left", "To make it live"
    r"\b(remaining|outstanding|pending|leftover|next)\s+(steps?|work|items?|tasks?|action\s+items?|todo|to\s+ship|to\s+deploy|to\s+make)\b",
    r"\bleft\s+(to\s+(do|ship|deploy|apply|run)|for\s+you)\b",
    r"\bto\s+(make|ship|get)\s+(it|this|that|the\s+\w+)\s+(live|going|working|deployed|running)\b",
    r"\bwhat'?s?\s+(left|remaining|still\s+(needed|to\s+do|pending))\b",
    r"\b(you|you'?ll?|you\s+(need|have|should|must)\s+to|your\s+turn\s+to)\s+(need|have|should|must|take|do|apply|run|deploy|push|configure|wire|enable|set|trigger|kick|start|create|add|handoff|hand\s+off)\b",
    r"\b(handing|handoff|hand\s+off|over\s+to\s+you|your\s+(job|task|responsibility|action))\b",
    # Numbered "for you to do" lists
    r"^\s*\d+[\).]\s+.*\b(apply|run|deploy|push|configure|set|trigger|enable|install|provision|grant)\b[^.]*$",
    # "Now you…" / "Time for you to…"
    r"\b(now\s+you|time\s+(for\s+you|to\s+hand)|over\s+to\s+you)\b",
    # "Deploy steps (your action)" style section headers
    r"\b(your\s+action|your\s+call|your\s+decision|your\s+move|user\s+action)\s*[\):]",
    # Self-declared pauses: "I'll pause", "I'll stop", "stopping here", "let me stop".
    # These are premature hand-offs — the model is voluntarily ending the turn
    # instead of executing the next obvious task.
    r"\b(i'?ll?|let me|i'?m going to|going to|i'?ve decided to)\s+(pause|stop|hold|wait|checkpoint|hand\s*off|yield)\b",
    r"\b(stopping|pausing|halting|checkpointing|holding)\s+(here|now|for\s+(now|a\s+moment|your|the))\b",
    r"\bpause\s+(here|before|until|on)\b",
    # Deferral to a later session / turn.
    r"\b(next|future|another|a\s+later|a\s+follow[- ]?up)\s+(session|turn|pass|iteration|round|sitting)\b",
    r"\b(follow[- ]?up|later)\s+(work|task|pass|step|session)\b",
    r"\bpick\s+(any|one|whichever|which|them|these|those)\s+(of\s+(them|these|those)\s+)?up\s+(next|later|in\s+a|in\s+the|after)\b",
    r"\b(we|i)\s+can\s+(resume|continue|pick\s+(it|them|this|that|these|those)\s+up|come\s+back)\s+(later|next|in\s+a|in\s+the|after|tomorrow|when)\b",
    r"\b(rest\s+of\s+(the\s+)?(plan|work|tasks?|items?|assistants?|build))\s+(can|will|should|is)\s+(come|be|wait|go)\b",
    # Waiting-for-review / green-light / eyeball language (not the same as a
    # genuine authorization ask — these are "I'm stopping until you look").
    r"\b(before|until|so|while)\s+you('?ve?|r)?\s+(look(ed)?|review(ed)?|check(ed)?|see|read|eyeball(ed)?|approve|confirm|decide|weigh\s+in|glance|sanity[- ]?check)\b",
    r"\b(needs?|need|want(ing)?|waiting\s+for|pending)\s+your\s+(green\s+light|go[- ]?ahead|sign[- ]?off|approval|ok|okay|thumbs?[- ]?up|blessing|eyes|review)\b",
    r"\b(your|user)\s+(green\s+light|go[- ]?ahead|sign[- ]?off|thumbs?[- ]?up|blessing)\b",
    r"\b(worth|warrant(s|ing)?|deserve(s|ing)?)\s+(eyeballing|your\s+review|a\s+look|checking)\b",
    r"\bbefore\s+(the\s+pattern|this|that|we)\s+(gets?|is|gets\s+copied)\b",
    # "Checkpoint here" / "status check" endings.
    r"\b(checkpoint|status\s+(check|update|report))\s+(here|now|before|for)\b",
    r"\bstopping\s+(here|there|at\s+this\s+point)\s+for\b",
    # "Phases 2–5 remain" / "Phase 2 remains" / "Tasks X through Y remain"
    # — declarative enumerations of work left undone. Bare "remaining"/"outstanding"
    # is too English-common; only flag when paired with a work-item noun.
    r"\b(phases?|steps?|tasks?|items?|stages?|commits?|pieces?|prs?|pull\s+requests?|changes?|parts?|milestones?)"
    r"\s+[\d\w\-–—,\s]{0,40}\s*\b(remain|remains|remaining|outstanding|pending|left|to\s+go)\b",
    r"\b(remain(ing|s)?|outstanding|pending|leftover|unfinished)"
    r"\s+(phases?|steps?|tasks?|items?|stages?|commits?|work|pieces?|prs?|pull\s+requests?|changes?|parts?|milestones?)\b",
    # "when you're ready" / "when you give the go" — deferral disguised as patience.
    r"\bwhen\s+you'?re?\s+(ready|good|set)\b",
    r"\bwhen\s+you\s+(give|say|want|decide|confirm|approve|feel)\b",
    # "Each is a discrete commit" / "each forms its own PR" — enumerating
    # independent units the user is expected to pick up.
    r"\beach\s+[\w'\-\s]{0,30}?\b(is|forms?|becomes?|makes?|represents?|maps?\s+to)\s+"
    r"(a\s+|its?\s+own\s+)?(discrete|separate|independent|standalone|own|its?\s+own|distinct)\s*"
    r"(commit|change|pr|pull\s+request|step|task|release|phase|chunk|piece|unit)s?\b",
    # "Let me know when to" — deferral via explicit "tell me"
    r"\blet\s+me\s+know\s+when\s+to\b",
]

COMPILED = [re.compile(p, flags=re.IGNORECASE | re.MULTILINE)
            for p in STOP_PATTERNS]


def find_hits(tail: str) -> list[str]:
    hits: list[str] = []
    for regex in COMPILED:
        for match in regex.finditer(tail):
            hits.append(match.group(0).strip())
    seen: dict[str, None] = {}
    for h in hits:
        seen.setdefault(h, None)
    return list(seen.keys())


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return 0
    if payload.get("stop_hook_active"):
        return 0
    msg = payload.get("last_assistant_message") or ""
    if not isinstance(msg, str):
        return 0
    stripped = msg.strip()
    if not stripped:
        return 0
    # Only look at the tail — 'should I continue?' lives at the end of turns.
    tail = stripped[-TAIL_CHARS:] if len(stripped) > TAIL_CHARS else stripped
    hits = find_hits(tail)
    if not hits:
        return 0
    reason = (
        "BLOCKED: You stopped to ask the user what to do next instead of continuing. "
        "Flagged phrase(s): "
        + "; ".join(hits[:3])
        + ". Pick the highest-value next task yourself and execute it. "
        "Only stop when the work is genuinely complete or when the next step "
        "requires information you cannot obtain (secrets, credentials, a "
        "decision only the user can make, or an action that affects something "
        "outside the local filesystem and must be explicitly authorized)."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
