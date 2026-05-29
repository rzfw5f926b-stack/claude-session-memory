#!/usr/bin/env python3
"""
Claude session memory logger.
Writes a session summary + self-eval + 512d embedding to a local SQLite store.

Storage location (in priority order):
  1. $CLAUDE_MEMORY_DIR
  2. ~/.claude/memory_vectors/

Embedding endpoint: $CLAUDE_EMBED_URL (default: http://localhost:11435/v1/embed)
This expects a POST with {"text": "...", "language": "en"} and returns {"embedding": [...]}.
Compatible with macOSUtilityBridge (Apple NLEmbedding 512d) or any OpenAI-compatible embed server.

Usage:
  python3 claude_memory_log.py \\
    --summary "Implemented X feature, debugged Y, used Bash+Edit tools" \\
    --projects '["my-project"]' \\
    --tools '["Bash", "Edit", "Read"]' \\
    --verdict good \\
    --note "User accepted all changes without corrections"
"""
import argparse
import json
import os
import sqlite3
import urllib.request
import urllib.error
from datetime import date
from pathlib import Path

import numpy as np

MEMORY_DIR = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
CLAUDE_DB  = MEMORY_DIR / "claude_memory.db"
VECTORS_DB = MEMORY_DIR / "vectors.db"
EMBED_URL  = os.environ.get("CLAUDE_EMBED_URL", "http://localhost:11435/v1/embed")
DIM        = 512


# ── Embedding ──────────────────────────────────────────────────────────────

def _embed(text: str) -> np.ndarray:
    payload = json.dumps({"text": text, "language": "en"}).encode()
    req = urllib.request.Request(
        EMBED_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    if "error" in data:
        raise RuntimeError(f"Embedding error: {data['error']}")
    vec = np.array(data["embedding"], dtype=np.float32)
    if vec.shape[0] != DIM:
        raise RuntimeError(f"Unexpected embedding dim: {vec.shape[0]} (expected {DIM})")
    return vec


# ── Vector store ───────────────────────────────────────────────────────────

def _vec_conn() -> sqlite3.Connection:
    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(VECTORS_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS vectors (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            text      TEXT NOT NULL,
            embedding BLOB NOT NULL,
            meta      TEXT DEFAULT '{}'
        )
    """)
    conn.commit()
    return conn


def _store_vector(text: str, vec: np.ndarray, meta: dict) -> int:
    blob = vec.astype(np.float32).tobytes()
    with _vec_conn() as conn:
        cur = conn.execute(
            "INSERT INTO vectors (text, embedding, meta) VALUES (?, ?, ?)",
            (text, blob, json.dumps(meta)),
        )
        return cur.lastrowid


# ── Session DB ─────────────────────────────────────────────────────────────

def _mem_conn() -> sqlite3.Connection:
    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(CLAUDE_DB)
    conn.executescript("""
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
    """)
    conn.commit()
    return conn


def _store_session(date_str: str, summary: str, projects: list, tools: list, vector_id: int) -> int:
    with _mem_conn() as conn:
        cur = conn.execute(
            "INSERT INTO sessions (date, summary, projects, tools_used, vector_id) VALUES (?,?,?,?,?)",
            (date_str, summary, json.dumps(projects), json.dumps(tools), vector_id),
        )
        return cur.lastrowid


def _store_eval(session_id: int, verdict: str, note: str):
    with _mem_conn() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO self_evals (session_id, verdict, note) VALUES (?,?,?)",
            (session_id, verdict, note),
        )


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Log a Claude session to persistent memory.")
    ap.add_argument("--summary",  required=True, help="Natural language session summary (English)")
    ap.add_argument("--projects", default="[]",  help="JSON list of project names")
    ap.add_argument("--tools",    default="[]",  help="JSON list of tools used")
    ap.add_argument("--verdict",  default="good", choices=["good", "mixed", "wrong"],
                    help="Self-evaluation: good=smooth, mixed=minor corrections, wrong=wrong direction")
    ap.add_argument("--note",     default="",    help="Short explanation for self-eval verdict")
    args = ap.parse_args()

    projects = json.loads(args.projects)
    tools    = json.loads(args.tools)
    today    = date.today().isoformat()

    vec = _embed(args.summary)
    vid = _store_vector(args.summary, vec, {"date": today, "verdict": args.verdict})
    sid = _store_session(today, args.summary, projects, tools, vid)
    _store_eval(sid, args.verdict, args.note)

    proj_str = ", ".join(projects) if projects else "—"
    print(f"💾 記憶已寫入（#{sid} · {args.verdict} · {proj_str}）")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"⚠️ 記憶寫入失敗：{e}")
        raise SystemExit(1)
