#!/bin/bash

# Save a Codex session entry to the SQLite registry (best-effort, non-fatal).
# Usage: _codex_db_save <jira_id> <model> <reasoning_effort> <project_path> <base_branch> <extra_prompt> <interactive>
_codex_db_save() {
    local jira_id="$1"
    local model="$2"
    local effort="$3"
    local project_path="$4"
    local base_branch="$5"
    local extra_prompt="$6"
    local interactive="$7"
    [ -z "$jira_id" ] && return
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$script_dir/db.py" save \
        --jira        "$jira_id" \
        --ai          "codex" \
        --model       "$model" \
        --effort      "$effort" \
        --path        "$project_path" \
        --branch      "$base_branch" \
        --extra-prompt "$extra_prompt" \
        --interactive "$interactive" \
        2>/dev/null || true
}

run_codex() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"
    local USE_DEFAULT_MODEL=$(echo "${3:-no}" | tr '[:upper:]' '[:lower:]')
    local JIRA_ID="${4:-}"
    local PROJECT_PATH="${5:-}"
    local BASE_BRANCH="${6:-}"
    local EXTRA_PROMPT="${7:-}"

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Codex to plan and implement (non-interactive)..."
        codex exec --full-auto "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
        _codex_db_save "$JIRA_ID" "" "" "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "no"
        return 0
    fi

    if [ "$USE_DEFAULT_MODEL" = "yes" ] || [ "$USE_DEFAULT_MODEL" = "true" ]; then
        echo "🤖 Asking Codex to plan and implement..."
        codex "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
        _codex_db_save "$JIRA_ID" "" "" "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
        return 0
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    if [ "$SHOW_MODELS" != "1" ]; then
        echo "🤖 Asking Codex to plan and implement..."
        codex "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
        _codex_db_save "$JIRA_ID" "" "" "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
        return 0
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
        codex "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    elif [ -n "$EFFORT" ]; then
        codex --model "$MODEL" -c model_reasoning_effort="$EFFORT" "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    else
        codex --model "$MODEL" "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    fi

    _codex_db_save "$JIRA_ID" "$MODEL" "$EFFORT" "$PROJECT_PATH" "$BASE_BRANCH" "$EXTRA_PROMPT" "yes"
}
