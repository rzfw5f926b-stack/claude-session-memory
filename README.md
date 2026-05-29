# claude-session-memory

> **繁體中文說明**
> 這是一個讓 Claude 具備跨 session 自我學習能力的記憶系統。
> 安裝後，Claude 每次 session 結束時會自動記錄摘要與自評，下次 session 開頭會搜尋相關過去記憶並注入 context，每週透過反思提煉洞見。
> **直接把這整個 README 貼給 AI，它就能幫你完成安裝。**

A lightweight self-learning memory system for Claude — stores session summaries as vectors, retrieves relevant past context at session start, and distills weekly insights via reflection.

Inspired by the three-layer memory architecture from [esun-sim-trader](https://github.com/), adapted for AI assistant use.

## How it works

```
Session start → vector search → inject relevant past context (🧠)
                                                        ↓
                                               respond to user
                                                        ↓
Session end   → embed summary → write to DB → self-evaluate (💾)
                                                        ↓
Every Sunday  → mmx reflection → update insights.md (📓 next session)
```

### Three layers

| Layer | Content | When |
|-------|---------|------|
| 1 — Session log | What was done, which projects, which tools | Each session end |
| 2 — Self-eval | `good` / `mixed` / `wrong` + reason | Each session end |
| 3 — Insights | Distilled patterns: user habits, common tasks, watch-outs | Every Sunday |

### Hybrid search scoring

Results are ranked by:

```
score = 0.7 × cosine_similarity + 0.2 × recency + 0.1 × complexity
```

- **recency**: `1 / (1 + days_ago / 30)` — sessions from last week rank higher than ones from 3 months ago
- **complexity**: longer summaries (richer sessions) score slightly higher
- **threshold**: 0.5 — below this, search exits silently

### Three UX signals

| Signal | When |
|--------|------|
| `🧠 Found N relevant memories (latest: YYYY-MM-DD ...)` | Session start, relevant memories found |
| `💾 記憶已寫入（#id · verdict · projects）` | Session end, write successful |
| `📓 Weekly reflection updated (YYYY-WNN · ...)` | First session after Sunday reflection |

## Prerequisites

- Python 3.10+
- `numpy` (`pip install numpy`)
- A local embedding endpoint at `http://localhost:11435/v1/embed`
  - Compatible with [macOSUtilityBridge](https://github.com/) (Apple NLEmbedding 512d)
  - Or any server accepting `{"text": "...", "language": "en"}` → `{"embedding": [...]}`
- `mmx` CLI for weekly reflection ([MiniMax](https://www.minimaxi.com/))
  - `npm install -g mmx-cli && mmx auth login --api-key <key>`

## Setup

```bash
git clone https://github.com/YOUR_USERNAME/claude-session-memory
cd claude-session-memory
pip install -r requirements.txt
bash setup.sh
```

`setup.sh` will:
1. Create `~/.claude/memory_vectors/` (or `$CLAUDE_MEMORY_DIR`)
2. Install scripts to `~/.claude/memory_tools/`
3. Initialize the SQLite databases
4. Install `~/run_claude_reflect.sh`
5. Print the snippet to add to `~/.claude/CLAUDE.md`

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `CLAUDE_MEMORY_DIR` | `~/.claude/memory_vectors` | Where DBs and insights.md are stored |
| `CLAUDE_EMBED_URL` | `http://localhost:11435/v1/embed` | Embedding endpoint |
| `CLAUDE_TOOLS_DIR` | `~/.claude/memory_tools` | Where scripts are installed |
| `CLAUDE_LOG_DIR` | `~/.claude/logs` | Reflection log directory |

## Usage

### Manual session log

```bash
python3 ~/.claude/memory_tools/claude_memory_log.py \
  --summary "Debugged IPv6 binding issue in dashboard.py, fixed with AF_INET6 server class" \
  --projects '["my-project"]' \
  --tools '["Bash", "Edit", "Read"]' \
  --verdict good \
  --note "User accepted fix on first try"
```

### Manual search

```bash
python3 ~/.claude/memory_tools/claude_memory_search.py --query "IPv6 socket error"
```

### Weekly reflection (manual)

```bash
bash ~/run_claude_reflect.sh
```

### Scheduled weekly reflection (cron)

```bash
# Add to crontab (crontab -e):
5 10 * * 0 CLAUDE_MEMORY_DIR=$HOME/.claude/memory_vectors bash $HOME/run_claude_reflect.sh
```

## File structure

```
~/.claude/
├── memory_tools/
│   ├── claude_memory_log.py      ← session write
│   └── claude_memory_search.py   ← hybrid search
├── memory_vectors/
│   ├── claude_memory.db          ← sessions + self_evals
│   ├── vectors.db                ← 512d embeddings
│   ├── insights.md               ← weekly distilled patterns
│   └── latest_reflection.json    ← pending reflection notification
└── CLAUDE.md                     ← add snippet from CLAUDE.md.snippet
```

### Storage size

Each session: ~3 KB (2 KB vector + 1 KB metadata). One year of daily sessions ≈ 1–2 MB.

## Database schema

```sql
-- claude_memory.db
CREATE TABLE sessions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    date       TEXT NOT NULL,
    summary    TEXT NOT NULL,    -- English natural language summary
    projects   TEXT,             -- JSON list of project names
    tools_used TEXT,             -- JSON list of tools used
    vector_id  INTEGER           -- FK into vectors.db
);

CREATE TABLE self_evals (
    session_id INTEGER PRIMARY KEY REFERENCES sessions(id),
    verdict    TEXT,             -- good / mixed / wrong
    note       TEXT              -- short explanation
);
```

## Self-eval verdicts

| Verdict | Meaning |
|---------|---------|
| `good` | User required no corrections, task completed smoothly |
| `mixed` | 1–2 corrections needed but eventually resolved |
| `wrong` | Multiple corrections / user clearly unsatisfied / wrong direction |

The weekly reflection uses the distribution of verdicts to identify patterns and update `insights.md`.

## License

MIT
