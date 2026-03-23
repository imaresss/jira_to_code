#!/usr/bin/env python3
"""
get_session.py — Extract a clean summary of a Cursor agent session.

Usage:
    python3 get_session.py <sessionId>          # by --resume UUID
    python3 get_session.py --latest             # most recent session (any project)
    python3 get_session.py --jira <JIRA_ID>     # most recent session for a ticket
                                                  (requires db.py to have recorded it)
    python3 get_session.py --codex <sessionId>  # Codex session history by session id

Output: JSON with session metadata and a clean exchange of user queries
        and assistant responses (system noise stripped out).
"""

import sqlite3
import json
import sys
import os
import re
import glob
import shutil
import tempfile


# ── Helpers ──────────────────────────────────────────────────────────────────

def decode_meta(raw_value: str) -> dict:
    """Meta table values are stored as hex-encoded JSON."""
    try:
        return json.loads(bytes.fromhex(raw_value).decode("utf-8"))
    except Exception:
        try:
            return json.loads(raw_value)
        except Exception:
            return {}


def extract_user_query(content: str) -> str:
    """
    Pull the actual user query from a user message.
    User blobs contain a lot of system context (<user_info>, <agent_skills>, etc.)
    and the real question lives inside <user_query>...</user_query>.
    """
    match = re.search(r"<user_query>\s*(.*?)\s*</user_query>", content, re.DOTALL)
    if match:
        return match.group(1).strip()

    # Fallback: if there are no XML tags at all, the whole thing is the query
    if "<" not in content:
        return content.strip()

    return ""  # pure system-context blob — skip it


def extract_assistant_response(content) -> str:
    """
    Extract clean assistant response text.
    - Skips pure internal-reasoning entries (bold **Thinking…** paragraphs only)
    - For list content, picks only "text" parts (not "reasoning" type)
    """
    if isinstance(content, list):
        parts = []
        for part in content:
            if not isinstance(part, dict):
                continue
            # Skip internal chain-of-thought reasoning blobs
            if part.get("type") == "reasoning":
                continue
            if part.get("type") == "text":
                parts.append(part.get("text", "").strip())
        return "\n\n".join(p for p in parts if p)

    if isinstance(content, str):
        text = content.strip()
        # Heuristic: if every paragraph is a bold "**...**" heading (internal thinking),
        # skip this blob entirely — it is a reasoning-only entry.
        paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
        if paragraphs and all(
            re.match(r"^\*\*[^*]+\*\*$", p) or re.match(r"^\*\*[^*]+\*\*\n", p)
            for p in paragraphs
        ):
            return ""
        return text

    return ""


# ── Core ─────────────────────────────────────────────────────────────────────

def get_cursor_session_history(session_id: str) -> dict:
    pattern = os.path.expanduser(f"~/.cursor/chats/*/{session_id}/store.db")
    matches = glob.glob(pattern)

    if not matches:
        return {"error": f"Session '{session_id}' not found under ~/.cursor/chats/"}

    db_path = matches[0]

    # Copy to temp to avoid WAL lock issues on a live DB
    tmp_db = os.path.join(tempfile.gettempdir(), f"cursor_session_{session_id}.db")
    shutil.copy2(db_path, tmp_db)

    try:
        conn = sqlite3.connect(tmp_db)
        conn.row_factory = sqlite3.Row
        cur = conn.cursor()

        # Session metadata
        cur.execute("SELECT key, value FROM meta")
        meta_rows = {row["key"]: row["value"] for row in cur.fetchall()}
        meta = decode_meta(meta_rows.get("0", "{}"))

        # All message blobs
        cur.execute("SELECT data FROM blobs WHERE data LIKE '%\"role\"%'")
        rows = cur.fetchall()

        messages = []
        for row in rows:
            raw = row["data"]
            if not raw:
                continue
            try:
                msg = json.loads(raw)
            except Exception:
                continue

            role = msg.get("role")
            content = msg.get("content", "")

            if role == "user":
                # content may be a string or a list; normalise to string first
                if isinstance(content, list):
                    flat = " ".join(
                        p.get("text", "") for p in content
                        if isinstance(p, dict) and p.get("type") == "text"
                    )
                else:
                    flat = content
                text = extract_user_query(flat)

            elif role == "assistant":
                text = extract_assistant_response(content)

            else:
                continue

            if not text:
                continue

            messages.append({"role": role, "content": text})

        conn.close()
    finally:
        try:
            os.remove(tmp_db)
        except OSError:
            pass

    return {
        "sessionId": session_id,
        "name": meta.get("name"),
        "createdAt": meta.get("createdAt"),
        "model": meta.get("lastUsedModel"),
        "messages": messages,
    }


def _codex_find_session_file(session_id: str) -> str:
    """Find Codex session JSONL file by session id."""
    pattern = os.path.expanduser(f"~/.codex/sessions/**/rollout-*{session_id}*.jsonl")
    matches = glob.glob(pattern, recursive=True)
    return matches[0] if matches else ""


def _codex_get_thread_name(session_id: str) -> str:
    """Lookup Codex thread name from session_index.jsonl."""
    index_path = os.path.expanduser("~/.codex/session_index.jsonl")
    if not os.path.exists(index_path):
        return ""
    try:
        with open(index_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if row.get("id") == session_id:
                    return row.get("thread_name", "") or ""
    except Exception:
        return ""
    return ""


def _codex_extract_message_text(content) -> str:
    """
    Extract readable text from Codex message content.
    Codex message content is typically a list of {type, text} parts.
    """
    if isinstance(content, list):
        parts = []
        for part in content:
            if not isinstance(part, dict):
                continue
            part_type = part.get("type", "")
            if part_type in ("input_text", "output_text", "text"):
                text = (part.get("text") or "").strip()
                if text:
                    parts.append(text)
        return "\n\n".join(parts).strip()
    if isinstance(content, str):
        return content.strip()
    return ""


def _get_codex_history(session_id: str) -> dict:
    """Extract Codex session history by session id."""
    session_file = _codex_find_session_file(session_id)
    if not session_file:
        return {"error": f"Session '{session_id}' not found under ~/.codex/sessions/"}

    created_at = ""
    model = ""
    messages = []

    try:
        with open(session_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue

                obj_type = obj.get("type")
                if obj_type == "session_meta":
                    payload = obj.get("payload") or {}
                    created_at = payload.get("timestamp") or obj.get("timestamp") or created_at
                    continue

                if obj_type == "turn_context":
                    payload = obj.get("payload") or {}
                    model = payload.get("model") or model
                    continue

                if obj_type == "response_item":
                    payload = obj.get("payload") or {}
                    if payload.get("type") != "message":
                        continue
                    role = payload.get("role")
                    if role not in ("user", "assistant"):
                        continue
                    text = _codex_extract_message_text(payload.get("content"))
                    if text:
                        messages.append({"role": role, "content": text})
    except Exception as e:
        return {"error": f"Failed to read Codex session '{session_id}': {e}"}

    return {
        "sessionId": session_id,
        "name": _codex_get_thread_name(session_id),
        "createdAt": created_at,
        "model": model,
        "messages": messages,
    }


def get_session_history_for_assistant(assistant: str, session_id: str) -> dict:
    """
    Dispatch session history retrieval based on assistant/model.
    Keeps Cursor's implementation intact and adds Codex via a registry.
    """
    assistant = (assistant or "").strip().lower()
    handlers = {
        "cursor": get_cursor_session_history,
        "codex": _get_codex_history,
    }
    handler = handlers.get(assistant)
    if not handler:
        return {"error": f"Unknown assistant '{assistant}' (expected 'cursor' or 'codex')"}
    return handler(session_id)


# ── Lookup helpers ────────────────────────────────────────────────────────────

def get_latest_session_id() -> str:
    """Return the composerId of the most recently modified Cursor session."""
    pattern = os.path.expanduser("~/.cursor/chats/*/*/store.db")
    all_dbs = glob.glob(pattern)
    if not all_dbs:
        return ""
    all_dbs.sort(key=os.path.getmtime, reverse=True)
    return os.path.basename(os.path.dirname(all_dbs[0]))


def get_session_id_for_jira(jira_id: str) -> str:
    """Look up the most recent session ID for a Jira ticket via db.py's DB."""
    db_path = os.path.expanduser("~/.jira_to_code/sessions.db")
    if not os.path.exists(db_path):
        return ""
    try:
        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT session_id FROM sessions WHERE jira_id = ? ORDER BY created_at DESC LIMIT 1",
            (jira_id,)
        ).fetchone()
        conn.close()
        return row[0] if row else ""
    except Exception:
        return ""


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    args = sys.argv[1:]

    if not args:
        print(__doc__)
        sys.exit(1)

    if args[0] == "--latest":
        session_id = get_latest_session_id()
        if not session_id:
            print(json.dumps({"error": "No Cursor sessions found under ~/.cursor/chats/"}))
            sys.exit(1)

    elif args[0] == "--codex":
        if len(args) < 2:
            print("Usage: get_session.py --codex <sessionId>", file=sys.stderr)
            sys.exit(1)
        session_id = args[1].strip()
        result = get_session_history_for_assistant("codex", session_id)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        sys.exit(0)

    elif args[0] == "--jira":
        if len(args) < 2:
            print("Usage: get_session.py --jira <JIRA_ID>", file=sys.stderr)
            sys.exit(1)
        jira_id = args[1].strip()
        session_id = get_session_id_for_jira(jira_id)
        if not session_id:
            print(json.dumps({"error": f"No session recorded for '{jira_id}'. Run jira_to_code first."}))
            sys.exit(1)

    else:
        session_id = args[0].strip()

    result = get_cursor_session_history(session_id)
    print(json.dumps(result, indent=2, ensure_ascii=False))
