#!/bin/bash
# UserPromptSubmit hook: detect when the user is frustrated or correcting
# behavior and auto-append a generated rule to the appropriate target so
# the same assistant behavior cannot recur.
#
# Targets (resolved via apply_auto_rule.py):
#   check_stop_asking.py     -> append regex to STOP_PATTERNS list
#   check_time_estimates.py  -> append regex to ESTIMATE_PATTERNS list
#   CLAUDE.md                -> append rule_text as a bullet under
#                                "## Auto-added rules" in the nearest
#                                project CLAUDE.md
#
# Confidence threshold defaults to 0.6; override with FRUSTRATION_CONF_MIN.
# All outcomes (applied / low confidence / no router / parse failure)
# are logged to ~/.claude/auto_rules.log so you can audit and revert.

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [[ -z "$PROMPT" ]]; then exit 0; fi

FRUSTRATION='\b(stop\s+(doing|using|saying|writing|asking|making|with)|don.?t\s+(do|ever|use|say|write|ask|tell)|never\s+(do|use|say|write|again)|i\s+(hate|dislike|don.?t\s+want|told\s+you|already\s+told)|ugh|wtf|jesus\s+christ|for\s+the\s+love|come\s+on|cmon|how\s+many\s+times|annoying|frustrat|infuriat|the\s+fuck|fucking\s|bullshit|why\s+(are|did|would|do)\s+you|that.?s\s+not\s+what|i\s+didn.?t\s+ask|not\s+what\s+i\s+(asked|wanted)|stop\s+asking|hate\s+(when|that|it|how))\b'

if ! echo "$PROMPT" | grep -qiE "$FRUSTRATION"; then
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

ROUTER="${MODEL_ROUTER_URL:-}"
if [[ -z "$ROUTER" ]]; then
    echo "$(date '+%F %T') | NO_ROUTER prompt=${PROMPT:0:200}" >> "$LOG"
    exit 0
fi

SYSTEM_PROMPT='You translate user frustration into a hook rule. Respond ONLY with a JSON object: {"summary":str,"target":"check_stop_asking.py"|"check_time_estimates.py"|"CLAUDE.md","regex":str|null,"rule_text":str|null,"confidence":float}. Use a Python regex (no surrounding slashes) matching what the assistant said for Stop-hook patterns. Use rule_text for a one-line CLAUDE.md rule. Set confidence below 0.5 if the frustration is unrelated to assistant behavior.'

REQ=$(jq -nc \
    --arg sys "$SYSTEM_PROMPT" \
    --arg user "$PROMPT" \
    --arg asst "$LAST_ASSISTANT" \
    '{model:"claude-sonnet-4-6",max_tokens:400,messages:[{role:"system",content:$sys},{role:"user",content:("USER (frustrated): "+$user+"\n\nPRIOR ASSISTANT TURN: "+$asst)}]}')

DRAFT=$(curl -sS "$ROUTER/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$REQ" 2>/dev/null \
    | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)

if [[ -z "$DRAFT" ]]; then
    echo "$(date '+%F %T') | ROUTER_NO_OUTPUT" >> "$LOG"
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

exit 0
