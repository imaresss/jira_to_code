#!/bin/bash

# Save a Cursor session ID to the SQLite registry (best-effort, non-fatal).
_cursor_db_save() {
    local jira_id="$1" session_id="$2" model="${3:-}"
    [ -z "$session_id" ] || [ -z "$jira_id" ] && return
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/db.py" save "$jira_id" "$session_id" "cursor" "$model" 2>/dev/null || true
}

# Run an agent command, tee its output so the user sees it live, then grep
# the printed --resume UUID and store it in the DB.
_run_and_register() {
    local jira_id="$1"; shift
    local cursor_model="$1"; shift
    local tmp_out
    tmp_out=$(mktemp)

    # Forward all output to the terminal AND capture it
    "$@" 2>&1 | tee "$tmp_out"
    local exit_code=${PIPESTATUS[0]}

    local session_id
    session_id=$(grep -o 'agent --resume=[^ ]*' "$tmp_out" 2>/dev/null | head -1 | cut -d= -f2)
    rm -f "$tmp_out"

    if [ -n "$session_id" ] && [ -n "$jira_id" ]; then
        _cursor_db_save "$jira_id" "$session_id" "$cursor_model"
        echo "💾 Session $session_id saved for $jira_id"
    fi

    return "$exit_code"
}

run_cursor() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"
    local USE_DEFAULT_MODEL=$(echo "${3:-no}" | tr '[:upper:]' '[:lower:]')
    local JIRA_ID="${4:-}"

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Cursor to plan and implement (non-interactive)..."
        agent -p --force "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    # Session history capture for interactive runs (saved to ~/.jira_to_code/sessions/${JIRA_ID}_context.md)
    local HISTORY_DIR RAW_LOG CLEAN_CONTEXT
    if [ -n "$JIRA_ID" ]; then
        HISTORY_DIR="$HOME/.jira_to_code/sessions"
        mkdir -p "$HISTORY_DIR"
        RAW_LOG=$(mktemp 2>/dev/null || echo "/tmp/${JIRA_ID}_raw_session.$$.log")
        CLEAN_CONTEXT="$HISTORY_DIR/${JIRA_ID}_context.md"
        _run_captured() {
            script -q "$RAW_LOG" "$@"
            local ret=$?
            echo "" >> "$CLEAN_CONTEXT"
            echo "--- Session $(date -Iseconds 2>/dev/null || date) ---" >> "$CLEAN_CONTEXT"
            if command -v perl >/dev/null 2>&1; then
                perl -pe 's/\x1b\[[0-9;]*[mGKF]//g' "$RAW_LOG" 2>/dev/null | col -bp >> "$CLEAN_CONTEXT" 2>/dev/null || cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
            else
                cat "$RAW_LOG" >> "$CLEAN_CONTEXT"
            fi
            rm -f "$RAW_LOG"
            [ $ret -eq 0 ] && echo "📄 Session saved to $CLEAN_CONTEXT"
            return $ret
        }
        run_cursor_cmd() {
            local model_arg="${CURSOR_MODEL:-}"
            _run_and_register "$JIRA_ID" "$model_arg" _run_captured agent "$@"
        }
    else
        run_cursor_cmd() {
            _run_and_register "" "" agent "$@"
        }
    fi

    if [ "$USE_DEFAULT_MODEL" = "yes" ] || [ "$USE_DEFAULT_MODEL" = "true" ]; then
        echo "🤖 Asking Cursor to plan and implement..."
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    if [ "$SHOW_MODELS" != "1" ]; then
        echo "🤖 Asking Cursor to plan and implement..."
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
        echo "🤖 Asking Cursor to plan and implement..."
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

    # Expose selected model so _run_and_register can log it
    CURSOR_MODEL="$MODEL"

    echo "🤖 Asking Cursor to plan and implement..."

    if [ -z "$MODEL" ] || [ "$IS_CURRENT" = true ]; then
        run_cursor_cmd "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    else
        run_cursor_cmd "$AI_PROMPT" --model "$MODEL" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    fi
}
