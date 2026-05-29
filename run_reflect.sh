#!/bin/bash
# Claude assistant weekly reflection — uses mmx CLI (no Anthropic API key needed)
# Reads sessions from the past week, produces an updated insights.md
#
# Prerequisites: mmx CLI installed (npm install -g mmx-cli)
# Schedule: run every Sunday (cron: 5 10 * * 0)
#
# Environment variables:
#   CLAUDE_MEMORY_DIR  — path to memory_vectors dir (default: ~/.claude/memory_vectors)
set -euo pipefail

MEMORY_DIR="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory_vectors}"
INSIGHTS="$MEMORY_DIR/insights.md"
LATEST_REF="$MEMORY_DIR/latest_reflection.json"
LOG_DIR="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}"
LOG="$LOG_DIR/claude-reflect-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG"; }

log "=== Claude Weekly Reflection ($(date +%Y-%m-%d)) ==="

# 1. Gather this week's session data
log "Gathering session data..."
DATA=$(python3 - <<EOF
import json, sqlite3, os
from datetime import date, timedelta
from pathlib import Path

memory_dir = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
db_path = memory_dir / "claude_memory.db"
if not db_path.exists():
    print(json.dumps({"sessions": [], "total_sessions": 0, "week_sessions": 0, "good": 0, "mixed": 0, "wrong": 0}))
    exit()

conn = sqlite3.connect(db_path)
start = (date.today() - timedelta(weeks=1)).isoformat()

rows = conn.execute("""
    SELECT s.id, s.date, s.summary, s.projects, s.tools_used,
           e.verdict, e.note
    FROM sessions s
    LEFT JOIN self_evals e ON e.session_id = s.id
    WHERE s.date >= ?
    ORDER BY s.date
""", (start,)).fetchall()

total = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
good  = conn.execute("SELECT COUNT(*) FROM self_evals WHERE verdict='good'").fetchone()[0]
mixed = conn.execute("SELECT COUNT(*) FROM self_evals WHERE verdict='mixed'").fetchone()[0]
wrong = conn.execute("SELECT COUNT(*) FROM self_evals WHERE verdict='wrong'").fetchone()[0]
conn.close()

output = {
    "week_start": start,
    "week_end": date.today().isoformat(),
    "week_sessions": len(rows),
    "total_sessions": total,
    "good": good, "mixed": mixed, "wrong": wrong,
    "sessions": [
        {
            "id": r[0], "date": r[1], "summary": r[2][:300],
            "projects": json.loads(r[3] or "[]"),
            "tools": json.loads(r[4] or "[]"),
            "verdict": r[5] or "unknown", "note": r[6] or ""
        } for r in rows
    ]
}
print(json.dumps(output, ensure_ascii=False))
EOF
)

CURRENT_INSIGHTS=$(cat "$INSIGHTS" 2>/dev/null || echo "(none yet)")
WEEK=$(date +%G-W%V)
WEEK_COUNT=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['week_sessions'])")
log "Sessions this week: $WEEK_COUNT"

# 2. Ask MiniMax to reflect
log "Asking MiniMax for reflection..."

PROMPT="You are an AI assistant doing your weekly self-reflection. Analyze sessions from the past week to understand patterns in your work and identify improvements.

## This Week's Sessions
$DATA

## Current Insights
$CURRENT_INSIGHTS

## Task
Analyze the sessions above. Consider:
1. What types of tasks came up? Any recurring patterns?
2. Which sessions were 'good' vs 'mixed'/'wrong'? What made the difference?
3. What tools or approaches worked well?
4. What should be done differently next time?

Produce TWO outputs separated by exactly this delimiter on its own line:
---REFLECTION_SUMMARY---

FIRST: Write an updated insights.md in full. Requirements:
- Structure: ## Week, ## User Patterns, ## Task Types, ## What Works, ## Watch Out For, ## Lessons Learned
- Keep factual, concrete, and actionable
- Add week tag: $WEEK
- Increment version if already versioned

SECOND: Write a SHORT summary (max 150 words) in Traditional Chinese:
- 這週的工作模式
- 哪個 session 最值得注意（good 或 wrong）
- 下週要特別留意什麼

Format exactly:
<updated insights.md content>
---REFLECTION_SUMMARY---
<150-word Traditional Chinese summary>"

FULL_RESPONSE=$(mmx text chat \
    --non-interactive \
    --quiet \
    --message "system:You are a disciplined AI assistant doing weekly self-reflection. Follow the output format exactly." \
    --message "user:$PROMPT" 2>>"$LOG")

if [ -z "$FULL_RESPONSE" ]; then
    log "ERROR: No response from MiniMax. Aborting."
    exit 1
fi

# 3. Split insights.md and summary
NEW_INSIGHTS=$(echo "$FULL_RESPONSE" | sed -n '1,/^---REFLECTION_SUMMARY---$/p' | head -n -1)
SUMMARY=$(echo "$FULL_RESPONSE" | sed -n '/^---REFLECTION_SUMMARY---$/,$ p' | tail -n +2)

# 4. Backup and save insights.md
if [ -f "$INSIGHTS" ]; then
    cp "$INSIGHTS" "$MEMORY_DIR/insights_backup_$(date +%Y-%m-%d).md"
    log "Backed up old insights.md"
fi

echo "$NEW_INSIGHTS" > "$INSIGHTS"
log "insights.md updated."

# 5. Save reflection summary (shown=false so next session picks it up)
python3 - <<EOF
import json, os
from datetime import date
from pathlib import Path

memory_dir = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
latest_ref = memory_dir / "latest_reflection.json"

data    = json.loads('''$DATA''')
summary = """$SUMMARY"""
week    = "$WEEK"

result = {
    "date":    "$(date +%Y-%m-%d)",
    "week":    week,
    "summary": summary.strip(),
    "stats": {
        "week_sessions": data["week_sessions"],
        "good":  data["good"],
        "mixed": data["mixed"],
        "wrong": data["wrong"],
    },
    "shown": False
}
with open(latest_ref, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
print("Reflection saved.")
EOF

log "=== Reflection complete ==="
echo ""
echo "=== REFLECTION SUMMARY ==="
echo "$SUMMARY"
