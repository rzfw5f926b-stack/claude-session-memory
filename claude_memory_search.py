#!/usr/bin/env python3
"""
Claude session memory search — hybrid scoring (cosine + recency + complexity).

Hybrid score formula:
  score = 0.7 * cosine_similarity + 0.2 * recency + 0.1 * complexity
  recency    = 1 / (1 + days_ago / 30)   # 30 days ago → 0.5, 90 days ago → 0.25
  complexity = min(summary_len / 500, 1)  # longer summaries score slightly higher

Only results with score >= 0.5 are shown. Below threshold: silent exit.

Storage: $CLAUDE_MEMORY_DIR (default: ~/.claude/memory_vectors/)
Embed:   $CLAUDE_EMBED_URL  (default: http://localhost:11435/v1/embed)

Usage:
  python3 claude_memory_search.py --query "esun-sim-trader embedding" --top-k 3
"""
import argparse
import json
import os
import sqlite3
import urllib.request
from datetime import date, datetime
from pathlib import Path

import numpy as np

MEMORY_DIR = Path(os.environ.get("CLAUDE_MEMORY_DIR", Path.home() / ".claude" / "memory_vectors"))
CLAUDE_DB  = MEMORY_DIR / "claude_memory.db"
VECTORS_DB = MEMORY_DIR / "vectors.db"
EMBED_URL  = os.environ.get("CLAUDE_EMBED_URL", "http://localhost:11435/v1/embed")
DIM        = 512
THRESHOLD  = 0.5


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


# ── Hybrid score ───────────────────────────────────────────────────────────

def _hybrid_score(cosine_sim: float, session_date: str, summary_len: int) -> float:
    try:
        dt = datetime.strptime(session_date, "%Y-%m-%d").date()
        days_ago = (date.today() - dt).days
    except Exception:
        days_ago = 30
    recency    = 1.0 / (1 + days_ago / 30)
    complexity = min(summary_len / 500, 1.0)
    return 0.7 * cosine_sim + 0.2 * recency + 0.1 * complexity


# ── Search ─────────────────────────────────────────────────────────────────

def search(query: str, top_k: int = 3) -> list[dict]:
    if not VECTORS_DB.exists() or not CLAUDE_DB.exists():
        return []

    q_vec = _embed(query)
    qn = np.linalg.norm(q_vec)
    if qn == 0:
        return []
    q_norm = q_vec / qn

    conn_v = sqlite3.connect(VECTORS_DB)
    rows = conn_v.execute("SELECT id, text, embedding, meta FROM vectors").fetchall()
    conn_v.close()

    if not rows:
        return []

    ids, texts, metas, vecs = [], [], [], []
    for row_id, text, blob, meta_json in rows:
        v = np.frombuffer(blob, dtype=np.float32)
        if v.shape[0] != DIM:
            continue
        ids.append(row_id)
        texts.append(text)
        metas.append(json.loads(meta_json))
        vecs.append(v)

    mat = np.stack(vecs)
    norms = np.linalg.norm(mat, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1, norms)
    cosines = (mat / norms) @ q_norm

    conn_m = sqlite3.connect(CLAUDE_DB)
    session_rows = conn_m.execute("""
        SELECT s.vector_id, s.date, s.projects, s.summary,
               e.verdict, e.note
        FROM sessions s
        LEFT JOIN self_evals e ON e.session_id = s.id
    """).fetchall()
    conn_m.close()

    by_vid = {r[0]: r for r in session_rows}

    scored = []
    for i, (vid, cos) in enumerate(zip(ids, cosines)):
        row = by_vid.get(vid)
        if row is None:
            continue
        _, s_date, projects_json, summary, verdict, note = row
        score = _hybrid_score(float(cos), s_date, len(summary))
        if score < THRESHOLD:
            continue
        scored.append({
            "score":    round(score, 3),
            "cosine":   round(float(cos), 3),
            "date":     s_date,
            "summary":  summary,
            "projects": json.loads(projects_json or "[]"),
            "verdict":  verdict or "—",
            "note":     note or "",
        })

    scored.sort(key=lambda x: x["score"], reverse=True)
    return scored[:top_k]


# ── Main ───────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Search Claude session memory (hybrid scoring).")
    ap.add_argument("--query", required=True, help="Natural language query")
    ap.add_argument("--top-k", type=int, default=3, help="Max results to return (default: 3)")
    args = ap.parse_args()

    results = search(args.query, args.top_k)

    if not results:
        # Silent — no relevant memories found, threshold not met
        return

    print(f"🧠 找到 {len(results)} 條相關記憶（最近：{results[0]['date']} {results[0]['summary'][:50]}...）")
    print()
    for r in results:
        proj = ", ".join(r["projects"]) if r["projects"] else "—"
        print(f"[{r['date']} · {r['verdict']} · {proj}] score={r['score']}")
        print(f"  {r['summary'][:200]}")
        if r["note"]:
            print(f"  → {r['note']}")
        print()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import sys
        print(f"⚠️ 記憶搜尋失敗：{e}", file=sys.stderr)
        # Non-critical — search failure should not block session startup
