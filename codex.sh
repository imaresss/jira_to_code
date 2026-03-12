#!/bin/bash

run_codex() {
    local AI_PROMPT="$1"

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    [ "$SHOW_MODELS" != "1" ] && { echo "🤖 Asking Codex to plan and implement..."; codex "$AI_PROMPT" || { echo "❌ Error: Codex CLI failed."; return 1; }; return 0; }

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
}
