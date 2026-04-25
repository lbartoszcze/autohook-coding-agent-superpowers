#!/bin/bash
# Consolidated PreToolUse hook for Write|Edit (device-wide)
# Combines: max-file-lines, max-folder-files, no-timeouts, forbidden patterns,
#           justification checks, replication manifest, tmp directory block

set -euo pipefail

# Use system wc to avoid conda's wc shadowing
WC_CMD=/usr/bin/wc

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]]; then exit 0; fi

# === Block tmp/var directories ===
if echo "$FILE_PATH" | grep -qiE '(/tmp/|/var/folders/)'; then
    echo "BLOCKED: Writing to tmp directory is not allowed" >&2
    exit 2
fi

# === Block user's to_check folders — NEVER overwrite user-prepared files ===
if echo "$FILE_PATH" | grep -qiE '/to_check/'; then
    echo "BLOCKED: NEVER write to to_check folders. These contain user-prepared files. Only read and review them." >&2
    exit 2
fi

# === Skip system directories for content checks ===
IS_SYSTEM=false
if echo "$FILE_PATH" | grep -qE '(node_modules|\.git/|\.next|__pycache__|/\.claude/|/chromium-build/)'; then
    IS_SYSTEM=true
fi

# === Extract content ===
CONTENT=""
if [[ "$TOOL" == "Write" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [[ "$TOOL" == "Edit" ]]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

# === Max file lines (300) ===
if [[ "$IS_SYSTEM" == "false" ]]; then
    if [[ "$TOOL" == "Write" && -n "$CONTENT" ]]; then
        LINES=$(echo "$CONTENT" | $WC_CMD -l | tr -d ' ')
        if [[ "$LINES" -gt 300 ]]; then
            echo "BLOCKED: File would be $LINES lines (max 300). Split into smaller modules." >&2
            exit 2
        fi
    fi
    if [[ "$TOOL" == "Edit" && -f "$FILE_PATH" ]]; then
        CURRENT_LINES=$($WC_CMD -l < "$FILE_PATH" | tr -d ' ')
        OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
        NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
        OLD_LINES=$(echo "$OLD_STRING" | $WC_CMD -l | tr -d ' ')
        NEW_LINES=$(echo "$NEW_STRING" | $WC_CMD -l | tr -d ' ')
        RESULT_LINES=$((CURRENT_LINES - OLD_LINES + NEW_LINES))
        if [[ "$RESULT_LINES" -gt 300 ]]; then
            echo "BLOCKED: File would be ~$RESULT_LINES lines after edit (max 300). Split into smaller modules." >&2
            exit 2
        fi
    fi
fi

# === Max folder files (5) — only for NEW files ===
if [[ "$IS_SYSTEM" == "false" && ! -f "$FILE_PATH" ]]; then
    DIR=$(dirname "$FILE_PATH")
    # Exempt special directories
    case "$DIR" in
        */supabase/migrations*|*/node_modules/*|*/.git/*|*/__pycache__/*|*/tests*|*/migrations*)
            ;;
        *)
            if [[ -d "$DIR" ]]; then
                FILE_COUNT=$(find "$DIR" -maxdepth 1 -type f 2>/dev/null | $WC_CMD -l | tr -d ' ')
                if [[ "$FILE_COUNT" -ge 5 ]]; then
                    echo "BLOCKED: Folder '$DIR' already has $FILE_COUNT files (max 5). Move files into sub-folders or consolidate." >&2
                    exit 2
                fi
            fi
            ;;
    esac
fi

# === Forbidden content patterns ===
if [[ -n "$CONTENT" && "$IS_SYSTEM" == "false" ]]; then
    if echo "$CONTENT" | grep -qiE '(fallback|keyword-based)'; then
        echo "BLOCKED: Forbidden pattern (fallback/keyword-based)" >&2
        exit 2
    fi
    # Do not call Anthropic's API directly. Wisent has its own LLM routing
    # infrastructure — github.com/wisent-ai/model-router — that exposes an
    # OpenAI-compatible /v1/chat/completions endpoint and dispatches to the
    # right provider (self-hosted Cydonia/Qwen on GCP, or a cloud fallback
    # when needed). Route through MODEL_ROUTER_URL instead of burning
    # Anthropic credits with a direct SDK call.
    if echo "$CONTENT" | grep -qE 'ANTHROPIC_API_KEY|@anthropic-ai/sdk|import[[:space:]]+Anthropic[[:space:]]+from|new[[:space:]]+Anthropic[[:space:]]*\('; then
        echo "BLOCKED: Do not use ANTHROPIC_API_KEY or the @anthropic-ai/sdk directly." >&2
        echo "" >&2
        echo "Wisent runs its own LLM router — github.com/wisent-ai/model-router" >&2
        echo "(local checkout: ~/Documents/CodingProjects/Wisent/model-router/)." >&2
        echo "" >&2
        echo "It exposes an OpenAI-compatible endpoint at \$MODEL_ROUTER_URL/v1/chat/completions" >&2
        echo "and dispatches to self-hosted Cydonia/Qwen on GCP or a cloud provider as configured." >&2
        echo "" >&2
        echo "Call that endpoint with fetch() or the 'openai' SDK pointed at \$MODEL_ROUTER_URL," >&2
        echo "not the Anthropic SDK." >&2
        exit 2
    fi
fi

# === No timeouts ===
if [[ -n "$CONTENT" ]]; then
    # Skip .claude directory
    if [[ "$FILE_PATH" != *"/.claude/"* ]]; then
        # asyncio.wait_for
        if echo "$CONTENT" | grep -qE 'asyncio\.wait_for\s*\('; then
            echo "BLOCKED: No timeouts. Do not use asyncio.wait_for(). Let tasks run to completion." >&2
            exit 2
        fi
        # asyncio.timeout
        if echo "$CONTENT" | grep -qE 'asyncio\.timeout\s*\('; then
            echo "BLOCKED: No timeouts. Do not use asyncio.timeout()." >&2
            exit 2
        fi
        # signal.alarm
        if echo "$CONTENT" | grep -qE 'signal\.alarm\s*\('; then
            echo "BLOCKED: No timeouts. Do not use signal.alarm()." >&2
            exit 2
        fi
        # AbortSignal.timeout
        if echo "$CONTENT" | grep -qE 'AbortSignal\.timeout\s*\('; then
            echo "BLOCKED: No timeouts. Do not use AbortSignal.timeout()." >&2
            exit 2
        fi
        # timeout= parameters (allow HTTP clients and Playwright navigation)
        if echo "$CONTENT" | grep -qE 'timeout\s*=\s*[0-9]'; then
            TIMEOUT_LINES=$(echo "$CONTENT" | grep -E 'timeout\s*=\s*[0-9]')
            UNSAFE_LINES=$(echo "$TIMEOUT_LINES" | grep -vE '(httpx|AsyncClient|requests\.|\.get\(|\.post\(|fetch|mcpServers|goto\(|wait_until|timeout=30000|timeout=60000|timeout=120000)' || true)
            if [[ -n "$UNSAFE_LINES" ]]; then
                echo "BLOCKED: Do not modify timeout values. Found: $(echo "$UNSAFE_LINES" | head -1 | xargs)" >&2
                exit 2
            fi
        fi
        # timeout: in JS/JSON (allow HTTP and mcpServers)
        if echo "$CONTENT" | grep -qE 'timeout\s*:\s*[0-9]'; then
            TIMEOUT_LINES=$(echo "$CONTENT" | grep -E 'timeout\s*:\s*[0-9]')
            UNSAFE_LINES=$(echo "$TIMEOUT_LINES" | grep -vE '(fetch|http|request|mcpServers|axios|\.get|\.post|navigation)' || true)
            if [[ -n "$UNSAFE_LINES" ]]; then
                echo "BLOCKED: Do not modify timeout values. Found: $(echo "$UNSAFE_LINES" | head -1 | xargs)" >&2
                exit 2
            fi
        fi
        # setTimeout used to kill tasks
        if echo "$CONTENT" | grep -qE 'setTimeout.*(abort|cancel|kill|reject|throw|clearInterval)'; then
            echo "BLOCKED: No timeouts. Do not use setTimeout to kill/abort tasks." >&2
            exit 2
        fi
        # Time limit patterns
        if echo "$CONTENT" | grep -qiE '\btime_limit\b|\btimelimit\b|\bmax_time\b|\bmaxtime\b'; then
            echo "BLOCKED: Content contains time limit pattern." >&2
            exit 2
        fi
        # *_timeout patterns
        if echo "$CONTENT" | grep -qiE 'statement_time.*out|connect_time.*out|read_time.*out|write_time.*out|socket_time.*out|request_time.*out|query_time.*out|lock_time.*out|idle_time.*out|poll_time.*out|wait_time.*out|connection_time.*out'; then
            echo "BLOCKED: Content contains time-limiting pattern." >&2
            exit 2
        fi
    fi
fi

# === New file justification (50+ words in ~/.claude/file_justifications.json) ===
if [[ ! -f "$FILE_PATH" && "$IS_SYSTEM" == "false" ]]; then
    REGISTRY="$HOME/.claude/file_justifications.json"
    if [[ -f "$REGISTRY" ]]; then
        JUST=$(jq -r --arg p "$FILE_PATH" '.[$p].justification // empty' "$REGISTRY" 2>/dev/null)
        WC=$(echo "$JUST" | $WC_CMD -w | tr -d ' ')
        if [[ -z "$JUST" || "$WC" -lt 50 ]]; then
            echo "BLOCKED: Need 50+ word justification in ~/.claude/file_justifications.json for new file: $FILE_PATH" >&2
            exit 2
        fi
    else
        echo "BLOCKED: Need 50+ word justification in ~/.claude/file_justifications.json for new file: $FILE_PATH" >&2
        exit 2
    fi
fi

# === Replication manifest for cloud scripts ===
if echo "$FILE_PATH" | grep -qiE '(gcp_images|/gcp/|_gcp\.|/ami/|_ami\.)'; then
    if echo "$FILE_PATH" | grep -qE '\.(sh|py)$'; then
        # Find project root
        PROJECT_ROOT=$(dirname "$FILE_PATH")
        while [[ "$PROJECT_ROOT" != "/" ]]; do
            if [[ -f "$PROJECT_ROOT/CLAUDE.md" || -d "$PROJECT_ROOT/.git" ]]; then break; fi
            PROJECT_ROOT=$(dirname "$PROJECT_ROOT")
        done
        MANIFEST_FILE="$PROJECT_ROOT/.claude/replication_manifest.json"
        if [[ ! -f "$MANIFEST_FILE" ]]; then
            echo "BLOCKED: No replication manifest at $MANIFEST_FILE. Create one before editing cloud scripts." >&2
            exit 2
        fi
        TARGET_ENTRY=$(jq -r --arg target "$FILE_PATH" '.replications[] | select(.target_file == $target)' "$MANIFEST_FILE" 2>/dev/null)
        if [[ -z "$TARGET_ENTRY" || "$TARGET_ENTRY" == "null" ]]; then
            echo "BLOCKED: No replication entry for $FILE_PATH in $MANIFEST_FILE" >&2
            exit 2
        fi
        for field in source_read_confirmed is_1_to_1 verified_working_locally; do
            val=$(echo "$TARGET_ENTRY" | jq -r ".$field")
            if [[ "$val" != "true" ]]; then
                echo "BLOCKED: '$field' is not true in manifest for $FILE_PATH" >&2
                exit 2
            fi
        done
        deps_ok=$(echo "$TARGET_ENTRY" | jq -r '.source_dependencies.all_dependencies_verified')
        if [[ "$deps_ok" != "true" ]]; then
            echo "BLOCKED: Dependencies not verified in manifest for $FILE_PATH" >&2
            exit 2
        fi
        prohibited=$(echo "$TARGET_ENTRY" | jq -r '.prohibited_differences | length')
        if [[ "$prohibited" -gt 0 ]]; then
            echo "BLOCKED: Prohibited differences exist in manifest for $FILE_PATH" >&2
            exit 2
        fi
    fi
fi

# === Weles project: enforce shared module usage ===
if echo "$FILE_PATH" | grep -qE '/weles/src/' && [[ -n "$CONTENT" && "$IS_SYSTEM" == "false" ]]; then
    REGISTRY="$HOME/.claude/file_justifications.json"
    check_shared_module() {
        local MODULE_NAME="$1" PATTERN="$2" MSG="$3" KEY="${4}"
        if echo "$CONTENT" | grep -qE "$PATTERN"; then
            local JUST=""
            if [[ -f "$REGISTRY" ]]; then
                JUST=$(jq -r --arg p "$FILE_PATH" --arg k "$KEY" '.[$p][$k] // empty' "$REGISTRY" 2>/dev/null)
            fi
            local WC=$(echo "$JUST" | $WC_CMD -w | tr -d ' ')
            if [[ -z "$JUST" || "$WC" -lt 50 ]]; then
                echo "BLOCKED: $MSG Add a 50+ word '$KEY' field to ~/.claude/file_justifications.json for $FILE_PATH explaining: (1) whether the shared module is used, (2) if not, why not, (3) confirm no code is duplicated." >&2
                exit 2
            fi
        fi
    }

    # 1. Capture module (src/capture/capture.ts) — screenshots, DOM dumps, console logs, network, video diagnosis
    check_shared_module "Capture" \
        'console\.log.*\[|writeFileSync.*(recording|vision|capture|diagnostic)' \
        "This code adds diagnostic logging. Use the shared Capture module at src/capture/capture.ts (screenshot, captureDom, captureEnvironment, diagnose, save)." \
        "diagnostics_justification"

    # 2. Vision module (src/vision/analyze.ts) — askPage(), findClickTarget(), checkPage()
    check_shared_module "Vision" \
        "spawnSync.*claude.*-p|claude.*--output-format" \
        "This code calls Claude CLI directly. Use the shared Vision module at src/vision/analyze.ts (askPage, findClickTarget, checkPage)." \
        "vision_justification"

    # 3. Human module (src/human/) — human-like mouse movement and typing
    check_shared_module "Human" \
        'mouse\.click|mouse\.move|keyboard\.type|keyboard\.press' \
        "This code uses raw mouse/keyboard. Use the shared Human module at src/human/ (keyboard.ts, mouse.ts) for human-like interaction." \
        "human_justification"

    # 4. Proxy module (src/proxy/config.ts) — proxy URL parsing and config
    check_shared_module "Proxy" \
        'new URL.*proxy|PROXY_URL|proxyOpt|proxy.*server.*username' \
        "This code parses proxy config. Use the shared Proxy module at src/proxy/config.ts." \
        "proxy_justification"

    # 5. Session module (src/session/store.ts) — cookie persistence
    check_shared_module "Session" \
        'addCookies|COOKIES_JSON|saveCookies|loadCookies|cookie.*JSON\.parse' \
        "This code handles cookies. Use the shared Session module at src/session/store.ts for save/load." \
        "session_justification"
fi

# === Block CivitAI API usage ===
if [[ -n "$CONTENT" ]]; then
    if echo "$CONTENT" | grep -qiE 'civitai\.com/api'; then
        echo "BLOCKED: Do not use CivitAI API - scrape the website directly" >&2
        exit 2
    fi
fi

# === Block hardcoded constants (numeric defaults + inline string arrays) ===
if [[ -n "$CONTENT" && "$IS_SYSTEM" == "false" ]]; then
    # Allow constants/config files to define data
    if ! echo "$FILE_PATH" | grep -qE '(constants/|config\.(py|ts|js)|settings\.(py|ts)|/utils/.*\.(ts|js))'; then
        # Python argparse numeric defaults
        if echo "$CONTENT" | grep -qE 'default\s*=\s*[0-9]'; then
            HARDCODED=$(echo "$CONTENT" | grep -E 'default\s*=\s*[0-9]' | grep -vE '(default=0[^.]|default=None|default=True|default=False)' || true)
            if [[ -n "$HARDCODED" ]]; then
                echo "BLOCKED: Hardcoded numeric default found: $(echo "$HARDCODED" | head -1 | xargs). Move to a constants/config module." >&2
                exit 2
            fi
        fi
        # Inline string arrays with 5+ quoted elements (hardcoded data)
        if echo "$CONTENT" | grep -qE "\[('[^']+',\s*){4,}|(\[\"[^\"]+\",\s*){4,}"; then
            INLINE_ARRAY=$(echo "$CONTENT" | grep -E "\[('[^']+',\s*){4,}|(\[\"[^\"]+\",\s*){4,}" | head -1 | xargs)
            echo "BLOCKED: Inline string array with 5+ elements found: ${INLINE_ARRAY:0:80}... Move data arrays to a constants/utils module, not inline in logic files." >&2
            exit 2
        fi
    fi
fi

exit 0
