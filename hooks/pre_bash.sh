#!/bin/bash
# Consolidated PreToolUse hook for Bash (device-wide)
# Combines: no-inline-scripts, wisent command validation

set -euo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [[ -z "$CMD" ]]; then exit 0; fi

# === Block writing to to_check folders ===
if echo "$CMD" | grep -qiE '(>|cp |mv |tee ).*/to_check/'; then
    echo "BLOCKED: NEVER write to to_check folders. These contain user-prepared files." >&2
    exit 2
fi

# === Block inline script execution ===
if echo "$CMD" | grep -qE '(^|[;&|] *)(sh|bash|zsh|dash) +-c '; then
    echo "BLOCKED: No inline shell scripts (sh -c, bash -c). Write a script file instead." >&2
    exit 2
fi
if echo "$CMD" | grep -qE 'python[0-9.]?\s+(-c|--command)'; then
    echo "BLOCKED: No inline python scripts (python -c). Write a .py file instead." >&2
    exit 2
fi
if echo "$CMD" | grep -qE 'python[0-9.]?\s+<<'; then
    echo "BLOCKED: No inline python heredoc. Write a .py file instead." >&2
    exit 2
fi
if echo "$CMD" | grep -qE '(^|[;&|] *)(node|npx) +(-e|--eval|-p|--print)'; then
    echo "BLOCKED: No inline node scripts (node -e). Write a .js file instead." >&2
    exit 2
fi
if echo "$CMD" | grep -qE '(^|[;&|] *)(ruby|perl) +(-e|--execute)'; then
    echo "BLOCKED: No inline ruby/perl scripts. Write a script file instead." >&2
    exit 2
fi

# === Block file modification circumvention ===
# Prevent running Python scripts that patch/modify large files (circumvents 300-line Edit hook)
if echo "$CMD" | grep -qE 'python[0-9.]*\s+(docs/patches|fix_|patch_)'; then
    echo "BLOCKED: Do not run patch scripts that modify large files. Refactor into smaller modules instead." >&2
    exit 2
fi
# Prevent sed/awk file modifications via gcloud SSH or docker exec
if echo "$CMD" | grep -qE 'gcloud.*ssh.*--(command|ssh-flag).*\bsed\b.*-i'; then
    echo "BLOCKED: No remote sed -i via gcloud SSH. Edit source files locally and redeploy." >&2
    exit 2
fi
if echo "$CMD" | grep -qE 'docker (exec|cp).*\.(py|sh)\b'; then
    echo "BLOCKED: No copying/running scripts inside Docker containers to modify code. Edit source files locally and redeploy." >&2
    exit 2
fi
if echo "$CMD" | grep -qE 'gcloud.*ssh.*python3?\s'; then
    echo "BLOCKED: No running Python remotely via gcloud SSH. Edit source files locally and redeploy." >&2
    exit 2
fi

# === Block direct Anthropic API usage ===
# Wisent has its own LLM router (github.com/wisent-ai/model-router) exposing
# an OpenAI-compatible /v1/chat/completions endpoint. Route through
# MODEL_ROUTER_URL instead of calling Anthropic directly.
if echo "$CMD" | grep -qE 'ANTHROPIC_API_KEY|@anthropic-ai/sdk|api\.anthropic\.com'; then
    echo "BLOCKED: Do not use ANTHROPIC_API_KEY or api.anthropic.com directly." >&2
    echo "" >&2
    echo "Wisent runs its own LLM router — github.com/wisent-ai/model-router" >&2
    echo "(local checkout: ~/Documents/CodingProjects/Wisent/model-router/)." >&2
    echo "" >&2
    echo "Call \$MODEL_ROUTER_URL/v1/chat/completions (OpenAI-compatible) instead." >&2
    exit 2
fi

# === Wisent CLI override flags ===
if echo "$CMD" | grep -qE '(^|\s)wisent\s'; then
    FORBIDDEN_FLAGS="--limit|--max-pairs|--max-samples|--num-samples|--batch-size|--max-iterations|--n-pairs|--sample-size|--subset|--quick|--fast|--test-mode|--debug-limit"
    if echo "$CMD" | grep -qE "(^|\s)(${FORBIDDEN_FLAGS})(\s|=|$)"; then
        MATCHED=$(echo "$CMD" | grep -oE "(${FORBIDDEN_FLAGS})" | head -1)
        echo "BLOCKED: Override flag '${MATCHED}' is forbidden in wisent commands. Use default parameters." >&2
        exit 2
    fi
    if echo "$CMD" | grep -qE '\s-n\s+[0-9]+'; then
        echo "BLOCKED: '-n <number>' flag is forbidden in wisent commands." >&2
        exit 2
    fi
fi

exit 0
