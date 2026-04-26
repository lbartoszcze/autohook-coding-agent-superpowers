#!/bin/bash
# UserPromptSubmit hook: detect when the user is frustrated or correcting
# behavior, and stage a proposed rule into ~/.claude/proposed_rules.md
# for manual review.
#
# Does NOT block prompts. Does NOT auto-modify live hooks or settings.
# It only appends a markdown block describing the signal and (when
# MODEL_ROUTER_URL is set) a candidate regex or CLAUDE.md rule for the
# user to inspect. Review the file periodically and copy useful rules
# into check_stop_asking.py / check_time_estimates.py / your CLAUDE.md
# by hand.
#
# Why no auto-append: an LLM-drafted regex that lands directly in a
# live Stop hook can block legitimate work, which produces more
# frustration, which produces more bad auto-rules. The review file
# breaks that loop.

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

if [[ -z "$PROMPT" ]]; then exit 0; fi

# Frustration / correction patterns. Over-capture on purpose; the LLM
# call below is the filter (it scores confidence and you only act on
# proposals you actually agree with).
FRUSTRATION='\b(stop\s+(doing|using|saying|writing|asking|making|with)|don.?t\s+(do|ever|use|say|write|ask|tell)|never\s+(do|use|say|write|again)|i\s+(hate|dislike|don.?t\s+want|told\s+you|already\s+told)|ugh|wtf|jesus\s+christ|for\s+the\s+love|come\s+on|cmon|how\s+many\s+times|annoying|frustrat|infuriat|the\s+fuck|fucking\s|bullshit|why\s+(are|did|would|do)\s+you|that.?s\s+not\s+what|i\s+didn.?t\s+ask|not\s+what\s+i\s+(asked|wanted)|stop\s+asking|hate\s+(when|that|it|how))\b'

if ! echo "$PROMPT" | grep -qiE "$FRUSTRATION"; then
    exit 0
fi

# Pull the last assistant message out of the transcript JSONL so the
# drafted rule can be grounded in the specific behavior that triggered
# the frustration.
LAST_ASSISTANT=""
if [[ -f "$TRANSCRIPT" ]]; then
    LAST_ASSISTANT=$(tail -300 "$TRANSCRIPT" \
        | jq -r 'select((.message.role // .role // .type) == "assistant") | (.message.content // .content // empty)' 2>/dev/null \
        | tr '\n' ' ' \
        | tail -c 1500 || true)
fi

PROPOSED="$HOME/.claude/proposed_rules.md"
TS=$(date '+%Y-%m-%d %H:%M:%S')
ROUTER="${MODEL_ROUTER_URL:-}"
DRAFT=""

if [[ -n "$ROUTER" ]]; then
    SYSTEM_PROMPT='You translate user frustration into a hook rule. Respond ONLY with a JSON object: {"summary":str,"target":"check_stop_asking.py"|"check_time_estimates.py"|"pre_bash.sh"|"pre_write_edit.sh"|"CLAUDE.md","regex":str|null,"rule_text":str|null,"confidence":float}. Use regex for Stop-hook patterns matching what the assistant said. Use rule_text for CLAUDE.md guidance. Set confidence below 0.5 if the frustration is unrelated to assistant behavior (e.g. the user is just cursing at a build error).'
    REQ=$(jq -nc \
        --arg sys "$SYSTEM_PROMPT" \
        --arg user "$PROMPT" \
        --arg asst "$LAST_ASSISTANT" \
        '{model:"claude-sonnet-4-6",max_tokens:400,messages:[{role:"system",content:$sys},{role:"user",content:("USER (frustrated): "+$user+"\n\nPRIOR ASSISTANT TURN: "+$asst)}]}')
    DRAFT=$(curl -sS --max-time 8 "$ROUTER/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$REQ" 2>/dev/null \
        | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
fi

{
    echo ""
    echo "---"
    echo ""
    echo "## $TS"
    echo ""
    echo "**User message:**"
    echo ""
    echo "> $(echo "$PROMPT" | head -c 600 | tr '\n' ' ')"
    echo ""
    if [[ -n "$LAST_ASSISTANT" ]]; then
        echo "**Prior assistant turn (excerpt):**"
        echo ""
        echo "> $(echo "$LAST_ASSISTANT" | head -c 600 | tr '\n' ' ')"
        echo ""
    fi
    if [[ -n "$DRAFT" ]]; then
        echo "**Drafted rule (review before applying):**"
        echo ""
        echo '```json'
        echo "$DRAFT"
        echo '```'
    else
        echo "_No router output (MODEL_ROUTER_URL unset or unreachable). Raw signal recorded; refine the rule by hand._"
    fi
    echo ""
} >> "$PROPOSED"

exit 0
