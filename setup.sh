#!/bin/bash
# claude-session-memory — one-shot setup
# Creates the memory directory, initializes the DB, and installs the scripts.
set -euo pipefail

MEMORY_DIR="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory_vectors}"
TOOLS_DIR="${CLAUDE_TOOLS_DIR:-$HOME/.claude/memory_tools}"
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

# 4. Copy scripts
cp "$SCRIPT_DIR/claude_memory_log.py"    "$TOOLS_DIR/"
cp "$SCRIPT_DIR/claude_memory_search.py" "$TOOLS_DIR/"
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

echo ""
echo "✅ All done!"
echo ""
echo "Next steps:"
echo "  1. Set CLAUDE_EMBED_URL to your embedding endpoint (see README)"
echo "  2. Set CLAUDE_LLM_CMD to your LLM CLI for weekly reflection"
echo "  3. Paste this repo's README to Claude and ask it to activate the memory system"
echo ""
echo "Verify: python3 $TOOLS_DIR/claude_memory_search.py --query \"test\""
