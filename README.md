# claude-code-config

My personal [Claude Code](https://claude.com/claude-code) hooks, settings, and a sanitized
project-level `CLAUDE.md` template. Sharing them in case the patterns are useful.

This is **opinionated personal config**, not a framework. Read the hooks before you adopt them
— some bits encode my own workflow (auto-deploy on push, an internal model router, a `weles`
project's shared modules) and will need adjustment before they make sense in yours.

## Layout

```
.
├── settings.json                     # ~/.claude/settings.json — wires the hooks
├── hooks/
│   ├── pre_bash.sh                   # PreToolUse:Bash — block inline scripts, dangerous patterns
│   ├── pre_write_edit.sh             # PreToolUse:Write|Edit — file-size cap, justifications, etc.
│   ├── check_email_infra.sh          # PreToolUse:Write|Edit — gate alt-provider workaround code
│   ├── diagnose_email.sh             # Companion: MX/SPF/DKIM/DMARC + Resend domain status
│   ├── check_stop_asking.py          # Stop hook — block "should I continue?" turns
│   └── check_time_estimates.py       # Stop hook — block duration estimates
└── examples/
    └── CLAUDE.md.template            # Sanitized project-level CLAUDE.md
```

## What the hooks enforce

### `pre_bash.sh` (PreToolUse on `Bash`)

- No writes into `to_check/` folders (user-prepared files).
- No inline shell, Python, Node, Ruby, or Perl. Write a file.
- No remote `sed -i` over `gcloud ssh`. No copying scripts into Docker containers to modify code.
- No direct Anthropic SDK / `ANTHROPIC_API_KEY` usage — pushes you through your own model router.
- No wisent CLI override flags that bypass production defaults (`--limit`, `--max-pairs`, `--quick`, etc.).

### `pre_write_edit.sh` (PreToolUse on `Write` and `Edit`)

- 300-line cap per file. Forces splitting into smaller modules.
- 5-file cap per folder for *new* files. Forces sub-folders / consolidation.
- Blocks the words `fallback` and `keyword-based` in source code.
- Blocks asyncio `wait_for` / `timeout`, `signal.alarm`, `AbortSignal.timeout`, and other timeout primitives.
- Mandatory ≥50-word justification in `~/.claude/file_justifications.json` for every new file.
- Replication manifest required for cloud scripts (`gcp_images`, `_gcp.`, `/ami/`, `_ami.`).
- Shared-module enforcement for the `weles` project (Capture, Vision, Human, Proxy, Session).
- No CivitAI API. Block hardcoded numeric defaults outside `constants/` and inline string arrays of 5+.

### `check_email_infra.sh` + `diagnose_email.sh`

Block writing alt-provider signup helpers until you've actually diagnosed the domain's
infrastructure (MX, SPF, DKIM, DMARC, Resend domain status, recent inbound). Pattern: diagnose
*before* you build a workaround. The marker file `~/.claude/.email_infra_checked` is the bypass.

### `check_stop_asking.py` (Stop hook)

Blocks turns that end with a "what should I do next?" question or a self-declared pause when there's
obviously more work to do. Catches: `want me to`, `should I`, `would you like me to`, `which one`,
`pick`, `let me know`, `pause here`, `checkpoint`, `waiting on your green light`, etc.

### `check_time_estimates.py` (Stop hook)

Blocks turns that contain duration estimates (`takes 5 minutes`, `1-2 hours`, `~30 min`, `ETA`,
`half a day`, etc.). Whitelists trading/ML timeframe nouns (`15-minute bars`, `10-week SMA`,
`60-bar hold`).

### Inline Stop hook (in `settings.json`)

Three regex blocks running on every Stop event:

1. **Manual / simplification language** — `manually`, `by hand`, `simplify`, `simpler approach`.
2. **Weasel words** — `likely`, `probably`, `maybe`, `might`, `could be`, `i think`, `i suspect`.
3. **Cool-down / wait-it-out language** — `cool down`, `fresh eyes`, `try again later`, `IPs will reset`, `take a break`.

## The `file_justifications.json` contract

`pre_write_edit.sh` requires every new file to have a ≥50-word justification under
`~/.claude/file_justifications.json`. The structure is `{ "<absolute_path>": { "justification": "..." } }`.
The `weles`-specific block additionally requires per-domain justifications
(`diagnostics_justification`, `vision_justification`, `human_justification`, `proxy_justification`,
`session_justification`) when the relevant patterns appear.

The point is to make creating a new file a deliberate act. If you can't write 50 words about
why this file needs to exist, it probably doesn't.

## What you'll need to adjust if you fork this

- **Internal model router reference.** `pre_bash.sh` and `pre_write_edit.sh` reference an internal
  router at `github.com/wisent-ai/model-router`. Change to your own, or remove the block entirely
  if you're fine calling Anthropic directly.
- **Wisent CLI flag list.** `pre_bash.sh` blocks specific `wisent` CLI flags. Change or remove.
- **`weles` shared module checks.** `pre_write_edit.sh` enforces shared modules for the `weles`
  project (`/weles/src/`). Either remove or change to your own project paths and modules.
- **`gcp_images` / cloud script paths.** The replication manifest check assumes those naming
  conventions. Adjust.
- **Folder file cap.** 5 may be too aggressive for your taste. Edit it in `pre_write_edit.sh`.

## Installing

This repo is **not** a package. To use:

```bash
cp settings.json ~/.claude/settings.json
mkdir -p ~/.claude/hooks
cp hooks/*.sh ~/.claude/hooks/
cp hooks/*.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/*.py
```

Replace the `<YOUR_*>` placeholders in `settings.json` with your real MCP server keys, or delete
the `mcpServers` block if you don't use them.

You'll also want to seed `~/.claude/file_justifications.json`:

```bash
echo '{}' > ~/.claude/file_justifications.json
```

## Secret rotation checklist

If you got an unsanitized copy of any of this somewhere, treat all of these as burned and rotate:

- AWS access keys
- GitHub PAT
- PyPI token
- Hugging Face token
- Stripe key
- Figma API key
- Resend API key

Anything pasted into a `CLAUDE.md` is effectively published — model context is not a secure
storage medium.

## License

MIT — see `LICENSE`. Use, fork, and modify freely. No warranty.
