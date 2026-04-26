#!/bin/bash
# UserPromptSubmit hook: detect when the user is frustrated or correcting
# behavior and auto-append a generated rule to the appropriate target so
# the same assistant behavior cannot recur.
#
# Drafts the rule by shelling out to `claude -p` (Claude Code CLI in
# non-interactive print mode). No external API or router needed; uses
# whatever auth the local Claude Code install already has.
#
# Targets (resolved via apply_auto_rule.py):
#   check_stop_asking.py     -> append regex to STOP_PATTERNS list
#   check_time_estimates.py  -> append regex to ESTIMATE_PATTERNS list
#   CLAUDE.md                -> append rule_text as a bullet under
#                                "## Auto-added rules" in the nearest
#                                project CLAUDE.md
#
# Confidence threshold defaults to 0.6; override with FRUSTRATION_CONF_MIN.
# All outcomes are logged to ~/.claude/auto_rules.log.

set -euo pipefail

# Anti-recursion guard: if we're already inside a `claude -p` call
# spawned by this same hook, exit immediately. Without this, the
# DRAFT_PROMPT (which contains the word "frustrated") triggers the hook
# again in the child claude session -> infinite recursion.
if [[ -n "${DETECT_FRUSTRATION_ACTIVE:-}" ]]; then
    exit 0
fi

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [[ -z "$PROMPT" ]]; then exit 0; fi

# Length floor — skip trivially short prompts to avoid LLM call on
# "ok" / "thanks" / single-word continuations.
PROMPT_LEN=${#PROMPT}
if [[ $PROMPT_LEN -lt 20 ]]; then
    exit 0
fi

LAST_ASSISTANT=""
if [[ -f "$TRANSCRIPT" ]]; then
    LAST_ASSISTANT=$(tail -300 "$TRANSCRIPT" \
        | jq -r 'select((.message.role // .role // .type) == "assistant") | (.message.content // .content // empty)' 2>/dev/null \
        | tr '\n' ' ' \
        | tail -c 1500 || true)
fi

LOG="$HOME/.claude/auto_rules.log"
mkdir -p "$(dirname "$LOG")"

if ! command -v claude >/dev/null 2>&1; then
    echo "$(date '+%F %T') | NO_CLAUDE_CLI prompt=${PROMPT:0:200}" >> "$LOG"
    exit 0
fi

# The slow path (claude -p + apply_auto_rule.py) runs in a detached
# background subshell so the UserPromptSubmit hook returns in
# milliseconds instead of waiting on the LLM. The rule lands in the
# target file whenever claude -p finishes; the next prompt picks it up.
(
    export DETECT_FRUSTRATION_ACTIVE=1

    # Step 1: classify whether the user is actually frustrated /
    # correcting the assistant. Replaces the old regex pre-filter.
    CLASSIFY_PROMPT="Decide whether the user message below is expressing frustration with or correction of the assistant's recent behavior. Examples of YES: telling the assistant to stop doing something, complaining about a previous response, profanity directed at the assistant, 'I told you', 'why did you', 'that's not what I asked'. Examples of NO: a normal task request, a calm question, satisfaction, cursing at unrelated infrastructure, casual filler.

USER MESSAGE: $PROMPT

Reply with exactly one of these and nothing else:
YES
or
NO"

    VERDICT=$(claude -p "$CLASSIFY_PROMPT" 2>/dev/null | head -1 | tr -d '[:space:]' || true)

    if [[ "$VERDICT" != "YES" ]]; then
        echo "$(date '+%F %T') | NOT_FRUSTRATED verdict=${VERDICT:-empty}" >> "$LOG"
        exit 0
    fi

    # Step 2: draft the actual rule.
    DRAFT_PROMPT="You translate user frustration into a hook rule for the autohook-coding-agent-superpowers config. Respond ONLY with a JSON object on a single line, no prose, no markdown fence: {\"summary\":str,\"target\":\"check_stop_asking.py\"|\"check_time_estimates.py\"|\"CLAUDE.md\",\"regex\":str|null,\"rule_text\":str|null,\"confidence\":float}. Use a Python regex (no surrounding slashes) matching what the assistant said for Stop-hook patterns. Use rule_text for a one-line CLAUDE.md rule. Set confidence below 0.5 if the user's frustration is unrelated to assistant behavior (cursing at a build error, etc).

USER (frustrated): $PROMPT

PRIOR ASSISTANT TURN: $LAST_ASSISTANT"

    DRAFT=$(claude -p "$DRAFT_PROMPT" 2>/dev/null || true)

    if [[ -z "$DRAFT" ]]; then
        echo "$(date '+%F %T') | CLAUDE_NO_OUTPUT" >> "$LOG"
        exit 0
    fi

    DRAFT_CLEAN=$(echo "$DRAFT" | sed -E '/^```/d')

    CONFIDENCE=$(echo "$DRAFT_CLEAN" | jq -r '.confidence // 0' 2>/dev/null || echo "0")
    TARGET=$(echo "$DRAFT_CLEAN" | jq -r '.target // empty' 2>/dev/null || echo "")
    REGEX=$(echo "$DRAFT_CLEAN" | jq -r '.regex // empty' 2>/dev/null || echo "")
    RULE_TEXT=$(echo "$DRAFT_CLEAN" | jq -r '.rule_text // empty' 2>/dev/null || echo "")
    SUMMARY=$(echo "$DRAFT_CLEAN" | jq -r '.summary // empty' 2>/dev/null || echo "")

    THRESHOLD="${FRUSTRATION_CONF_MIN:-0.6}"
    KEEP=$(awk -v c="$CONFIDENCE" -v t="$THRESHOLD" 'BEGIN { print (c+0 >= t+0) ? "1" : "0" }')
    if [[ "$KEEP" != "1" ]]; then
        echo "$(date '+%F %T') | LOW_CONF conf=$CONFIDENCE thresh=$THRESHOLD target=$TARGET summary=$SUMMARY" >> "$LOG"
        exit 0
    fi

    HELPER="$HOME/.claude/hooks/apply_auto_rule.py"
    if [[ ! -f "$HELPER" ]]; then
        echo "$(date '+%F %T') | NO_HELPER target=$TARGET" >> "$LOG"
        exit 0
    fi

    ARGS=(--target "$TARGET" --summary "$SUMMARY" --cwd "$CWD")
    if [[ -n "$REGEX" && "$REGEX" != "null" ]]; then
        ARGS+=(--regex "$REGEX")
    fi
    if [[ -n "$RULE_TEXT" && "$RULE_TEXT" != "null" ]]; then
        ARGS+=(--rule-text "$RULE_TEXT")
    fi

    python3 "$HELPER" "${ARGS[@]}" >> "$LOG" 2>&1 || true
) </dev/null >/dev/null 2>&1 &
disown

echo "$(date '+%F %T') | DISPATCHED prompt=${PROMPT:0:120}" >> "$LOG"
exit 0
