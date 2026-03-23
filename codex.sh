#!/bin/bash

# Save a Codex session entry to the SQLite registry and fetch history (best-effort, non-fatal).
# Usage: _codex_db_save <jira_id> <session_id> <model> <reasoning_effort> <project_path> <base_branch> <extra_prompt> <interactive>
_codex_db_save() {
    local jira_id="$1"
    local session_id="$2"
    local model="$3"
    local effort="$4"
    local project_path="$5"
    local base_branch="$6"
    local extra_prompt="$7"
    local interactive="$8"
    [ -z "$jira_id" ] && return
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local inserted_id
    inserted_id=$(python3 "$script_dir/db.py" save \
        --jira        "$jira_id" \
        --ai          "codex" \
        --session     "$session_id" \
        --model       "$model" \
        --effort      "$effort" \
        --path        "$project_path" \
        --branch      "$base_branch" \
        --extra-prompt "$extra_prompt" \
        --interactive "$interactive" \
        2>/dev/null) || true

    # Fetch conversation history and store in session_history (codex)
    if [ -n "$inserted_id" ]; then
        python3 "$script_dir/db.py" save-history \
            --sessions-id  "$inserted_id" \
            --assistant    "codex" \
            --session-uuid "$session_id" \
            2>/dev/null || true

        if [ -n "$session_id" ]; then
            echo "📝 Summarizing session history..."
            (python3 "$script_dir/db.py" summarize-history \
                --sessions-id "$inserted_id" \
                2>/dev/null) &
        fi
    fi
}

_codex_latest_session_id_since() {
    local marker_file="$1"
    local newest_file=""
    newest_file=$(find "$HOME/.codex/sessions" -name "rollout-*.jsonl" -newer "$marker_file" \
        -exec stat -f "%m %N" {} \; 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
    if [ -n "$newest_file" ]; then
        local base
        base=$(basename "$newest_file")
        # Extract full UUID from filename, e.g. rollout-...-<uuid>.jsonl
        echo "$base" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
    else
        echo ""
    fi
}

_codex_finalize_run() {
    local exit_code="$1"
    local marker_file="$2"
    local jira_id="$3"
    local session_model="$4"
    local session_effort="$5"
    local project_path="$6"
    local base_branch="$7"
    local extra_prompt="$8"
    local interactive="$9"

    local session_id
    session_id=$(_codex_latest_session_id_since "$marker_file")
    _codex_db_save "$jira_id" "$session_id" "$session_model" "$session_effort" \
        "$project_path" "$base_branch" "$extra_prompt" "$interactive"
    rm -f "$marker_file"
    return "$exit_code"
}

run_codex() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"
    local USE_DEFAULT_MODEL=$(echo "${3:-no}" | tr '[:upper:]' '[:lower:]')
    local JIRA_ID="${4:-}"
    local PROJECT_PATH="${5:-}"
    local BASE_BRANCH="${6:-}"
    local EXTRA_PROMPT="${7:-}"

    # Marker file used to identify which Codex rollout file was created by this run
    local marker_file
    marker_file=$(mktemp)

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Codex to plan and implement (non-interactive)..."
        codex exec --full-auto "$AI_PROMPT"
        local ret=$?
        [ $ret -ne 0 ] && echo "❌ Error: Codex CLI failed."
        _codex_finalize_run "$ret" "$marker_file" "$JIRA_ID" "" "" \
            "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "no"
        return $?
    fi

    if [ "$USE_DEFAULT_MODEL" = "yes" ] || [ "$USE_DEFAULT_MODEL" = "true" ]; then
        echo "🤖 Asking Codex to plan and implement..."
        codex "$AI_PROMPT"
        local ret=$?
        [ $ret -ne 0 ] && echo "❌ Error: Codex CLI failed."
        _codex_finalize_run "$ret" "$marker_file" "$JIRA_ID" "" "" \
            "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
        return $?
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    if [ "$SHOW_MODELS" != "1" ]; then
        echo "🤖 Asking Codex to plan and implement..."
        codex "$AI_PROMPT"
        local ret=$?
        [ $ret -ne 0 ] && echo "❌ Error: Codex CLI failed."
        _codex_finalize_run "$ret" "$marker_file" "$JIRA_ID" "" "" \
            "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
        return $?
    fi

    echo ""
    echo "Select a Codex model:"
    echo "  1) gpt-5.3-codex"
    echo "  2) gpt-5.2-codex"
    echo "  3) gpt-5.2"
    echo "  4) gpt-5.1-codex-max"
    echo "  5) gpt-5.1-codex-mini"
    read -p "Select model (1-5) [Press Enter to skip]: " MODEL_CHOICE

    local MODEL=""
    local IS_MINI=false

    case "$MODEL_CHOICE" in
        "")  MODEL="" ;;
        1)   MODEL="gpt-5.3-codex" ;;
        2)   MODEL="gpt-5.2-codex" ;;
        3)   MODEL="gpt-5.2" ;;
        4)   MODEL="gpt-5.1-codex-max" ;;
        5)   MODEL="gpt-5.1-codex-mini"; IS_MINI=true ;;
        *)   echo "❌ Error: Invalid model selection."; return 1 ;;
    esac

    local EFFORT=""

    if [ -n "$MODEL_CHOICE" ]; then
        echo ""
        if [ "$IS_MINI" = true ]; then
            echo "Select reasoning effort:"
            echo "  1) Medium"
            echo "  2) High"
            read -p "Select effort (1-2) [Press Enter to skip]: " EFFORT_CHOICE
            case "$EFFORT_CHOICE" in
                "")  EFFORT="" ;;
                1)   EFFORT="medium" ;;
                2)   EFFORT="high" ;;
                *)   echo "❌ Error: Invalid reasoning effort selection."; return 1 ;;
            esac
        else
            echo "Select reasoning effort:"
            echo "  1) Low"
            echo "  2) Medium"
            echo "  3) High"
            echo "  4) Extra High"
            read -p "Select effort (1-4) [Press Enter to skip]: " EFFORT_CHOICE
            case "$EFFORT_CHOICE" in
                "")  EFFORT="" ;;
                1)   EFFORT="low" ;;
                2)   EFFORT="medium" ;;
                3)   EFFORT="high" ;;
                4)   EFFORT="extra-high" ;;
                *)   echo "❌ Error: Invalid reasoning effort selection."; return 1 ;;
            esac
        fi
    fi

    echo "🤖 Asking Codex to plan and implement..."

    if [ -z "$MODEL" ]; then
        codex "$AI_PROMPT"
    elif [ -n "$EFFORT" ]; then
        codex --model "$MODEL" -c model_reasoning_effort="$EFFORT" "$AI_PROMPT"
    else
        codex --model "$MODEL" "$AI_PROMPT"
    fi
    local ret=$?
    [ $ret -ne 0 ] && echo "❌ Error: Codex CLI failed."
    _codex_finalize_run "$ret" "$marker_file" "$JIRA_ID" "$MODEL" "$EFFORT" \
        "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
    return $?
}

# Resume an existing Codex session and update its history in the DB.
# Usage: run_codex_resume <prev_session_uuid> <jira_id> <project_path> <base_branch>
run_codex_resume() {
    local PREV_SESSION="$1"
    local JIRA_ID="$2"
    local PROJECT_PATH="$3"
    local BASE_BRANCH="$4"

    echo "▶️  Resuming Codex session $PREV_SESSION..."
    codex resume "$PREV_SESSION"
    local ret=$?

    # Update the existing session_history row with fresh conversation — no new rows.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/db.py" update-history \
        --jira         "$JIRA_ID" \
        --session-uuid "$PREV_SESSION" \
        --assistant    "codex" \
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

    return "$ret"
}
