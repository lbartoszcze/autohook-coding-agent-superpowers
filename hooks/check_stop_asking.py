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
    # === Describe-the-gap-but-don't-fill-it ===
    # The assistant identifies missing/unfinished work, declares it's not
    # done, or punts to a future redesign — without actually doing the
    # work. Different failure mode from asking-style or self-pause.
    # "I haven't implemented it yet" / "I have not done that"
    r"\bi\s+(haven'?t|have\s+not)\s+(yet\s+)?"
    r"(implemented|done|fixed|built|written|wired|added|finished|started|tackled|"
    r"addressed|made|created|rewritten|replaced|migrated|hooked\s+up|landed|coded|"
    r"set\s+(it|that|this|them)?\s*up)\b",
    # "is what should replace it" / "is what needs to land"
    r"\bis\s+what\s+(should|needs?\s+to|must)\s+"
    r"(replace|come|be|happen|land|ship|fix|resolve|address|do)\b",
    # "should be implemented" / "needs to be done" / "must be replaced"
    r"\b(should|needs?\s+to|must)\s+be\s+"
    r"(implemented|done|fixed|built|written|wired|added|finished|hooked\s+up|"
    r"landed|replaced|migrated|coded|tackled|rewritten|refactored|addressed)\b",
    # "the X redesign is what should..." / "the migration that needs to..."
    r"\b(redesign|refactor|rewrite|migration|implementation|fix|change|cleanup)"
    r"\s+(is|that)\s+(what\s+)?(should|needs\s+to|must)\b",
    # "today the system is exactly the wrong thing you flagged"
    r"\b(today|currently|right\s+now|as\s+of\s+now)\s+"
    r"(is|does|works|behaves|operates)\s+exactly\s+(like|the|how|what|that)\b",
    # "still <verb>s the broken thing" — acknowledging unfinished state
    r"\bstill\s+(uses|relies\s+on|behaves|works|treats|hits|calls|reads|writes|"
    r"triggers|runs|fires|defaults|breaks|misses|ignores|skips)\s+(the\s+|a\s+)?"
    r"(broken|wrong|old|original|previous|deprecated|stale|legacy|flawed|"
    r"outdated)\b",
    # === Status-report-then-stop ===
    # Long agent turns that end with a "what's done / what's left" recap
    # and stop, even when the listed-as-left work is within the agent's
    # capability. These complement the asking-style and self-pause sets.
    # Noun-first remaining: "problems remaining", "tasks remaining",
    # "issues outstanding", "bugs open", "tests failing".
    r"\b(problems?|issues?|bugs?|failures?|gaps?|tasks?|items?|tests?|fixes?|"
    r"changes?|trajectories|repos?|files?|tickets?|defects?)\s+"
    r"(remain|remains|remaining|outstanding|pending|left|to\s+go|"
    r"unfinished|open|still\s+open|still\s+failing)\b",
    # Adjective-first form expanded with new noun set.
    r"\b(remaining|outstanding|pending|leftover|unfinished|open|still)\s+"
    r"(problems?|issues?|bugs?|failures?|gaps?|fixes?|trajectories|repos?|"
    r"tickets?|defects?)\b",
    # "Continuing on X" / "Will continue with Y" / "Moving on to Z" —
    # declarative future-action that almost always precedes a stop.
    r"\b(continuing\s+(on|with)|will\s+continue\s+with|i'?ll?\s+continue\s+"
    r"(on|with)|moving\s+on\s+to|onto\s+the\s+next|switching\s+to\s+the\s+next)\b",
    # "Next: <verb>" — explicit colon-as-label deferral. Catches
    # "Next: apply the X pattern to Y" and friends. Verb list aligned with
    # describe-but-don't-do above.
    r"\bnext\s*:\s*(apply|run|do|fix|build|implement|wire|hook|add|change|"
    r"test|ship|deploy|migrate|refactor|rewrite|tackle|address|finish|"
    r"complete|land|handle|investigate|diagnose|trace|inspect|continue)\b",
    # "Goal: drive X to pass" + bullet list later — recap-style intro.
    # Matches the literal `※ recap:` and similar markers + "Progress
    # summary" headers that almost always precede a stop.
    r"^[\s>*\-•※]*\s*(recap|progress\s+summary|status\s+(update|report|so\s+far)|"
    r"current\s+state|state\s+of\s+(things|the\s+world|play))\s*[:\(]",
    # "Continuing on X." at end of turn — short-sentence deflection, often
    # the last thing before the agent stops.
    r"\b(continuing|continue|moving|moving\s+on|onto|on\s+to)\s+"
    r"(on\s+)?\w+(_\w+)?(\s*(/|,)\s*\w+(_\w+)?)*\s*\.?\s*$",
    # "1 task open" / "3 tests still failing" — declarative count of
    # unfinished work, used as a status-report sign-off.
    r"\b\d+\s+(task|item|issue|bug|problem|change|file|test|fix|trajectory|"
    r"trajectories|repo|repos)s?\s+(open|outstanding|remaining|left|to\s+go|"
    r"still\s+(open|failing|outstanding|pending))\b",
]

COMPILED = [re.compile(p, flags=re.IGNORECASE | re.MULTILINE)
            for p in STOP_PATTERNS]


def strip_code(text: str) -> str:
    """Remove fenced code blocks and inline code spans from the message
    before running the deflection patterns. Citing a pattern in
    backticks (e.g. `"continuing on"`) or showing it in a fenced block
    is meta-discussion, not a deflection. Without this, the hook fires
    on its own examples whenever the assistant edits or explains the
    hook itself."""
    # Strip ```...``` fenced blocks first (multi-line, non-greedy).
    text = re.sub(r"```[\s\S]*?```", "", text)
    # Strip `...` inline code spans (single-line, non-greedy).
    text = re.sub(r"`[^`\n]+`", "", text)
    return text


def find_hits(tail: str) -> list[str]:
    cleaned = strip_code(tail)
    hits: list[str] = []
    for regex in COMPILED:
        for match in regex.finditer(cleaned):
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
        + ". Pick the highest-value next task yourself and execute it."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
