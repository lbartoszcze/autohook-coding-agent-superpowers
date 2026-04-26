#!/bin/bash
# One-shot installer for claude-code-config.
#
# Run from the repo root:
#     ./install.sh
#
# What it does:
#   1. Verifies jq, curl, python3, awk, sed are on $PATH
#   2. Creates ~/.claude/hooks/
#   3. Backs up any existing ~/.claude/settings.json to .bak.<timestamp>
#   4. Copies settings.json + hooks/* into ~/.claude/
#   5. chmod +x the hook scripts
#   6. Seeds ~/.claude/file_justifications.json (empty {}) if missing
#   7. Touches ~/.claude/auto_rules.log if missing
#
# Idempotent: re-running overwrites hook files in place. The previous
# settings.json is preserved as a timestamped backup so you can diff
# and merge any local changes you had made.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
yel()   { printf '\033[33m%s\033[0m' "$1"; }

ok()   { printf '  %s %s\n' "$(green '[ok]')"   "$1"; }
warn() { printf '  %s %s\n' "$(yel '[warn]')"   "$1"; }
err()  { printf '  %s %s\n' "$(red '[err]')"    "$1" >&2; }

echo "claude-code-config installer"
echo "============================"
echo ""
echo "  Source: $REPO_ROOT"
echo "  Target: $CLAUDE_DIR"
echo ""

# 1. Prerequisites
echo "1. Checking prerequisites"
MISSING=()
for cmd in jq curl python3 awk sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    err "Missing required commands: ${MISSING[*]}"
    err "Install them via Homebrew (macOS) or apt (Linux) and re-run."
    exit 1
fi
ok "jq, curl, python3, awk, sed all present"
echo ""

# 2. Directory layout
echo "2. Creating ~/.claude directories"
mkdir -p "$HOOKS_DIR"
ok "$HOOKS_DIR ready"
echo ""

# 3. settings.json
echo "3. Installing settings.json"
TS=$(date '+%Y%m%d-%H%M%S')
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    BACKUP="$CLAUDE_DIR/settings.json.bak.$TS"
    cp "$CLAUDE_DIR/settings.json" "$BACKUP"
    warn "existing settings.json backed up to:"
    warn "    $BACKUP"
fi
cp "$REPO_ROOT/settings.json" "$CLAUDE_DIR/settings.json"
ok "settings.json installed"
warn "open it and replace <YOUR_*> placeholders, or remove the mcpServers block"
echo ""

# 4. Hooks
echo "4. Installing hooks"
HOOKS_INSTALLED=0
for f in "$REPO_ROOT/hooks"/*.sh "$REPO_ROOT/hooks"/*.py; do
    if [[ -f "$f" ]]; then
        name=$(basename "$f")
        cp "$f" "$HOOKS_DIR/$name"
        chmod +x "$HOOKS_DIR/$name"
        ok "$name"
        HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
    fi
done
if [[ "$HOOKS_INSTALLED" -eq 0 ]]; then
    err "No hooks found in $REPO_ROOT/hooks/. Did you run from the repo root?"
    exit 1
fi
echo ""

# 5. Helper files
echo "5. Seeding helper files"
if [[ ! -f "$CLAUDE_DIR/file_justifications.json" ]]; then
    echo '{}' > "$CLAUDE_DIR/file_justifications.json"
    ok "file_justifications.json seeded with {}"
else
    ok "file_justifications.json already present"
fi
touch "$CLAUDE_DIR/auto_rules.log"
ok "auto_rules.log ready"
echo ""

# 6. Done
echo "6. Done. $HOOKS_INSTALLED hook scripts installed."
echo ""
echo "Next steps:"
echo "  - Set MODEL_ROUTER_URL in your shell so detect_frustration.sh can"
echo "    draft auto-rules. The endpoint must be OpenAI-compatible:"
echo ""
echo "      export MODEL_ROUTER_URL=https://your-router/v1"
echo ""
echo "  - Drop examples/CLAUDE.md.template into a project root, replace the"
echo "    <YOUR_*> placeholders, and rename it CLAUDE.md."
echo ""
echo "  - Review ~/.claude/settings.json. The mcpServers block has placeholder"
echo "    keys; fill them in or remove the block."
echo ""
echo "Audit auto-applied rules with:"
echo "  cat ~/.claude/auto_rules.log"
