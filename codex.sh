#!/bin/bash

run_codex() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"
    local USE_DEFAULT_MODEL=$(echo "${3:-no}" | tr '[:upper:]' '[:lower:]')
    local JIRA_ID="${4:-}"

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Codex to plan and implement (non-interactive)..."
        codex exec --full-auto "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
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
        run_codex_cmd() { _run_captured codex "$@"; }
    else
        run_codex_cmd() { codex "$@"; }
    fi

    if [ "$USE_DEFAULT_MODEL" = "yes" ] || [ "$USE_DEFAULT_MODEL" = "true" ]; then
        echo "🤖 Asking Codex to plan and implement..."
        run_codex_cmd "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
        return 0
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    [ "$SHOW_MODELS" != "1" ] && { echo "🤖 Asking Codex to plan and implement..."; run_codex_cmd "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }; return 0; }

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
        run_codex_cmd "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    elif [ -n "$EFFORT" ]; then
        run_codex_cmd --model "$MODEL" -c model_reasoning_effort="$EFFORT" "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    else
        run_codex_cmd --model "$MODEL" "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }
    fi
}
