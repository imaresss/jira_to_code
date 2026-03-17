#!/bin/bash

# Save a Cursor session entry to the SQLite registry and immediately fetch +
# store the conversation history in session_history (best-effort, non-fatal).
# Usage: _cursor_db_save <jira_id> <session_id> <model> <project_path> <base_branch> <extra_prompt> <interactive>
_cursor_db_save() {
    local jira_id="$1"
    local session_id="$2"
    local model="$3"
    local project_path="$4"
    local base_branch="$5"
    local extra_prompt="$6"
    local interactive="$7"
    [ -z "$jira_id" ] && return

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Save session row; db.py prints the inserted primary key to stdout
    local inserted_id
    inserted_id=$(python3 "$script_dir/db.py" save \
        --jira        "$jira_id" \
        --ai          "cursor" \
        --session     "$session_id" \
        --model       "$model" \
        --path        "$project_path" \
        --branch      "$base_branch" \
        --extra-prompt "$extra_prompt" \
        --interactive "$interactive" \
        2>/dev/null) || true

    # Fetch conversation history and store in session_history (cursor only)
    if [ -n "$inserted_id" ]; then
        python3 "$script_dir/db.py" save-history \
            --sessions-id  "$inserted_id" \
            --session-uuid "$session_id" \
            2>/dev/null || true

        # Summarize the stored conversation in the background (non-blocking)
        if [ -n "$session_id" ]; then
            echo "📝 Summarizing session history..."
            (python3 "$script_dir/db.py" summarize-history \
                --sessions-id "$inserted_id" \
                2>/dev/null) &
        fi
    fi
}

# Extract the --resume UUID from captured output (strips ANSI codes first).
_extract_resume_id() {
    local file="$1"
    perl -pe 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$file" 2>/dev/null \
        | grep -o 'agent --resume=[^ ]*' \
        | head -1 \
        | cut -d= -f2
}

# Resume an existing Cursor session and update its history in the DB.
# Usage: run_cursor_resume <prev_session_uuid> <jira_id> <project_path> <base_branch>
run_cursor_resume() {
    local PREV_SESSION="$1"
    local JIRA_ID="$2"
    local PROJECT_PATH="$3"
    local BASE_BRANCH="$4"

    local HISTORY_DIR RAW_LOG CLEAN_CONTEXT
    HISTORY_DIR="$HOME/.jira_to_code/sessions"
    mkdir -p "$HISTORY_DIR"
    RAW_LOG=$(mktemp 2>/dev/null || echo "/tmp/cursor_raw_session.$$.log")

    if [ -n "$JIRA_ID" ]; then
        CLEAN_CONTEXT="$HISTORY_DIR/${JIRA_ID}_context.md"
    else
        CLEAN_CONTEXT=""
    fi

    echo "▶️  Resuming session $PREV_SESSION..."
    script -q "$RAW_LOG" agent --resume="$PREV_SESSION"
    local ret=$?

    # Append cleaned transcript to the .md history file
    if [ -n "$CLEAN_CONTEXT" ]; then
        echo "" >> "$CLEAN_CONTEXT"
        echo "--- Resumed Session $(date -Iseconds 2>/dev/null || date) ---" >> "$CLEAN_CONTEXT"
        if command -v perl >/dev/null 2>&1; then
            perl -pe 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$RAW_LOG" 2>/dev/null \
                | col -bp >> "$CLEAN_CONTEXT" 2>/dev/null \
                || cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
        else
            cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
        fi
        echo "📄 Resumed session transcript saved to $CLEAN_CONTEXT"
    fi

    # Update the existing session_history row with fresh conversation — no new rows.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/db.py" update-history \
        --jira         "$JIRA_ID" \
        --session-uuid "$PREV_SESSION" \
        2>/dev/null || true
    [ -n "$PREV_SESSION" ] && echo "💾 Session history updated for $PREV_SESSION ($JIRA_ID)"

    # Re-summarize the updated conversation in the background (non-blocking)
    if [ -n "$JIRA_ID" ] && [ -n "$PREV_SESSION" ]; then
        echo "📝 Summarizing session history..."
        (python3 "$script_dir/db.py" summarize-history \
            --jira         "$JIRA_ID" \
            --session-uuid "$PREV_SESSION" \
            2>/dev/null) &
    fi

    rm -f "$RAW_LOG"
    return "$ret"
}

run_cursor() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"
    local USE_DEFAULT_MODEL=$(echo "${3:-no}" | tr '[:upper:]' '[:lower:]')
    local JIRA_ID="${4:-}"
    local PROJECT_PATH="${5:-}"
    local BASE_BRANCH="${6:-}"
    local EXTRA_PROMPT="${7:-}"

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Cursor to plan and implement (non-interactive)..."

        # Drop a timestamp marker so we can identify which store.db was created
        # by this specific agent run (Cursor doesn't print a --resume UUID in
        # non-interactive mode, but it still writes a session to disk).
        local marker_file
        marker_file=$(mktemp)

        agent -p  "$AI_PROMPT" --force
        local agent_exit=$?

        # Find the store.db created/modified after our marker — that is this session.
        local non_interactive_session_id=""
        local newest_db
        newest_db=$(find "$HOME/.cursor/chats" -name "store.db" -newer "$marker_file" \
                    -exec stat -f "%m %N" {} \; 2>/dev/null \
                    | sort -rn | head -1 | awk '{print $2}')
        rm -f "$marker_file"

        if [ -n "$newest_db" ]; then
            non_interactive_session_id=$(basename "$(dirname "$newest_db")")
            echo "🔍 Non-interactive session ID: $non_interactive_session_id"
        fi

        _cursor_db_save "$JIRA_ID" "$non_interactive_session_id" "" \
            "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "no"

        [ $agent_exit -ne 0 ] && { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    # For interactive runs: record the session via `script`, extract the
    # --resume UUID from the captured log, save to DB and .md history.
    local HISTORY_DIR RAW_LOG CLEAN_CONTEXT
    HISTORY_DIR="$HOME/.jira_to_code/sessions"
    mkdir -p "$HISTORY_DIR"
    RAW_LOG=$(mktemp 2>/dev/null || echo "/tmp/cursor_raw_session.$$.log")

    if [ -n "$JIRA_ID" ]; then
        CLEAN_CONTEXT="$HISTORY_DIR/${JIRA_ID}_context.md"
    else
        CLEAN_CONTEXT=""
    fi

    # Wraps an `agent …` invocation with `script` for capture, then:
    #   1. Appends cleaned transcript to the .md history file (if JIRA_ID set)
    #   2. Extracts --resume UUID and saves full session record to DB
    run_cursor_cmd() {
        echo "🤖 Asking Cursor to plan and implement..."
        script -q "$RAW_LOG" agent "$@"
        local ret=$?

        # ── History .md ──────────────────────────────────────────────────────
        if [ -n "$CLEAN_CONTEXT" ]; then
            echo "" >> "$CLEAN_CONTEXT"
            echo "--- Session $(date -Iseconds 2>/dev/null || date) ---" >> "$CLEAN_CONTEXT"
            if command -v perl >/dev/null 2>&1; then
                perl -pe 's/\x1b\[[0-9;]*[mGKHF]//g; s/\r//g' "$RAW_LOG" 2>/dev/null \
                    | col -bp >> "$CLEAN_CONTEXT" 2>/dev/null \
                    || cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
            else
                cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
            fi
            echo "📄 Session transcript saved to $CLEAN_CONTEXT"
        fi

        # ── DB registration ──────────────────────────────────────────────────
        local session_id=""
        if [ -n "$JIRA_ID" ]; then
            session_id=$(_extract_resume_id "$RAW_LOG")
            _cursor_db_save \
                "$JIRA_ID" \
                "$session_id" \
                "${CURSOR_MODEL:-}" \
                "$PROJECT_PATH" \
                "$BASE_BRANCH" \
                "$EXTRA_PROMPT" \
                "yes"
            [ -n "$session_id" ] && echo "💾 Session $session_id saved for $JIRA_ID"
        fi

        rm -f "$RAW_LOG"
        return "$ret"
    }

    if [ "$USE_DEFAULT_MODEL" = "yes" ] || [ "$USE_DEFAULT_MODEL" = "true" ]; then
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    if [ "$SHOW_MODELS" != "1" ]; then
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    echo ""
    echo "Fetching available Cursor models..."

    # Provide /dev/null as stdin to prevent agent from detecting a tty
    # and writing its own formatted output directly to the terminal
    local MODEL_LIST
    MODEL_LIST=$(agent --list-models </dev/null 2>/dev/null)

    if [ -z "$MODEL_LIST" ] || echo "$MODEL_LIST" | grep -qi "no models available"; then
        echo "⚠️  No models available. Proceeding with default."
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    echo ""
    echo "Select a Cursor model:"
    local i=1
    local MODELS=()       # model IDs only (e.g. composer-1.5)
    local MODELS_FULL=()  # full display lines (e.g. composer-1.5 - Composer 1.5)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Strip any leading "  N) " numbering the command may include
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*)[[:space:]]*//')
        [ -z "$stripped" ] && continue
        # Skip header lines (start with uppercase) and tip/info lines
        [[ "$stripped" =~ ^[A-Z] ]] && continue
        [[ "$stripped" =~ ^[Tt]ip: ]] && continue
        # Extract just the model ID (everything before " - ")
        local model_id
        model_id=$(echo "$stripped" | sed 's/ - .*//' | xargs)
        [ -z "$model_id" ] && continue
        MODELS+=("$model_id")
        MODELS_FULL+=("$stripped")
        echo "  $i) $stripped"
        ((i++))
    done <<< "$MODEL_LIST"

    local MAX=${#MODELS[@]}
    read -p "Select model (1-$MAX) [Press Enter to skip]: " MODEL_CHOICE

    local MODEL=""
    local IS_CURRENT=false
    if [ -z "$MODEL_CHOICE" ]; then
        MODEL=""
    elif [[ "$MODEL_CHOICE" =~ ^[0-9]+$ ]] && [ "$MODEL_CHOICE" -ge 1 ] && [ "$MODEL_CHOICE" -le "$MAX" ]; then
        MODEL="${MODELS[$((MODEL_CHOICE - 1))]}"
        # If the selected entry is marked (current), use the default agent call
        [[ "${MODELS_FULL[$((MODEL_CHOICE - 1))]}" == *"(current)"* ]] && IS_CURRENT=true
    else
        echo "❌ Error: Invalid model selection."
        return 1
    fi

    # Expose selected model so run_cursor_cmd can log it
    CURSOR_MODEL="$MODEL"

    if [ -z "$MODEL" ] || [ "$IS_CURRENT" = true ]; then
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    else
        run_cursor_cmd "$AI_PROMPT" --model "$MODEL" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    fi
}
