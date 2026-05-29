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

# 1. Create directories
mkdir -p "$MEMORY_DIR"
mkdir -p "$TOOLS_DIR"

# 2. Copy scripts
cp "$SCRIPT_DIR/claude_memory_log.py"    "$TOOLS_DIR/"
cp "$SCRIPT_DIR/claude_memory_search.py" "$TOOLS_DIR/"
echo "✅ Scripts installed to $TOOLS_DIR"

# 3. Initialize DB (creates tables if not exist)
python3 "$TOOLS_DIR/claude_memory_log.py" \
    --summary "Memory system initialized" \
    --projects '[]' \
    --tools '[]' \
    --verdict good \
    --note "Setup run" 2>/dev/null || true
echo "✅ Database initialized at $MEMORY_DIR"

# 4. Install weekly reflection script
cp "$SCRIPT_DIR/run_reflect.sh" "$HOME/run_claude_reflect.sh"
chmod +x "$HOME/run_claude_reflect.sh"
echo "✅ Reflection script installed at ~/run_claude_reflect.sh"

# 5. Show CLAUDE.md snippet
echo ""
echo "=== Manual step: add to ~/.claude/CLAUDE.md ==="
cat "$SCRIPT_DIR/CLAUDE.md.snippet"
echo ""
echo "Done! Run 'python3 $TOOLS_DIR/claude_memory_search.py --query \"test\"' to verify."
