# autohook-coding-agent-superpowers

My personal [Claude Code](https://claude.com/claude-code) hooks, settings, and a sanitized
project-level `CLAUDE.md` template. Sharing them in case the patterns are useful.

This is **opinionated personal config**, not a framework. Read the hooks before you adopt them
— some bits encode my own workflow (auto-deploy on push, an internal model router, a `weles`
project's shared modules) and will need adjustment before they make sense in yours.

## Layout

```
.
├── install.sh                        # One-shot installer; see "Installing" below
├── settings.json                     # ~/.claude/settings.json — wires the hooks
├── hooks/
│   ├── pre_bash.sh                   # PreToolUse:Bash — block inline scripts, dangerous patterns
│   ├── pre_write_edit.sh             # PreToolUse:Write|Edit — file-size cap, justifications, etc.
│   ├── check_email_infra.sh          # PreToolUse:Write|Edit — gate alt-provider workaround code
│   ├── diagnose_email.sh             # Companion: MX/SPF/DKIM/DMARC + Resend domain status
│   ├── detect_frustration.sh         # UserPromptSubmit — auto-append rules from frustrated prompts
│   ├── apply_auto_rule.py            # Helper invoked by detect_frustration.sh to mutate target files
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

### `detect_frustration.sh` + `apply_auto_rule.py` (UserPromptSubmit)

Watches user prompts for frustration / correction signals (`stop`, `ugh`, `i told you`, `that's not what i asked`, `why did you`, profanity targeting behavior, etc.). When it fires it grabs the prior assistant turn from the session transcript and asks `MODEL_ROUTER_URL` to draft a JSON object: `{summary, target, regex, rule_text, confidence}`. If confidence ≥ `FRUSTRATION_CONF_MIN` (default `0.6`), `apply_auto_rule.py` mutates the target directly:

- `check_stop_asking.py` / `check_time_estimates.py` — appends the regex to the relevant pattern list (`STOP_PATTERNS` or `ESTIMATE_PATTERNS`) with a `# auto-added <ISO timestamp>: <summary>` comment.
- `CLAUDE.md` — appends `rule_text` as a bullet under `## Auto-added rules` in the nearest project `CLAUDE.md`, walking up from the session `cwd`. The section is created if absent.

Every outcome (`APPLIED`, `LOW_CONF`, `NO_ROUTER`, `ROUTER_NO_OUTPUT`, `FAIL_*`) is appended to `~/.claude/auto_rules.log`. Audit it; revert any rule by editing the source file.

`MODEL_ROUTER_URL` must expose an OpenAI-compatible `/v1/chat/completions` endpoint. If it's unset or unreachable, the hook logs and exits without mutating anything. There is no curl deadline — a slow router will block `UserPromptSubmit` until it responds (deliberate; matches the project's no-timeouts policy).

The auto-append is direct on purpose: the original design staged proposals into a review file, which sounded safer but defeated the point — "prevent this from ever happening again" means the next prompt should already be guarded. A bad regex or rule shows up immediately in `auto_rules.log` and can be reverted by editing the target file.

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

One-liner:

```bash
git clone https://github.com/lbartoszcze/autohook-coding-agent-superpowers && \
  cd autohook-coding-agent-superpowers && \
  ./install.sh
```

`install.sh` copies `settings.json` and the hook scripts into `~/.claude/`, `chmod +x`s the hooks, seeds `~/.claude/file_justifications.json` with `{}` if missing, and touches `~/.claude/auto_rules.log`. Any pre-existing `~/.claude/settings.json` is backed up to `settings.json.bak.<timestamp>` so you can diff and merge any local changes by hand. Re-running is safe — hook files are overwritten in place; everything else is idempotent.

Prerequisites: `jq`, `curl`, `python3`, `awk`, `sed`. The installer aborts with a clear error if any are missing.

### Post-install

1. **Replace placeholders in `~/.claude/settings.json`.** The `mcpServers` block ships with `<YOUR_STRIPE_API_KEY>`, `<YOUR_FIGMA_API_KEY>`, etc. Fill them in or delete the block entirely.
2. **Set `MODEL_ROUTER_URL`** in your shell rc if you want `detect_frustration.sh` to draft auto-rules. The endpoint must be OpenAI-compatible (`/v1/chat/completions`):
   ```bash
   export MODEL_ROUTER_URL=https://your-router/v1
   ```
3. **Drop the `CLAUDE.md` template into a project.** Copy `examples/CLAUDE.md.template` to your project root, replace the `<YOUR_*>` placeholders, and rename it `CLAUDE.md`.
4. **Audit auto-applied rules** with `cat ~/.claude/auto_rules.log`. Revert by editing the target file (`hooks/check_stop_asking.py`, `hooks/check_time_estimates.py`, or your project `CLAUDE.md`).

### Manual install

If you want to copy individual pieces without running the installer:

```bash
cp settings.json ~/.claude/settings.json
mkdir -p ~/.claude/hooks
cp hooks/*.sh hooks/*.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/*.py
echo '{}' > ~/.claude/file_justifications.json    # only if missing
touch ~/.claude/auto_rules.log
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
