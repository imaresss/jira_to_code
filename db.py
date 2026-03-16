#!/usr/bin/env python3
"""
db.py — SQLite session registry for jira_to_code.

Stores Cursor/Codex session IDs keyed by Jira ticket ID so sessions can be
resumed and their history retrieved without remembering the UUID.

DB location: ~/.jira_to_code/sessions.db

Commands
--------
  save <jira_id> <session_id> <ai_tool> [model] [project_path] [branch]
      Record a new session.

  get <jira_id>
      Print the session_id of the most recent session for the given Jira ID.
      Exits 0 with the UUID, or exits 1 (no output) if none found.

  list [jira_id]
      Print all sessions as tab-separated rows, newest first.
      If jira_id is given, filter to that ticket only.

Examples
--------
  python3 db.py save RS-129 22fe6962-... cursor composer-1.5 /path/to/repo main
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
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            jira_id      TEXT    NOT NULL,
            session_id   TEXT    NOT NULL,
            ai_tool      TEXT    NOT NULL,
            model        TEXT    DEFAULT '',
            project_path TEXT    DEFAULT '',
            branch       TEXT    DEFAULT '',
            created_at   INTEGER NOT NULL
        )
    """)
    conn.commit()
    return conn


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_save(args: list):
    if len(args) < 3:
        print("Usage: db.py save <jira_id> <session_id> <ai_tool> [model] [project_path] [branch]",
              file=sys.stderr)
        sys.exit(1)

    jira_id      = args[0]
    session_id   = args[1]
    ai_tool      = args[2]
    model        = args[3] if len(args) > 3 else ""
    project_path = args[4] if len(args) > 4 else ""
    branch       = args[5] if len(args) > 5 else ""

    conn = _connect()
    conn.execute(
        """INSERT INTO sessions
               (jira_id, session_id, ai_tool, model, project_path, branch, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (jira_id, session_id, ai_tool, model, project_path, branch, int(time.time()))
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
        "SELECT session_id FROM sessions WHERE jira_id = ? ORDER BY created_at DESC LIMIT 1",
        (jira_id,)
    ).fetchone()
    conn.close()

    if row:
        print(row["session_id"])
    else:
        sys.exit(1)  # no output, non-zero exit — easy to test in bash


def cmd_list(args: list):
    jira_filter = args[0] if args else None
    conn = _connect()

    if jira_filter:
        rows = conn.execute(
            """SELECT jira_id, session_id, ai_tool, model, project_path, branch,
                      datetime(created_at, 'unixepoch', 'localtime') AS ts
               FROM sessions WHERE jira_id = ? ORDER BY created_at DESC""",
            (jira_filter,)
        ).fetchall()
    else:
        rows = conn.execute(
            """SELECT jira_id, session_id, ai_tool, model, project_path, branch,
                      datetime(created_at, 'unixepoch', 'localtime') AS ts
               FROM sessions ORDER BY created_at DESC"""
        ).fetchall()
    conn.close()

    if not rows:
        print("No sessions recorded yet.")
        return

    header = ["JIRA_ID", "SESSION_ID", "TOOL", "MODEL", "PROJECT", "BRANCH", "CREATED_AT"]
    print("\t".join(header))
    print("-" * 100)
    for r in rows:
        print("\t".join(str(r[c] or "") for c in
                        ["jira_id", "session_id", "ai_tool", "model", "project_path", "branch", "ts"]))


# ── Entry point ───────────────────────────────────────────────────────────────

COMMANDS = {"save": cmd_save, "get": cmd_get, "list": cmd_list}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(1)

    COMMANDS[sys.argv[1]](sys.argv[2:])
