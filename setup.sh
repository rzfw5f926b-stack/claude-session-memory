#!/bin/bash
# claude-session-memory — one-shot setup
# Creates the memory directory, initializes the DB, installs scripts,
# registers the UserPromptSubmit hook, and installs the /mem skill.
set -euo pipefail

MEMORY_DIR="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory_vectors}"
TOOLS_DIR="${CLAUDE_TOOLS_DIR:-$HOME/.claude/memory_tools}"
SKILLS_DIR="$HOME/.claude/skills/mem"
SETTINGS="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== claude-session-memory setup ==="
echo "Memory dir : $MEMORY_DIR"
echo "Tools dir  : $TOOLS_DIR"
echo ""

# 1. Check Python version (3.10+ required)
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
PYTHON_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]; }; then
    echo "❌ Python 3.10+ required (found $PYTHON_VERSION). Aborting."
    exit 1
fi
echo "✅ Python $PYTHON_VERSION"

# 2. Check numpy
if ! python3 -c "import numpy" 2>/dev/null; then
    echo "Installing numpy..."
    pip install numpy --quiet
fi
echo "✅ numpy"

# 3. Create directories
mkdir -p "$MEMORY_DIR"
mkdir -p "$TOOLS_DIR"
mkdir -p "$SKILLS_DIR"

# 4. Copy scripts
cp "$SCRIPT_DIR/claude_memory_log.py"      "$TOOLS_DIR/"
cp "$SCRIPT_DIR/claude_memory_search.py"   "$TOOLS_DIR/"
cp "$SCRIPT_DIR/session_memory_hook.py"    "$TOOLS_DIR/"
echo "✅ Scripts installed to $TOOLS_DIR"

# 5. Initialize DB schema only (no embedding call — embed endpoint may not be set up yet)
python3 - <<EOF
import sqlite3, os
from pathlib import Path

memory_dir = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
memory_dir.mkdir(parents=True, exist_ok=True)

for db_path, schema in [
    (memory_dir / "claude_memory.db", """
        CREATE TABLE IF NOT EXISTS sessions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            date       TEXT NOT NULL,
            summary    TEXT NOT NULL,
            projects   TEXT,
            tools_used TEXT,
            vector_id  INTEGER
        );
        CREATE TABLE IF NOT EXISTS self_evals (
            session_id INTEGER PRIMARY KEY REFERENCES sessions(id),
            verdict    TEXT,
            note       TEXT
        );
    """),
    (memory_dir / "vectors.db", """
        CREATE TABLE IF NOT EXISTS vectors (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            text      TEXT NOT NULL,
            embedding BLOB NOT NULL,
            meta      TEXT DEFAULT '{}'
        );
    """),
]:
    conn = sqlite3.connect(db_path)
    conn.executescript(schema)
    conn.commit()
    conn.close()

print(f"DB initialized at {memory_dir}")
EOF
echo "✅ Database initialized (schema only — no embedding required at setup)"

# 6. Install weekly reflection script
cp "$SCRIPT_DIR/run_reflect.sh" "$HOME/run_claude_reflect.sh"
chmod +x "$HOME/run_claude_reflect.sh"
echo "✅ Reflection script installed at ~/run_claude_reflect.sh"

# 7. Register UserPromptSubmit hook in ~/.claude/settings.json
python3 - <<EOF
import json
from pathlib import Path

settings_path = Path("$SETTINGS")
settings_path.parent.mkdir(parents=True, exist_ok=True)

# Load existing settings or start fresh
if settings_path.exists():
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

hook_entry = {
    "matcher": ".*",
    "hooks": [
        {
            "type": "command",
            "command": "python3 ~/.claude/memory_tools/session_memory_hook.py"
        }
    ]
}

hooks = settings.setdefault("hooks", {})
existing = hooks.setdefault("UserPromptSubmit", [])

# Don't add duplicate
hook_cmd = "python3 ~/.claude/memory_tools/session_memory_hook.py"
already_registered = any(
    any(h.get("command") == hook_cmd for h in entry.get("hooks", []))
    for entry in existing
)

if not already_registered:
    existing.append(hook_entry)
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)
    print("Hook registered in settings.json")
else:
    print("Hook already registered — skipping")
EOF
echo "✅ UserPromptSubmit hook registered in $SETTINGS"

# 8. Install /mem skill
cat > "$SKILLS_DIR/SKILL.md" <<'SKILLEOF'
---
name: mem
description: Manually operate the session memory system. Search: /mem [keywords] (omit keywords to auto-derive from context). Log: /mem log (write current session immediately). Not subject to session lock — can be called anytime.
---

# /mem — Manual Memory Operations

## Usage

- `/mem [keywords]` — search memory
- `/mem log` — log this session now

---

## Search mode (default)

Run:
```bash
python3 ~/.claude/memory_tools/claude_memory_search.py --query "<keywords>" --top-k 5
```

- If keywords provided → use them directly
- If omitted → extract 3–5 keywords from the last 2–3 conversation turns
- Results found → display with 🧠 prefix
- No results → silent

---

## Log mode (/mem log)

Derive from the current session:
- `summary` (English, one sentence)
- `projects` (list of project names involved)
- `tools` (list of tools used)
- `verdict` (good / mixed / wrong)
- `note` (brief reason)

Run:
```bash
python3 ~/.claude/memory_tools/claude_memory_log.py \
  --summary "..." \
  --projects '[...]' \
  --tools '[...]' \
  --verdict "..." \
  --note "..."
```

Display the script's actual stdout (💾 or ⚠️ line). **Never write these lines yourself — only show actual script output.**
SKILLEOF
echo "✅ /mem skill installed at $SKILLS_DIR/SKILL.md"

echo ""
echo "✅ All done!"
echo ""
echo "Next steps:"
echo "  1. Set CLAUDE_EMBED_URL to your embedding endpoint (see README)"
echo "     macOS 14+: use macOSUtilityBridge at localhost:11435 (no extra setup)"
echo "     Other:     Ollama with nomic-embed-text (see README for adapter)"
echo "  2. Set CLAUDE_LLM_CMD to your LLM CLI for weekly reflection"
echo "  3. Add the following to ~/.claude/CLAUDE.md:"
echo ""
echo "  ## Memory Search (Session Start)"
echo "  Memory search is handled automatically by \`session_memory_hook.py\` (UserPromptSubmit hook)."
echo "  The hook injects 🧠 results once per session on the first substantive message — no manual action needed."
echo "  To search mid-session or with custom keywords, use \`/mem [keywords]\`."
echo ""
echo "  ## Memory Log (Session End)"
echo "  Before ending a session where meaningful work was done, run:"
echo "  python3 ~/.claude/memory_tools/claude_memory_log.py \\"
echo "    --summary \"<English summary>\" \\"
echo "    --projects '[\"project1\"]' \\"
echo "    --tools '[\"Bash\", \"Edit\"]' \\"
echo "    --verdict \"good|mixed|wrong\" \\"
echo "    --note \"<brief reason>\""
echo ""
echo "  Verdict guidelines:"
echo "    good  — no corrections needed, task completed smoothly"
echo "    mixed — 1-2 corrections needed but resolved"
echo "    wrong — multiple corrections / user clearly unsatisfied"
echo ""
echo "  IMPORTANT: Display 💾/⚠️ line only from actual script stdout, never write it yourself."
echo ""
echo "Verify: python3 $TOOLS_DIR/claude_memory_search.py --query \"test\""
