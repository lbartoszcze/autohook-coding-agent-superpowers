#!/bin/bash
# Cross-agent sync: deploy hook config to Claude Code, Droid, and Codex.
#
# Shared hooks live in ~/.shared-hooks/ (installed by install.sh).
# This script syncs the settings.json template + local overlay into
# the operational config files for all three agents.
#
# Inputs:
#   1. <repo>/settings.json       (public template, tracked in git)
#   2. ~/.claude/settings.local.json (local secrets overlay)
#
# Outputs:
#   ~/.claude/settings.json       (Claude Code)
#   ~/.factory/settings.json      (Droid -- hooks section only)
#   ~/.codex/hooks.json           (Codex -- hooks only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$REPO_ROOT/settings.json"
OVERLAY="$HOME/.claude/settings.local.json"
SHARED_HOOKS="$HOME/.shared-hooks"

if ! command -v jq >/dev/null 2>&1; then
    echo "[sync] ERROR: jq not on PATH. Install jq and re-run." >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
    echo "[sync] ERROR: template not found: $TEMPLATE" >&2
    exit 1
fi

if [[ ! -f "$OVERLAY" ]]; then
    echo "[sync] No overlay at $OVERLAY -- creating an empty one ({})."
    echo '{}' > "$OVERLAY"
    chmod 600 "$OVERLAY"
fi

# Validate inputs
if ! jq -e . "$TEMPLATE" >/dev/null 2>&1; then
    echo "[sync] ERROR: template is not valid JSON: $TEMPLATE" >&2
    exit 1
fi
if ! jq -e . "$OVERLAY" >/dev/null 2>&1; then
    echo "[sync] ERROR: overlay is not valid JSON: $OVERLAY" >&2
    exit 1
fi

# --- Claude Code ---
CLAUDE_OUT="$HOME/.claude/settings.json"
if [[ -f "$CLAUDE_OUT" ]]; then
    cp "$CLAUDE_OUT" "$CLAUDE_OUT.bak.$(date +%s)"
fi
jq -s '.[0] * .[1]' "$TEMPLATE" "$OVERLAY" > "$CLAUDE_OUT.tmp"
if ! jq -e . "$CLAUDE_OUT.tmp" >/dev/null 2>&1; then
    echo "[sync] ERROR: Claude Code merged output is not valid JSON. Aborting." >&2
    rm -f "$CLAUDE_OUT.tmp"
    exit 1
fi
mv "$CLAUDE_OUT.tmp" "$CLAUDE_OUT"
echo "[sync] wrote $CLAUDE_OUT"

# --- Droid (Factory) ---
FACTORY_OUT="$HOME/.factory/settings.json"
DROID_HOOKS=$(jq -r '.hooks // {}' "$CLAUDE_OUT" 2>/dev/null || echo '{}')
if [[ -f "$FACTORY_OUT" ]]; then
    cp "$FACTORY_OUT" "$FACTORY_OUT.bak.$(date +%s)"
    # Merge hooks into existing Droid settings (preserve non-hook fields)
    jq --argjson hooks "$DROID_HOOKS" '.hooks = $hooks' "$FACTORY_OUT" > "$FACTORY_OUT.tmp" 2>/dev/null && \
        mv "$FACTORY_OUT.tmp" "$FACTORY_OUT" || {
        echo "[sync] WARN: could not merge hooks into Droid settings; skipping Droid"
        rm -f "$FACTORY_OUT.tmp"
    }
    echo "[sync] wrote $FACTORY_OUT (hooks merged)"
else
    echo "{\"hooks\": $DROID_HOOKS}" > "$FACTORY_OUT"
    echo "[sync] wrote $FACTORY_OUT (new file, hooks only)"
fi

# --- Codex ---
# Generate Codex hooks.json from the shared scripts directly,
# since Codex has different matcher names and uses TOML-style config.
CODEX_OUT="$HOME/.codex/hooks.json"
if [[ -f "$CODEX_OUT" ]]; then
    cp "$CODEX_OUT" "$CODEX_OUT.bak.$(date +%s)"
fi
cat > "$CODEX_OUT" <<CODEX_JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "$SHARED_HOOKS/pre_bash.sh", "statusMessage": "Checking Bash command"}
        ]
      },
      {
        "matcher": "apply_patch|Edit|Write",
        "hooks": [
          {"type": "command", "command": "$SHARED_HOOKS/pre_write_edit.sh", "statusMessage": "Checking file edit"}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {"type": "command", "command": "$SHARED_HOOKS/detect_frustration.sh"}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "python3 $SHARED_HOOKS/check_speculation.py", "statusMessage": "Checking speculation", "wait": 10},
          {"type": "command", "command": "python3 $SHARED_HOOKS/check_time_estimates.py", "statusMessage": "Checking time estimates", "wait": 10},
          {"type": "command", "command": "python3 $SHARED_HOOKS/check_stop_asking.py", "statusMessage": "Checking premature stop", "wait": 10},
          {"type": "command", "command": "python3 $SHARED_HOOKS/check_open_items_with_model.py", "statusMessage": "Model-gated stop check", "wait": 30},
          {"type": "command", "command": "python3 $SHARED_HOOKS/check_substantiation_with_model.py", "statusMessage": "Model-gated substantiation check", "wait": 30}
        ]
      }
    ]
  }
}
CODEX_JSON

if ! jq -e . "$CODEX_OUT" >/dev/null 2>&1; then
    echo "[sync] WARN: Codex hooks.json is not valid JSON; skipping"
    rm -f "$CODEX_OUT"
else
    echo "[sync] wrote $CODEX_OUT"
fi

echo "[sync] All agents synced."
