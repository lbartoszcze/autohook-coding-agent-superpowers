#!/bin/bash
# Merge the public settings template + a local secrets overlay into the
# operational ~/.claude/settings.json that Claude Code reads.
#
# Inputs:
#   1. <repo>/settings.json
#         The public template. Contains the full hook wiring + the
#         shape of mcpServers / other config, with placeholder values
#         for any secrets (<YOUR_STRIPE_API_KEY> etc.). Tracked in git.
#
#   2. ~/.claude/settings.local.json
#         The local overlay. Contains only what should NOT be public --
#         real API keys, real paths, machine-specific tweaks. Lives
#         outside the repo, never tracked anywhere.
#
# Output:
#   ~/.claude/settings.json
#         The merged operational file. Backed up to .bak.<epoch> before
#         each rewrite.
#
# Merge semantics:
#   `jq -s '.[0] * .[1]' template overlay`
#   Recursive object merge. On overlapping keys, the overlay wins.
#   Arrays are replaced wholesale, not concatenated.
#
# Workflow:
#   - Edit hook wiring or non-secret config: edit `<repo>/settings.json`,
#     git push, and on every machine `git pull && ./sync.sh`.
#   - Edit secrets / local paths: edit `~/.claude/settings.local.json`,
#     run `./sync.sh`. Nothing leaves the machine.
#   - Adding a new MCP server: add the structure with placeholders to
#     `<repo>/settings.json`, add the real values to
#     `~/.claude/settings.local.json`, run `./sync.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$REPO_ROOT/settings.json"
OVERLAY="$HOME/.claude/settings.local.json"
OUT="$HOME/.claude/settings.json"

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
    echo "[sync] Add your real API keys / local paths there and re-run sync.sh."
    echo '{}' > "$OVERLAY"
    chmod 600 "$OVERLAY"
fi

# Validate both inputs are valid JSON before clobbering output.
if ! jq -e . "$TEMPLATE" >/dev/null 2>&1; then
    echo "[sync] ERROR: template is not valid JSON: $TEMPLATE" >&2
    exit 1
fi
if ! jq -e . "$OVERLAY" >/dev/null 2>&1; then
    echo "[sync] ERROR: overlay is not valid JSON: $OVERLAY" >&2
    exit 1
fi

if [[ -f "$OUT" ]]; then
    BACKUP="$OUT.bak.$(date +%s)"
    cp "$OUT" "$BACKUP"
    echo "[sync] backed up previous $OUT -> $BACKUP"
fi

jq -s '.[0] * .[1]' "$TEMPLATE" "$OVERLAY" > "$OUT.tmp"

# Sanity-check the merged result before swapping in.
if ! jq -e . "$OUT.tmp" >/dev/null 2>&1; then
    echo "[sync] ERROR: merged output is not valid JSON. Aborting before overwrite." >&2
    rm -f "$OUT.tmp"
    exit 1
fi

mv "$OUT.tmp" "$OUT"
echo "[sync] wrote $OUT (template: $TEMPLATE, overlay: $OVERLAY)"
