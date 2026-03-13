#!/bin/bash

run_cursor() {
    local AI_PROMPT="$1"
    local INTERACTIVE="${2:-yes}"

    if [ "$INTERACTIVE" = "no" ]; then
        echo "🤖 Asking Cursor to plan and implement (non-interactive)..."
        agent -p --force "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
        return 0
    fi

    echo ""
    read -p "Press Enter to continue with default model, or type 1 to select a model: " SHOW_MODELS
    if [ "$SHOW_MODELS" != "1" ]; then
        echo "🤖 Asking Cursor to plan and implement..."
        agent "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
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
        agent "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
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

    echo "🤖 Asking Cursor to plan and implement..."

    if [ -z "$MODEL" ] || [ "$IS_CURRENT" = true ]; then
        agent "$AI_PROMPT" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    else
        agent "$AI_PROMPT" --model "$MODEL" || { echo "❌ Error: Cursor CLI failed."; return 1; }
    fi
}
