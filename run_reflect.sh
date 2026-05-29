#!/bin/bash
# Claude assistant weekly reflection
# Runs every Sunday, reads sessions from the past week, produces insights.md update
#
# Requires an LLM CLI that accepts piped input. Configure via CLAUDE_LLM_CMD:
#   export CLAUDE_LLM_CMD="llm"          # Simon Willison's llm CLI (default)
#   export CLAUDE_LLM_CMD="ollama run llama3"
#   export CLAUDE_LLM_CMD="sgpt"         # shell-gpt
# Default: 'llm' (https://llm.datasette.io)
set -euo pipefail

VECTOR_DIR="${CLAUDE_MEMORY_DIR:-$HOME/.claude/memory_vectors}"
INSIGHTS="$VECTOR_DIR/insights.md"
LATEST_REF="$VECTOR_DIR/latest_reflection.json"
LOG_DIR="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}"
LOG="$LOG_DIR/claude-reflect-$(date +%Y-%m-%d).log"
mkdir -p "$LOG_DIR"

log() { echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG"; }

log "=== Claude Weekly Reflection ($(date +%Y-%m-%d)) ==="

# 1. Gather this week's session data
log "Gathering session data..."
DATA=$(CLAUDE_MEMORY_DIR="${VECTOR_DIR}" python3 - <<'PYEOF'
import json, sqlite3, os
from datetime import date, timedelta
from pathlib import Path

db_path = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors")) / "claude_memory.db"
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
PYEOF
)

CURRENT_INSIGHTS=$(cat "$INSIGHTS" 2>/dev/null || echo "(none yet)")
WEEK=$(date +%G-W%V)

log "Sessions this week: $(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['week_sessions'])")"

# 2. Ask LLM to reflect
LLM_CMD="${CLAUDE_LLM_CMD:-llm}"
log "Running reflection via: $LLM_CMD"

PROMPT="You are an AI assistant doing your weekly self-reflection. Your goal is to identify YOUR OWN behavioral patterns — not to summarize what happened or repeat facts the user already knows.

## This Week's Sessions
$DATA

## Current Insights (AI-inferred, supplementary only)
$CURRENT_INSIGHTS

## Important constraints
- The user maintains their own manual devlogs and project notes. Do NOT duplicate that content.
- Focus ONLY on patterns about YOUR behavior as an assistant: what you tend to do well, what mistakes you repeat, what approaches lead to good vs wrong verdicts.
- This file is read by you (the AI) as supplementary context. It is labeled as AI inference, not verified fact.
- Do NOT record user preferences, project decisions, or technical facts — those belong in the user's own memory system.

## Task
Analyze YOUR behavioral patterns from the sessions. Consider:
1. What types of mistakes led to 'wrong' or 'mixed' verdicts? Do you repeat the same mistakes?
2. What approaches consistently led to 'good' verdicts?
3. Are there tool usage patterns worth noting (e.g. forgetting to read before editing)?
4. What should YOU do differently next time — specifically as an assistant?

Produce TWO outputs separated by exactly this delimiter on its own line:
---REFLECTION_SUMMARY---

FIRST: Write an updated insights.md in full. Requirements:
- Header must include: ⚠️ AI-inferred — supplementary to user's devlog, not authoritative
- Structure: ## Week, ## Behavioral Patterns, ## What Works, ## Recurring Mistakes, ## Watch Out For
- Keep it about YOUR assistant behavior only, not user/project facts
- Add week tag: $WEEK
- Increment version if already versioned

SECOND: Write a SHORT summary (max 150 words) in English:
- This week's behavioral patterns
- Most notable session (good or wrong) and why
- What to watch out for next week (your own behavior)

Format exactly:
<updated insights.md content>
---REFLECTION_SUMMARY---
<150-word English summary>"

FULL_RESPONSE=$(echo "$PROMPT" | $LLM_CMD 2>>"$LOG")

if [ -z "$FULL_RESPONSE" ]; then
    log "ERROR: No response from LLM (cmd: $LLM_CMD). Set CLAUDE_LLM_CMD env var."
    exit 1
fi

# 3. Split insights and summary
NEW_INSIGHTS=$(echo "$FULL_RESPONSE" | sed -n '1,/^---REFLECTION_SUMMARY---$/p' | head -n -1)
SUMMARY=$(echo "$FULL_RESPONSE" | sed -n '/^---REFLECTION_SUMMARY---$/,$ p' | tail -n +2)

# 4. Backup and save insights
if [ -f "$INSIGHTS" ]; then
    cp "$INSIGHTS" "$VECTOR_DIR/insights_backup_$(date +%Y-%m-%d).md"
    log "Backed up old insights.md"
fi

echo "$NEW_INSIGHTS" > "$INSIGHTS"
log "insights.md updated."

# 5. Save reflection summary (shown=false so next session picks it up)
python3 - <<PYEOF
import json, os
from datetime import date
from pathlib import Path

vector_dir = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
latest_ref = vector_dir / "latest_reflection.json"

data    = json.loads("""$DATA""")
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
PYEOF

log "=== Reflection complete ==="
echo ""
echo "=== REFLECTION SUMMARY ==="
echo "$SUMMARY"
