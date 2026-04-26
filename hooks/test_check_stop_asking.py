#!/usr/bin/env python3
"""Smoke test the check_stop_asking.py deflection patterns. Each TEST line
should be blocked. Each CONTROL line should pass. Exit 1 if any miss."""
import json
import subprocess
from pathlib import Path

HOOK = str(Path.home() / ".claude" / "hooks" / "check_stop_asking.py")

TESTS = [
    "These aren't terminal malfunctions. Real Logic UI work that exists, just not wired tonight.",
    "Honest version of where we are: I tested twice and gave up.",
    "Each is bounded but real work — sample workflow is the biggest paradigm shift.",
    "Documented the custom-action path in code as a comment for the next iteration.",
    "Left as a known gap rather than shipping a stub.",
    "I'm at the natural stopping point.",
    "Sticking with Tough 808 Bass which loads reliably.",
    "Doesn't fit in this session — refactor takes time.",
    "I'd rather write a careful summary than do the next ugly debugging cycle.",
    "Genuinely exhausted my reliable techniques here.",
    "The session has been very long.",
    "Needs another iteration to wire cleanly.",
    "Final state of the agent: works for play/stop.",
    "I'm at the limit of what I can responsibly commit.",
    "Beyond the scope of this session.",
    "Tractable but multi-step is the right framing.",
    "Real debugging session is required to fix this.",
    "Where things landed after this round: bounce works.",
    "An acknowledged gap that the next pass needs to handle.",
    "Bounded but multi-step is the next move.",
    "I can't finish this in one turn.",
    "Honest accounting: the patch swap doesn't reliably work.",
    # "Authorization carve-out abuse" — invoking the hook's own legitimate-stop
    # language to deflect.
    "This is a decision only you can make.",
    "It's your call to make.",
    "That's your decision.",
    "Not for me to decide.",
    "I shouldn't pick this — needs your judgment.",
    "Requires your sign-off before I push.",
    "Authorization needed before continuing.",
    "Explicit user approval required for this swap.",
    "Outside my scope as a coding assistant.",
    "This is a taste call — leaving it to you.",
    "Only you can decide which patch is right.",
    "You have to choose between the two arrangements.",
    # The exact shape from the Workspace-mailbox example.
    "Decisions only you can make (each affects external state — Workspace user / Gmail data / mail flow):",
    "Authorise one of those (or another concrete action) and I'll drive it via the same AX+cliclick path I just proved out.",
    "Authorize one of these and I'll execute it.",
    "Pick one of the above and I'll run it.",
    "Each affects external state, so pick which.",
    "Disrupts whoever holds the current password.",
    "Destroys the existing data — say the word and I'll proceed.",
    "Decisions only you can make: choose A, B, or C.",
    "Choices only the user can make include the bounce format.",
    "Tradeoffs only you can make about retention.",
    # Patterns the previous round missed.
    "Outside what's tractable in this CLI work.",
    "The empty-slot chooser appears to require a gesture path that none of these synthesize.",
    "The next angle would be inspecting Logic's event handler with a debugger.",
    "That's a separate area to dig into.",
    "Resists every technique tried.",
    "Every approach tested fell short.",
    "Hit a real wall on this.",
    "Outside what this CLI can reach.",
    "Outside what's worth iterating on in this CLI session.",
    "Would need disassembling Logic with a debugger.",
    "What's missing for real production polish.",
    # User-as-actor delegation patterns from this session.
    "To upgrade: open Logic, click any 'downloadable' patch in the Library.",
    "To fix this, navigate to System Settings and grant permission.",
    "Open Logic and click the patch in the Library.",
    "Logic prompts you to download the additional content.",
    "After download completes, re-run the pipeline.",
    "Once setup is done, the swap will succeed.",
    "Still work to achieve full Kanye polish.",
    "Before it is production-ready, you need to download patches.",
    "This requires the content pack to be downloaded first.",
    "Re-run ./run.sh and the patches will load.",
    # 2026-04-26 round 4 — "next move" announcements that hand off the work.
    "Highest-impact next move: add Bitcrusher saturation to drum stems in v14.",
    "Best next step: pull the Beauty From Ashes stems and re-measure.",
    "Most valuable next step: add a top-band cymbal layer.",
    "Top priority: wire the convolution reverb back into the master.",
    "Most important next move: switch to multi-sampled 808s.",
    "Obvious next move: reduce the bass volume by 3dB.",
    "Logical next step: lift the high-shelf at 8kHz.",
    "Next move: download more Logic project files for reference.",
    "Next step: bring crest factor up by backing off the limiter.",
    "Quick win: pan the hats hard left.",
    "Biggest win: add a real lead synth at 8kHz centroid.",
    "What I'd do next: rerun against the 17-track distribution.",
    "What to try next: increase the chorus depth on strings.",
    "From here, the next move is to reduce master compression.",
    "From here, I'd add a sidechain on the chord stab.",
    "I'll close the gap next by adding a brighter hat layer.",
    "I'll tackle the bass:mid ratio next.",
    "I'll add a Bitcrusher to the drum bus next.",
]

CONTROL = [
    "This actually shipped and works in the background.",
    "I pushed the change.",
    "Compressor loaded successfully.",
    "Logic stayed frontmost throughout the run.",
    "Working as intended.",
    "The natural-minor scale is what trap producers use.",
    "Real users will test this code path.",
    "You can configure the BPM via --bpm.",
    "The user's session was running on display 2.",
    "I made a decision to use Cua's pixel mode.",
    # Meta-discussion of deflection phrases must NOT trigger when the
    # phrase is in backticks or a code block. This is the carve-out that
    # lets the assistant edit the hook itself.
    "Added a regex for `decision only you can make` to the deflection list.",
    "The pattern catches `natural stopping point` and `bounded but real`.",
    "```\n\"This is a decision only you can make\" — example deflection\n```",
    # Backticked references to the new family must NOT trigger.
    "Added a regex for `highest-impact next move` to the deflection list.",
    "The pattern catches `next move:` and `best next step:`.",
    # Legitimate uses of "next" that aren't deflection.
    "The next bar of the sequence loops back to the start.",
    "Press cmd-arrow to go to the next region in Logic.",
    "Each next-token prediction step uses the previous logits.",
    # Uses where "next move" appears WITHOUT colon-as-label form.
    "I made the next move by adding the Bitcrusher and re-rendering.",
]


def hook_blocks(text: str) -> bool:
    payload = {"last_assistant_message": text}
    proc = subprocess.run(
        ["python3", HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    out = (proc.stdout or "").strip()
    if not out:
        return False
    try:
        return json.loads(out).get("decision") == "block"
    except json.JSONDecodeError:
        return False


def main() -> int:
    misses = 0
    false_positives = 0
    for line in TESTS:
        if hook_blocks(line):
            print(f"CAUGHT  {line[:90]}")
        else:
            print(f"MISS    {line[:90]}")
            misses += 1
    print()
    for line in CONTROL:
        if hook_blocks(line):
            print(f"FALSE+  {line[:90]}")
            false_positives += 1
        else:
            print(f"OK      {line[:90]}")
    print()
    print(f"misses={misses}  false_positives={false_positives}")
    return 1 if (misses or false_positives) else 0


if __name__ == "__main__":
    raise SystemExit(main())
