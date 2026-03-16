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
    conn.execute(
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
    conn.close()


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
    "save":           cmd_save,
    "update-session": cmd_update_session,
    "get":            cmd_get,
    "list":           cmd_list,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(1)

    COMMANDS[sys.argv[1]](sys.argv[2:])
