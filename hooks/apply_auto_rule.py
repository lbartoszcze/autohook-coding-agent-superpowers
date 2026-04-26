#!/usr/bin/env python3
"""Apply an auto-generated rule from detect_frustration.sh to the right
hook file or to the nearest project CLAUDE.md.

Usage:
    apply_auto_rule.py --target <name>
                       [--regex <pattern>] [--rule-text <text>]
                       [--summary <summary>] [--cwd <project_cwd>]

Targets:
    check_stop_asking.py     -> append --regex to STOP_PATTERNS list
    check_time_estimates.py  -> append --regex to ESTIMATE_PATTERNS list
    CLAUDE.md                -> append --rule-text as a bullet under
                                "## Auto-added rules" in the nearest
                                project CLAUDE.md (searched upward from
                                --cwd; falls back to --cwd itself if
                                none found).

Every outcome (applied / failed / skipped) is appended to
~/.claude/auto_rules.log.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import sys
from pathlib import Path


HOOKS_DIR = Path.home() / ".claude" / "hooks"
LOG_FILE = Path.home() / ".claude" / "auto_rules.log"


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as f:
        f.write(f"{dt.datetime.now().isoformat(timespec='seconds')} | {msg}\n")


def append_to_python_list(path: Path, list_name: str, pattern: str, summary: str) -> bool:
    if not path.is_file():
        log(f"FAIL_NO_FILE target={path}")
        return False
    src = path.read_text()
    m = re.search(rf"{re.escape(list_name)}\s*=\s*\[", src)
    if not m:
        log(f"FAIL_NO_LIST target={path.name} list={list_name}")
        return False
    depth = 0
    i = m.end() - 1
    while i < len(src):
        if src[i] == "[":
            depth += 1
        elif src[i] == "]":
            depth -= 1
            if depth == 0:
                break
        i += 1
    if depth != 0:
        log(f"FAIL_UNBALANCED target={path.name}")
        return False
    ts = dt.datetime.now().isoformat(timespec="seconds")
    safe = pattern.replace('"""', '\\"\\"\\"')
    new_entry = f"    # auto-added {ts}: {summary}\n    r\"\"\"{safe}\"\"\",\n"
    new_src = src[:i] + new_entry + src[i:]
    path.write_text(new_src)
    log(f"APPLIED target={path.name} list={list_name} summary={summary}")
    return True


def find_project_claude_md(cwd: str) -> Path:
    p = Path(cwd or os.getcwd()).resolve()
    while True:
        candidate = p / "CLAUDE.md"
        if candidate.is_file():
            return candidate
        if p == p.parent:
            return Path(cwd or os.getcwd()).resolve() / "CLAUDE.md"
        p = p.parent


def append_to_claude_md(cwd: str, rule_text: str, summary: str) -> bool:
    target = find_project_claude_md(cwd)
    src = target.read_text() if target.is_file() else ""
    section = "## Auto-added rules"
    ts = dt.datetime.now().isoformat(timespec="seconds")
    bullet = f"- {rule_text}  <!-- auto-added {ts}: {summary} -->\n"
    if section in src:
        idx = src.index(section)
        eol = src.index("\n", idx)
        new_src = src[: eol + 1] + "\n" + bullet + src[eol + 1 :]
    else:
        sep = "" if src.endswith("\n") or not src else "\n"
        new_src = src + sep + ("\n" if src else "") + section + "\n\n" + bullet
    target.write_text(new_src)
    log(f"APPLIED target=CLAUDE.md path={target} summary={summary}")
    return True


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--regex", default="")
    p.add_argument("--rule-text", default="")
    p.add_argument("--summary", default="")
    p.add_argument("--cwd", default=os.getcwd())
    args = p.parse_args()
    summary = args.summary or "(no summary)"
    if args.target == "check_stop_asking.py":
        if not args.regex:
            log(f"FAIL_NO_REGEX target={args.target}")
            return 1
        ok = append_to_python_list(
            HOOKS_DIR / "check_stop_asking.py", "STOP_PATTERNS",
            args.regex, summary,
        )
        return 0 if ok else 1
    if args.target == "check_time_estimates.py":
        if not args.regex:
            log(f"FAIL_NO_REGEX target={args.target}")
            return 1
        ok = append_to_python_list(
            HOOKS_DIR / "check_time_estimates.py", "ESTIMATE_PATTERNS",
            args.regex, summary,
        )
        return 0 if ok else 1
    if args.target == "CLAUDE.md":
        if not args.rule_text:
            log(f"FAIL_NO_RULE_TEXT target={args.target}")
            return 1
        ok = append_to_claude_md(args.cwd, args.rule_text, summary)
        return 0 if ok else 1
    log(f"FAIL_UNSUPPORTED_TARGET target={args.target}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
