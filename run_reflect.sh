#!/bin/bash
# Claude assistant weekly reflection — uses mmx CLI (no Anthropic API key needed)
# Runs every Sunday 10:05, reads sessions from the past week, produces insights.md update
set -euo pipefail

MEMORY_TOOLS="$HOME/.claude/memory_tools"
VECTOR_DIR="$HOME/.claude/projects/-Users-h60613/memory_vectors"
INSIGHTS="$VECTOR_DIR/insights.md"
LATEST_REF="$VECTOR_DIR/latest_reflection.json"
LOG="$HOME/.claude/logs/claude-reflect-$(date +%Y-%m-%d).log"
mkdir -p "$HOME/.claude/logs"

log() { echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG"; }

log "=== Claude Weekly Reflection ($(date +%Y-%m-%d)) ==="

# 1. Gather this week's session data
log "Gathering session data..."
DATA=$(python3 - <<'EOF'
import json, sqlite3
from datetime import date, timedelta
from pathlib import Path

db_path = Path.home() / ".claude/projects/-Users-h60613/memory_vectors/claude_memory.db"
if not db_path.exists():
    print(json.dumps({"sessions": [], "total": 0, "good": 0, "mixed": 0, "wrong": 0}))
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

log "Session count this week: $(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['week_sessions'])")"

# 2. Ask MiniMax to reflect
log "Asking MiniMax for reflection..."

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

SECOND: Write a SHORT summary (max 150 words) in Traditional Chinese:
- 這週我（AI）的行為模式
- 哪個 session 最值得注意（good 或 wrong）以及為什麼
- 下週要特別留意什麼（針對我自己的行為）

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

# 5. Save reflection summary (with shown=false for next session pickup)
python3 - <<EOF
import json
from datetime import date

data   = json.loads('''$DATA''')
summary = """$SUMMARY"""
week   = "$WEEK"

result = {
    "date":  "$(date +%Y-%m-%d)",
    "week":  week,
    "summary": summary.strip(),
    "stats": {
        "week_sessions": data["week_sessions"],
        "good":  data["good"],
        "mixed": data["mixed"],
        "wrong": data["wrong"],
    },
    "shown": False
}
with open("$LATEST_REF", "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
print("Reflection saved to latest_reflection.json")
EOF

log "=== Reflection complete ==="
echo ""
echo "=== REFLECTION SUMMARY ==="
echo "$SUMMARY"
