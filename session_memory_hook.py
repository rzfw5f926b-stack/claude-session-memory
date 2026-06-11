#!/usr/bin/env python3
"""
UserPromptSubmit hook: inject memory search results once per session.

Place this file in ~/.claude/memory_tools/ and register it in ~/.claude/settings.json:

  {
    "hooks": {
      "UserPromptSubmit": [
        {
          "matcher": ".*",
          "hooks": [{ "type": "command", "command": "python3 ~/.claude/memory_tools/session_memory_hook.py" }]
        }
      ]
    }
  }

Flow:
  1. Read Claude Code hook JSON from stdin (session_id, prompt)
  2. If lock exists → already ran this session, exit silently
  3. If prompt is trivial (≤4 chars or greeting) → skip without creating lock
     (next substantive message will still trigger search)
  4. Create lock, run claude_memory_search.py, print results if any

Note on context accumulation:
  UserPromptSubmit hook output (additionalContext) accumulates in conversation history
  and is NOT cleared between turns — this is a known Claude Code behavior (issue #40216).
  The session-lock pattern (run once, then silently exit) is the only safe approach.
"""
import json
import sys
import subprocess
from pathlib import Path

GREETINGS = {"你好", "hi", "hello", "hey", "晚安", "早安", "嗨", "哈囉", "ok", "好", "哈"}
TOOLS_DIR = Path.home() / ".claude" / "memory_tools"


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)

    session_id = payload.get("session_id", "unknown")
    prompt = payload.get("prompt", "").strip()

    # Already ran this session
    lock = Path(f"/tmp/claude-mem-{session_id}")
    if lock.exists():
        sys.exit(0)

    # Skip trivial content — don't create lock, so next substantive message triggers search
    if len(prompt) <= 4 or prompt.lower() in GREETINGS:
        sys.exit(0)

    # Create lock before search (prevent double-run on rapid messages)
    lock.touch()

    try:
        result = subprocess.run(
            [
                "python3",
                str(TOOLS_DIR / "claude_memory_search.py"),
                "--query", prompt[:150],
                "--top-k", "3",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        output = result.stdout.strip()
        if output:
            print(output)
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
