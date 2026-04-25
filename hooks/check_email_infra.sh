#!/bin/bash
# PreToolUse hook: When Claude writes email provider workaround code,
# block it until email infrastructure has been diagnosed first.

set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
CONTENT=""

if [[ "$TOOL" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [[ "$TOOL" == "Edit" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

if [[ -z "$CONTENT" ]]; then exit 0; fi

# Detect email workaround patterns — creating new email provider signup code
WORKAROUND_PATTERNS='_create_tuta|_create_gmail|_create_yahoo|_create_outlook|_create_mailcom|_create_protonmail|_create_hotmail|alternative.email.provider|email.workaround|email.provider.signup'

if echo "$CONTENT" | grep -qiE "$WORKAROUND_PATTERNS"; then
    # Check if infra was verified recently (< 1 hour)
    STAMP="$HOME/.claude/.email_infra_checked"
    if [[ -f "$STAMP" ]]; then
        STAMP_AGE=$(( $(date +%s) - $(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
        if [[ "$STAMP_AGE" -lt 3600 ]]; then
            exit 0
        fi
    fi

    echo "BLOCKED: You are writing email provider workaround code." >&2
    echo "" >&2
    echo "STOP. Before building workarounds, diagnose the actual email infrastructure:" >&2
    echo "  Run: ~/.claude/hooks/diagnose_email.sh <domain>" >&2
    echo "" >&2
    echo "After diagnosing and fixing any issues:" >&2
    echo "  Run: touch ~/.claude/.email_infra_checked" >&2
    exit 2
fi

exit 0
