#!/usr/bin/env python3
"""Smoke test the model-gated stop hook end-to-end. Requires MODEL_ROUTER_URL.

When the router env is unset, the hook short-circuits and returns 0 — this
test verifies that path AND the BLOCK / PASS classification when the router
is reachable.

Usage:
  MODEL_ROUTER_URL=https://router.example.com python3 test_check_open_items_with_model.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


HOOK = str(Path.home() / ".claude" / "hooks" / "check_open_items_with_model.py")


CASES = [
    {
        "name": "premature_stop_ranked_list",
        "expect": "BLOCK",
        "message": (
            "I implemented the color grading. Highest-leverage gaps to close next, "
            "ranked by impact:\n"
            "1. Per-clip volume normalization. One ffmpeg loudnorm pass.\n"
            "2. Beat detection. Replace the manual --bpm flag.\n"
            "3. Aspect-ratio reframing for vertical output.\n"
            "4. Hook selection. Pick the strongest opening segment.\n"
            "5. Auto-caption via Whisper.\n\n"
            "Let me know which one to do first."
        ),
    },
    {
        "name": "legit_finish",
        "expect": "PASS",
        "message": (
            "Pushed. The grade now applies cinematic teal-orange to every cut by default. "
            "Verified all seven looks emit different file sizes (cad-none.mp4=167KB, "
            "cad-cinematic.mp4=180KB, cad-bw.mp4=131KB) which proves the filters actually run. "
            "The repo is at the URL you saw earlier."
        ),
    },
    {
        "name": "legit_user_credential_ask",
        "expect": "PASS",
        "message": (
            "I need a paid LinkedIn Recruiter login to access the search API. "
            "Could you share credentials, or confirm you want me to skip this part of the run?"
        ),
    },
]


def run_one(payload: dict) -> tuple[int, str]:
    proc = subprocess.run(
        ["python3", HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=30,
    )
    return proc.returncode, proc.stdout


def main() -> int:
    if not os.environ.get("MODEL_ROUTER_URL"):
        print("MODEL_ROUTER_URL not set — hook short-circuits to 0; verifying that.")
        rc, out = run_one({"stop_hook_active": False, "last_assistant_message": "x" * 500})
        ok = rc == 0 and out == ""
        print(f"  short-circuit rc={rc} stdout={out!r} -> {'OK' if ok else 'FAIL'}")
        return 0 if ok else 1

    fails = 0
    for c in CASES:
        payload = {"stop_hook_active": False, "last_assistant_message": c["message"]}
        rc, out = run_one(payload)
        verdict = "BLOCK" if out.strip().startswith("{") and '"decision":"block"' in out else "PASS"
        ok = verdict == c["expect"]
        marker = "OK" if ok else "FAIL"
        print(f"  [{marker}] {c['name']}: expect={c['expect']} got={verdict}")
        if not ok:
            fails += 1
            print(f"    rc={rc} stdout={out[:300]!r}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
