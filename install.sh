#!/bin/bash
# Cross-agent installer for autohook-coding-agent-superpowers.
#
# Run from the repo root:
#     ./install.sh
#
# What it does:
#   1. Verifies jq, python3, awk, sed are on $PATH
#   2. Creates ~/.shared-hooks/ (shared across agents)
#   3. Copies all hook scripts into ~/.shared-hooks/
#   4. Wires Claude Code (~/.claude/settings.json)
#   5. Wires Droid (~/.factory/settings.json)
#   6. Wires Codex (~/.codex/hooks.json)
#   7. Installs global git commit-msg hook
#   8. Seeds helper files
#
# Idempotent: re-running overwrites hook files in place.
# Settings files are backed up before modification.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_HOOKS="$HOME/.shared-hooks"
CLAUDE_DIR="$HOME/.claude"
FACTORY_DIR="$HOME/.factory"
CODEX_DIR="$HOME/.codex"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yel()   { printf '\033[33m%s\033[0m' "$1"; }

ok()   { printf '  %s %s\n' "$(green '[ok]')"   "$1"; }
warn() { printf '  %s %s\n' "$(yel '[warn]')"   "$1"; }
err()  { printf '  %s %s\n' "$(red '[err]')"    "$1" >&2; }

echo "autohook-coding-agent-superpowers installer (cross-agent)"
echo "========================================================="
echo ""
echo "  Source: $REPO_ROOT"
echo "  Shared hooks: $SHARED_HOOKS"
echo ""

# 1. Prerequisites
echo "1. Checking prerequisites"
MISSING=()
for cmd in jq python3 awk sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required commands: ${MISSING[*]}"
    err "Standard CLI tools (Homebrew on macOS, apt on Linux)."
    exit 1
fi
ok "jq, python3, awk, sed all present"

# Check at least one agent is installed
AGENTS_FOUND=0
for cmd in claude droid codex; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd CLI found"
        AGENTS_FOUND=$((AGENTS_FOUND + 1))
    fi
done
if [[ "$AGENTS_FOUND" -eq 0 ]]; then
    warn "No agent CLIs found (claude, droid, codex). Hooks will be installed but won't fire until an agent is installed."
fi
echo ""

# 2. Directory layout
echo "2. Creating shared hooks directory"
mkdir -p "$SHARED_HOOKS"
ok "$SHARED_HOOKS ready"
echo ""

# 3. Install hook scripts to shared location
echo "3. Installing hook scripts to $SHARED_HOOKS"
HOOKS_INSTALLED=0
for f in "$REPO_ROOT/hooks"/*.sh "$REPO_ROOT/hooks"/*.py; do
    if [[ -f "$f" ]]; then
        name=$(basename "$f")
        cp "$f" "$SHARED_HOOKS/$name"
        chmod +x "$SHARED_HOOKS/$name"
        ok "$name"
        HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
    fi
done
# Also install the new check_speculation.py if it exists in shared-hooks already
if [[ -f "$SHARED_HOOKS/check_speculation.py" ]]; then
    ok "check_speculation.py (already in shared-hooks)"
fi
if [[ "$HOOKS_INSTALLED" -eq 0 ]]; then
    err "No hooks found in $REPO_ROOT/hooks/. Did you run from the repo root?"
    exit 1
fi
echo ""

# 4. Wire Claude Code
echo "4. Wiring Claude Code (~/.claude/)"
mkdir -p "$CLAUDE_DIR"
TS=$(date '+%Y%m%d-%H%M%S')
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    cp "$CLAUDE_DIR/settings.json" "$CLAUDE_DIR/settings.json.bak.$TS"
    warn "backed up existing settings.json"
fi
cp "$REPO_ROOT/settings.json" "$CLAUDE_DIR/settings.json"
ok "Claude Code settings.json installed"
warn "Replace <YOUR_*> placeholders in mcpServers, or remove the block"
echo ""

# 5. Wire Droid (Factory)
echo "5. Wiring Droid (~/.factory/)"
mkdir -p "$FACTORY_DIR"
if [[ -f "$FACTORY_DIR/settings.json" ]]; then
    cp "$FACTORY_DIR/settings.json" "$FACTORY_DIR/settings.json.bak.$TS"
    warn "backed up existing settings.json"
fi
# Generate Droid hooks config
DROID_HOOKS_JSON=$(cat <<'DROID_EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Execute",
        "hooks": [
          {"type": "command", "command": "SHARED/pre_bash.sh"}
        ]
      },
      {
        "matcher": "Edit|Create",
        "hooks": [
          {"type": "command", "command": "SHARED/pre_write_edit.sh"}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {"type": "command", "command": "SHARED/detect_frustration.sh"}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "python3 SHARED/check_speculation.py"},
          {"type": "command", "command": "python3 SHARED/check_time_estimates.py"},
          {"type": "command", "command": "python3 SHARED/check_stop_asking.py"},
          {"type": "command", "command": "python3 SHARED/check_open_items_with_model.py"},
          {"type": "command", "command": "python3 SHARED/check_substantiation_with_model.py"}
        ]
      }
    ]
  }
}
DROID_EOF
)
# Replace SHARED/ with actual path
DROID_HOOKS_JSON=$(echo "$DROID_HOOKS_JSON" | sed "s|SHARED/|$SHARED_HOOKS/|g")

if [[ -f "$FACTORY_DIR/settings.json" ]]; then
    # Merge hooks into existing settings using jq
    jq --argjson hooks "$DROID_HOOKS_JSON" '.hooks = $hooks.hooks' "$FACTORY_DIR/settings.json" > "$FACTORY_DIR/settings.json.tmp" 2>/dev/null && \
        mv "$FACTORY_DIR/settings.json.tmp" "$FACTORY_DIR/settings.json" && \
        ok "Droid hooks merged into existing settings.json" || {
        warn "Could not merge with jq; writing standalone hooks config"
        echo "$DROID_HOOKS_JSON" > "$FACTORY_DIR/settings.json"
        ok "Droid settings.json written (standalone)"
    }
else
    echo "$DROID_HOOKS_JSON" > "$FACTORY_DIR/settings.json"
    ok "Droid settings.json created"
fi
echo ""

# 6. Wire Codex
echo "6. Wiring Codex (~/.codex/)"
mkdir -p "$CODEX_DIR"
if [[ -f "$CODEX_DIR/hooks.json" ]]; then
    cp "$CODEX_DIR/hooks.json" "$CODEX_DIR/hooks.json.bak.$TS"
    warn "backed up existing hooks.json"
fi
CODEX_HOOKS_JSON=$(cat <<'CODEX_EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "SHARED/pre_bash.sh", "statusMessage": "Checking Bash command"}
        ]
      },
      {
        "matcher": "apply_patch|Edit|Write",
        "hooks": [
          {"type": "command", "command": "SHARED/pre_write_edit.sh", "statusMessage": "Checking file edit"}
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {"type": "command", "command": "SHARED/detect_frustration.sh"}
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "python3 SHARED/check_speculation.py", "timeout": 10},
          {"type": "command", "command": "python3 SHARED/check_time_estimates.py", "timeout": 10},
          {"type": "command", "command": "python3 SHARED/check_stop_asking.py", "timeout": 10},
          {"type": "command", "command": "python3 SHARED/check_open_items_with_model.py", "timeout": 30},
          {"type": "command", "command": "python3 SHARED/check_substantiation_with_model.py", "timeout": 30}
        ]
      }
    ]
  }
}
CODEX_EOF
)
CODEX_HOOKS_JSON=$(echo "$CODEX_HOOKS_JSON" | sed "s|SHARED/|$SHARED_HOOKS/|g")
echo "$CODEX_HOOKS_JSON" > "$CODEX_DIR/hooks.json"
ok "Codex hooks.json installed"
echo ""

# 7. Helper files
echo "7. Seeding helper files"
if [[ ! -f "$SHARED_HOOKS/file_justifications.json" ]]; then
    echo '{}' > "$SHARED_HOOKS/file_justifications.json"
    ok "file_justifications.json seeded with {}"
else
    ok "file_justifications.json already present"
fi
touch "$SHARED_HOOKS/auto_rules.log"
ok "auto_rules.log ready"
echo ""

# 8. Global git commit-msg hook
echo "8. Installing global git commit-msg hook"
GIT_HOOKS_DIR="$CLAUDE_DIR/git-hooks"
mkdir -p "$GIT_HOOKS_DIR"
cp "$REPO_ROOT/git-hooks/commit-msg" "$GIT_HOOKS_DIR/commit-msg"
chmod +x "$GIT_HOOKS_DIR/commit-msg"
ok "commit-msg installed to $GIT_HOOKS_DIR/"

CURRENT_HP=$(git config --global --get core.hooksPath || true)
if [[ -z "$CURRENT_HP" ]]; then
    git config --global core.hooksPath "$GIT_HOOKS_DIR"
    ok "git config --global core.hooksPath -> $GIT_HOOKS_DIR"
elif [[ "$CURRENT_HP" == "$GIT_HOOKS_DIR" ]]; then
    ok "core.hooksPath already pointing at $GIT_HOOKS_DIR"
else
    warn "core.hooksPath already set to: $CURRENT_HP"
    warn "leaving it alone. Either repoint it manually with"
    warn "    git config --global core.hooksPath $GIT_HOOKS_DIR"
    warn "or copy commit-msg into $CURRENT_HP/ yourself."
fi
echo ""

# 9. Done
echo "9. Done. $HOOKS_INSTALLED hook scripts installed to $SHARED_HOOKS"
echo ""
echo "All three agents now share the same behavioral hooks:"
echo "  Claude Code  -> ~/.claude/settings.json   (references $SHARED_HOOKS/)"
echo "  Droid        -> ~/.factory/settings.json  (references $SHARED_HOOKS/)"
echo "  Codex        -> ~/.codex/hooks.json        (references $SHARED_HOOKS/)"
echo ""
echo "Next steps:"
echo "  - Replace <YOUR_*> placeholders in ~/.claude/settings.json mcpServers"
echo "  - detect_frustration.sh shells out to 'claude -p' for model-gated hooks"
echo "  - Edit a hook in $SHARED_HOOKS/ and all agents pick it up immediately"
echo ""
echo "Audit auto-applied rules with:"
echo "  cat $SHARED_HOOKS/auto_rules.log"
