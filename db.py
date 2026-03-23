#!/usr/bin/env python3
"""
db.py — SQLite session registry for jira_to_code.

DB location: ~/.jira_to_code/sessions.db

Schema
------
  id                 INTEGER  PK AUTOINCREMENT
  jira_id            TEXT     NOT NULL
  session_id         TEXT     (cursor --resume UUID; empty for codex)
  ai_assistant       TEXT     NOT NULL  (codex | cursor)
  model              TEXT
  reasoning_effort   TEXT     (codex only: low | medium | high | extra-high)
  project_path       TEXT
  base_branch        TEXT
  additional_prompt  TEXT
  interactive        TEXT     (yes | no)
  created_at         INTEGER  unix timestamp
  updated_at         INTEGER  unix timestamp

Commands
--------
  save  --jira <id> --ai <tool> [--session <uuid>] [--model <m>]
        [--effort <e>] [--path <p>] [--branch <b>]
        [--extra-prompt <text>] [--interactive <yes|no>]
      Record a new session row.

  get <jira_id>
      Print the session_id of the most recent session for the given Jira ID.
      Exits 0 with the UUID, or exits 1 (no output) if none found.

  list [jira_id]
      Print all sessions as a formatted table, newest first.

Examples
--------
  python3 db.py save --jira RS-129 --ai cursor --session 22fe6962-... \\
                     --model composer-1.5 --path /repo --branch main \\
                     --interactive yes
  python3 db.py save --jira RS-129 --ai codex --model gpt-5.2-codex \\
                     --effort high --interactive yes
  python3 db.py get  RS-129
  python3 db.py list
  python3 db.py list RS-129
"""

import sqlite3
import sys
import os
import time
import json

DB_PATH = os.path.expanduser("~/.jira_to_code/sessions.db")


# ── DB bootstrap ─────────────────────────────────────────────────────────────

def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row

    # Check if table exists and whether it uses the old schema (has ai_tool column)
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "sessions" in tables:
        existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(sessions)")}
        if "ai_tool" in existing_cols and "ai_assistant" not in existing_cols:
            # Migrate old schema to new by rebuilding the table
            conn.executescript("""
                ALTER TABLE sessions RENAME TO sessions_old;

                CREATE TABLE sessions (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    jira_id           TEXT    NOT NULL,
                    session_id        TEXT    DEFAULT '',
                    ai_assistant      TEXT    NOT NULL DEFAULT '',
                    model             TEXT    DEFAULT '',
                    reasoning_effort  TEXT    DEFAULT '',
                    project_path      TEXT    DEFAULT '',
                    base_branch       TEXT    DEFAULT '',
                    additional_prompt TEXT    DEFAULT '',
                    interactive       TEXT    DEFAULT 'yes',
                    created_at        INTEGER NOT NULL DEFAULT 0,
                    updated_at        INTEGER NOT NULL DEFAULT 0
                );

                INSERT INTO sessions
                    (id, jira_id, session_id, ai_assistant, model,
                     project_path, base_branch, created_at, updated_at)
                SELECT
                    id, jira_id,
                    COALESCE(session_id, ''),
                    COALESCE(ai_tool, ''),
                    COALESCE(model, ''),
                    COALESCE(project_path, ''),
                    COALESCE(branch, ''),
                    created_at,
                    created_at
                FROM sessions_old;

                DROP TABLE sessions_old;
            """)
    else:
        conn.execute("""
            CREATE TABLE sessions (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                jira_id           TEXT    NOT NULL,
                session_id        TEXT    DEFAULT '',
                ai_assistant      TEXT    NOT NULL DEFAULT '',
                model             TEXT    DEFAULT '',
                reasoning_effort  TEXT    DEFAULT '',
                project_path      TEXT    DEFAULT '',
                base_branch       TEXT    DEFAULT '',
                additional_prompt TEXT    DEFAULT '',
                interactive       TEXT    DEFAULT 'yes',
                created_at        INTEGER NOT NULL DEFAULT 0,
                updated_at        INTEGER NOT NULL DEFAULT 0
            )
        """)

    # Create session_history table if it doesn't exist
    conn.execute("""
        CREATE TABLE IF NOT EXISTS session_history (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            sessions_id INTEGER NOT NULL REFERENCES sessions(id),
            conversation TEXT    DEFAULT '',
            summary      TEXT    DEFAULT ''
        )
    """)

    conn.commit()
    return conn


# ── Argument parser (lightweight, no argparse dependency) ────────────────────

def _parse_flags(args: list) -> dict:
    """Parse --key value pairs into a dict."""
    result = {}
    i = 0
    while i < len(args):
        if args[i].startswith("--"):
            key = args[i][2:]
            val = args[i + 1] if i + 1 < len(args) and not args[i + 1].startswith("--") else ""
            result[key] = val
            i += 2 if val else 1
        else:
            i += 1
    return result


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_save(args: list):
    flags = _parse_flags(args)

    jira_id = flags.get("jira", "").strip()
    if not jira_id:
        print("Error: --jira <jira_id> is required.", file=sys.stderr)
        sys.exit(1)

    ai_assistant      = flags.get("ai", "").strip()
    if not ai_assistant:
        print("Error: --ai <tool> is required (codex or cursor).", file=sys.stderr)
        sys.exit(1)

    now = int(time.time())
    conn = _connect()
    cur = conn.execute(
        """INSERT INTO sessions
               (jira_id, session_id, ai_assistant, model, reasoning_effort,
                project_path, base_branch, additional_prompt, interactive,
                created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            jira_id,
            flags.get("session", ""),
            ai_assistant,
            flags.get("model", ""),
            flags.get("effort", ""),
            flags.get("path", ""),
            flags.get("branch", ""),
            flags.get("extra-prompt", ""),
            flags.get("interactive", "yes"),
            now,
            now,
        )
    )
    conn.commit()
    inserted_id = cur.lastrowid
    conn.close()
    # Print the inserted id so callers (bash) can capture it
    print(inserted_id)


def cmd_save_history(args: list):
    """
    Fetch conversation history for a session and store it in session_history.

    Usage:
      db.py save-history --sessions-id <pk> --session-uuid <cursor_uuid>
      db.py save-history --sessions-id <pk> --assistant codex

    --sessions-id  : primary key of the sessions row (FK)
    --session-uuid : Cursor composerId / --resume UUID used to fetch the history
    --assistant    : codex | cursor (optional; if omitted uses cursor for back-compat)
    """
    flags = _parse_flags(args)

    sessions_id = flags.get("sessions-id", "").strip()
    session_uuid = flags.get("session-uuid", "").strip()
    assistant = (flags.get("assistant", "") or "cursor").strip().lower()

    if not sessions_id:
        print("Error: --sessions-id is required.", file=sys.stderr)
        sys.exit(1)

    if not session_uuid:
        # Nothing to fetch — insert a blank placeholder so the FK is recorded
        conn = _connect()
        conn.execute(
            "INSERT INTO session_history (sessions_id, conversation, summary) VALUES (?, ?, ?)",
            (int(sessions_id), "", "")
        )
        conn.commit()
        conn.close()
        return

    # Import get_session_history dispatcher from sibling get_session.py
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, script_dir)
    try:
        from get_session import get_session_history_for_assistant  # type: ignore
    except ImportError as e:
        print(f"Warning: could not import get_session.py: {e}", file=sys.stderr)
        return

    if assistant == "cursor":
        history = get_session_history_for_assistant("cursor", session_uuid)
    else:
        history = get_session_history_for_assistant("codex", session_uuid)
    conversation_json = json.dumps(history, ensure_ascii=False)

    conn = _connect()
    conn.execute(
        "INSERT INTO session_history (sessions_id, conversation, summary) VALUES (?, ?, ?)",
        (int(sessions_id), conversation_json, "")
    )
    conn.commit()
    conn.close()
    print(f"📚 History stored for sessions_id={sessions_id} (session={session_uuid})")


def cmd_update_history(args: list):
    """
    Fetch a fresh conversation snapshot and UPDATE the existing session_history
    row in-place. No new rows are inserted anywhere.

    Usage:
      db.py update-history --jira <jira_id> --session-uuid <cursor_uuid>
      db.py update-history --jira <jira_id> --session-uuid <codex_uuid> --assistant codex

    --jira         : Jira ticket ID used to look up the sessions row
    --session-uuid : Session UUID
    --assistant    : codex | cursor (optional; default cursor)
    """
    flags = _parse_flags(args)
    jira_id      = flags.get("jira", "").strip()
    session_uuid = flags.get("session-uuid", "").strip()
    assistant    = (flags.get("assistant", "") or "cursor").strip().lower()

    if not jira_id:
        print("Error: --jira is required.", file=sys.stderr)
        sys.exit(1)
    if not session_uuid:
        print("Error: --session-uuid is required.", file=sys.stderr)
        sys.exit(1)

    conn = _connect()

    # Find the sessions row PK that matches jira_id + session_id
    row = conn.execute(
        "SELECT id FROM sessions WHERE jira_id = ? AND session_id = ? ORDER BY created_at DESC LIMIT 1",
        (jira_id, session_uuid)
    ).fetchone()

    if not row:
        print(f"Error: No sessions row found for jira_id='{jira_id}' session_id='{session_uuid}'.",
              file=sys.stderr)
        conn.close()
        sys.exit(1)

    sessions_pk = row["id"]

    # Find the most recent session_history row for this sessions PK
    hist_row = conn.execute(
        "SELECT id FROM session_history WHERE sessions_id = ? ORDER BY id DESC LIMIT 1",
        (sessions_pk,)
    ).fetchone()

    # Fetch the updated conversation
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, script_dir)
    try:
        from get_session import get_session_history_for_assistant  # type: ignore
    except ImportError as e:
        print(f"Warning: could not import get_session.py: {e}", file=sys.stderr)
        conn.close()
        return

    history = get_session_history_for_assistant(assistant, session_uuid)
    conversation_json = json.dumps(history, ensure_ascii=False)

    if hist_row:
        conn.execute(
            "UPDATE session_history SET conversation = ? WHERE id = ?",
            (conversation_json, hist_row["id"])
        )
        print(f"📚 Updated session_history id={hist_row['id']} for sessions_id={sessions_pk} (session={session_uuid})")
    else:
        # Defensive: no history row exists yet — create the first one
        conn.execute(
            "INSERT INTO session_history (sessions_id, conversation, summary) VALUES (?, ?, ?)",
            (sessions_pk, conversation_json, "")
        )
        print(f"📚 Created first session_history entry for sessions_id={sessions_pk} (session={session_uuid})")

    conn.commit()
    conn.close()


def cmd_summarize_history(args: list):
    """
    Summarize the conversation stored in session_history using whichever AI
    assistant was recorded for that session (cursor → agent -p, codex →
    codex exec --full-auto) and write the result to the summary column —
    in-place update, no new rows.

    Usage:
      db.py summarize-history --sessions-id <pk>
      db.py summarize-history --jira <jira_id> --session-uuid <cursor_uuid>
    """
    import subprocess
    import re as _re

    flags = _parse_flags(args)
    sessions_id_str = flags.get("sessions-id", "").strip()
    jira_id         = flags.get("jira", "").strip()
    session_uuid    = flags.get("session-uuid", "").strip()

    conn = _connect()

    # Resolve the session_history row AND the ai_assistant for that session.
    # We JOIN session_history → sessions so both lookups return ai_assistant.
    if sessions_id_str:
        row = conn.execute(
            """SELECT sh.id AS hist_id, sh.conversation,
                      s.ai_assistant
               FROM session_history sh
               JOIN sessions s ON s.id = sh.sessions_id
               WHERE sh.sessions_id = ?
               ORDER BY sh.id DESC LIMIT 1""",
            (int(sessions_id_str),)
        ).fetchone()
    elif jira_id and session_uuid:
        row = conn.execute(
            """SELECT sh.id AS hist_id, sh.conversation,
                      s.ai_assistant
               FROM session_history sh
               JOIN sessions s ON s.id = sh.sessions_id
               WHERE s.jira_id = ? AND s.session_id = ?
               ORDER BY sh.id DESC LIMIT 1""",
            (jira_id, session_uuid)
        ).fetchone()
    else:
        print("Error: provide --sessions-id OR both --jira and --session-uuid.",
              file=sys.stderr)
        conn.close()
        sys.exit(1)

    if not row or not row["conversation"]:
        print("No conversation found to summarize.", file=sys.stderr)
        conn.close()
        return

    ai_assistant = (row["ai_assistant"] or "").strip().lower()
    if ai_assistant not in ("cursor", "codex"):
        print(f"Error: unknown ai_assistant '{ai_assistant}' — expected 'cursor' or 'codex'.",
              file=sys.stderr)
        conn.close()
        sys.exit(1)

    try:
        history = json.loads(row["conversation"])
    except Exception:
        print("Warning: could not parse conversation JSON.", file=sys.stderr)
        conn.close()
        return

    messages = history.get("messages", [])
    if not messages:
        print("No messages found in conversation.", file=sys.stderr)
        conn.close()
        return

    # Format conversation as readable text for the summarization prompt
    lines = []
    for msg in messages:
        role    = msg.get("role", "")
        content = msg.get("content", "").strip()
        if role and content:
            lines.append(f"{role.upper()}:\n{content}")
    conversation_text = "\n\n---\n\n".join(lines)

    # Truncate to avoid exceeding the AI's context window
    MAX_CHARS = 40_000
    if len(conversation_text) > MAX_CHARS:
        conversation_text = conversation_text[:MAX_CHARS] + "\n\n[... conversation truncated ...]"

    prompt = (
        "You are summarizing an AI coding session for future reference. "
        "Do NOT use any tools — output the summary text directly.\n\n"
        "Given the conversation below between a user and an AI coding assistant "
        "working on a Jira ticket, produce a concise technical summary "
        "(2-4 paragraphs) covering:\n"
        "- What was implemented or changed\n"
        "- Key files modified and why\n"
        "- Important decisions or trade-offs made\n"
        "- Any known issues, blockers, or follow-up items\n\n"
        f"Conversation:\n{conversation_text}\n\nSummary:"
    )

    # Dispatch to the same AI assistant that was used for the session
    if ai_assistant == "cursor":
        cmd = ["agent", "-p", prompt, "--force"]
        cli_name = "Cursor agent"
    else:  # codex
        cmd = ["codex", "exec", "--full-auto", prompt]
        cli_name = "Codex"

    print(f"🤖 Summarizing via {cli_name}...")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=180,
        )
        raw_output = result.stdout.strip() or result.stderr.strip()
    except FileNotFoundError:
        print(f"Error: '{cmd[0]}' command not found. Is {cli_name} CLI installed?",
              file=sys.stderr)
        conn.close()
        return
    except subprocess.TimeoutExpired:
        print(f"Warning: {cli_name} summarization timed out after 180 s.", file=sys.stderr)
        conn.close()
        return
    except Exception as e:
        print(f"Warning: {cli_name} summarization failed: {e}", file=sys.stderr)
        conn.close()
        return

    if not raw_output:
        print(f"Warning: no summary output received from {cli_name}.", file=sys.stderr)
        conn.close()
        return

    # Strip ANSI escape codes
    summary = _re.sub(r'\x1b\[[0-9;]*[mGKHFJ]', '', raw_output).strip()

    conn.execute(
        "UPDATE session_history SET summary = ? WHERE id = ?",
        (summary, row["hist_id"])
    )
    conn.commit()
    conn.close()
    print(f"✅ Summary stored for history_id={row['hist_id']} (via {cli_name})")


def cmd_update_session(args: list):
    """Update session_id for the most recent row matching jira_id + ai_assistant."""
    flags = _parse_flags(args)
    jira_id    = flags.get("jira", "").strip()
    session_id = flags.get("session", "").strip()
    if not jira_id or not session_id:
        print("Error: --jira and --session are required.", file=sys.stderr)
        sys.exit(1)

    now = int(time.time())
    conn = _connect()
    conn.execute(
        """UPDATE sessions SET session_id = ?, updated_at = ?
           WHERE id = (
               SELECT id FROM sessions WHERE jira_id = ?
               ORDER BY created_at DESC LIMIT 1
           )""",
        (session_id, now, jira_id)
    )
    conn.commit()
    conn.close()


def cmd_get(args: list):
    if not args:
        print("Usage: db.py get <jira_id>", file=sys.stderr)
        sys.exit(1)

    jira_id = args[0]
    conn = _connect()
    row = conn.execute(
        "SELECT session_id FROM sessions WHERE jira_id = ? AND session_id != '' ORDER BY created_at DESC LIMIT 1",
        (jira_id,)
    ).fetchone()
    conn.close()

    if row:
        print(row["session_id"])
    else:
        sys.exit(1)


def cmd_list(args: list):
    jira_filter = args[0] if args else None
    conn = _connect()

    query = """
        SELECT id, jira_id, session_id, ai_assistant, model, reasoning_effort,
               project_path, base_branch, additional_prompt, interactive,
               datetime(created_at, 'unixepoch', 'localtime') AS created,
               datetime(updated_at, 'unixepoch', 'localtime') AS updated
        FROM sessions
        {where}
        ORDER BY created_at DESC
    """
    if jira_filter:
        rows = conn.execute(query.format(where="WHERE jira_id = ?"), (jira_filter,)).fetchall()
    else:
        rows = conn.execute(query.format(where="")).fetchall()
    conn.close()

    if not rows:
        print("No sessions recorded yet.")
        return

    cols = ["id", "jira_id", "session_id", "ai_assistant", "model",
            "reasoning_effort", "project_path", "base_branch",
            "additional_prompt", "interactive", "created", "updated"]
    headers = ["ID", "JIRA_ID", "SESSION_ID", "AI", "MODEL",
               "EFFORT", "PROJECT", "BRANCH", "EXTRA_PROMPT", "INTERACTIVE",
               "CREATED_AT", "UPDATED_AT"]

    print("\t".join(headers))
    print("-" * 140)
    for r in rows:
        print("\t".join(str(r[c] or "") for c in cols))


# ── Entry point ───────────────────────────────────────────────────────────────

COMMANDS = {
    "save":               cmd_save,
    "save-history":       cmd_save_history,
    "update-history":     cmd_update_history,
    "summarize-history":  cmd_summarize_history,
    "update-session":     cmd_update_session,
    "get":                cmd_get,
    "list":               cmd_list,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(1)

    COMMANDS[sys.argv[1]](sys.argv[2:])
