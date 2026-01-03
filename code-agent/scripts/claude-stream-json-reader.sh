#!/bin/bash
# Stream JSON Reader for Claude Code CLI output
#
# Converts stream-json format to human-readable output.
# Usage: claude --output-format stream-json --verbose -p "task" | claude-stream-json-reader.sh
#
# Key principle: Never swallow unknown output - if a line cannot be parsed,
# print it as-is to ensure no information is lost.

set -euo pipefail

# Colors (ANSI escape codes)
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
MAGENTA='\033[35m'

# Box drawing characters
BOX_TL='╭'
BOX_TR='╮'
BOX_BL='╰'
BOX_BR='╯'
BOX_H='─'
BOX_V='│'

# Track state for streaming messages
current_session=""
in_text_stream=false
turn_count=0

# Print a separator line
print_separator() {
    echo -e "${DIM}────────────────────────────────────────${RESET}"
}

# Print session header
print_session_header() {
    local session_id="$1"
    local model="$2"
    local cwd="$3"
    local width=64
    local line=$(printf '%*s' $((width - 2)) '' | tr ' ' "$BOX_H")

    echo -e "${CYAN}${BOX_TL}${line}${BOX_TR}${RESET}"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "Session: ${session_id:0:40}"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "Model: $model"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "CWD: ${cwd:0:50}"
    echo -e "${CYAN}${BOX_BL}${line}${BOX_BR}${RESET}"
    echo
}

# Format system/init message
format_init() {
    local json="$1"
    local session_id model cwd

    session_id=$(echo "$json" | jq -r '.session_id // "unknown"')
    model=$(echo "$json" | jq -r '.model // "unknown"')
    cwd=$(echo "$json" | jq -r '.cwd // "unknown"')

    current_session="$session_id"
    print_session_header "$session_id" "$model" "$cwd"
}

# Format assistant message
format_assistant() {
    local json="$1"
    local content_array

    # End any ongoing text stream first
    if [[ "$in_text_stream" == "true" ]]; then
        echo
        in_text_stream=false
    fi

    ((turn_count++))
    echo -e "${DIM}[Turn $turn_count]${RESET}"

    # Get the content array
    content_array=$(echo "$json" | jq -c '.message.content // []')

    # Process each content item
    echo "$content_array" | jq -c '.[]' 2>/dev/null | while IFS= read -r item; do
        local item_type
        item_type=$(echo "$item" | jq -r '.type // "unknown"')

        case "$item_type" in
            "text")
                local text
                text=$(echo "$item" | jq -r '.text // ""')
                if [[ -n "$text" ]]; then
                    echo -e "\n${GREEN}${BOLD}[ASSISTANT]${RESET}"
                    echo "$text"
                fi
                ;;
            "tool_use")
                local tool_name tool_id input description command path
                tool_name=$(echo "$item" | jq -r '.name // "unknown"')
                tool_id=$(echo "$item" | jq -r '.id // ""')
                input=$(echo "$item" | jq -r '.input // {}')

                echo -e "\n${YELLOW}${BOLD}[TOOL] ${tool_name}${RESET}"

                # Extract common input parameters
                description=$(echo "$input" | jq -r '.description // empty' 2>/dev/null || true)
                command=$(echo "$input" | jq -r '.command // empty' 2>/dev/null || true)
                path=$(echo "$input" | jq -r '.file_path // .path // empty' 2>/dev/null || true)

                if [[ -n "$description" ]]; then
                    echo -e "   ${DIM}Description:${RESET} $description"
                fi

                if [[ -n "$path" ]]; then
                    echo -e "   ${DIM}Path:${RESET} ${CYAN}$path${RESET}"
                fi

                if [[ -n "$command" ]]; then
                    echo -e "   ${DIM}Command:${RESET} ${CYAN}$command${RESET}"
                fi
                ;;
            *)
                # Unknown content type - print as-is
                echo "$item"
                ;;
        esac
    done
}

# Format user/tool_result message
format_user() {
    local json="$1"
    local content_array

    # Get the content array
    content_array=$(echo "$json" | jq -c '.message.content // []')

    # Process each content item
    echo "$content_array" | jq -c '.[]' 2>/dev/null | while IFS= read -r item; do
        local item_type
        item_type=$(echo "$item" | jq -r '.type // "unknown"')

        case "$item_type" in
            "tool_result")
                local tool_use_id is_error content
                tool_use_id=$(echo "$item" | jq -r '.tool_use_id // ""')
                is_error=$(echo "$item" | jq -r '.is_error // false')
                content=$(echo "$item" | jq -r '.content // ""')

                if [[ "$is_error" == "true" ]]; then
                    echo -e "   ${RED}[ERROR]${RESET}"
                else
                    echo -e "   ${GREEN}[OK]${RESET}"
                fi

                # Print output with indentation, truncate if too long
                if [[ -n "$content" && "$content" != "null" ]]; then
                    local line_count
                    line_count=$(echo "$content" | wc -l)

                    if [[ $line_count -gt 20 ]]; then
                        echo "$content" | head -15 | sed 's/^/   /'
                        echo -e "   ${DIM}... ($((line_count - 15)) more lines)${RESET}"
                    else
                        echo "$content" | sed 's/^/   /'
                    fi
                fi
                ;;
            *)
                # Other user content - skip or print as needed
                ;;
        esac
    done
}

# Format result message
format_result() {
    local json="$1"
    local subtype result duration_ms total_cost num_turns
    local input_tokens output_tokens cache_read cache_creation

    subtype=$(echo "$json" | jq -r '.subtype // "unknown"')
    result=$(echo "$json" | jq -r '.result // ""')
    duration_ms=$(echo "$json" | jq -r '.duration_ms // 0')
    total_cost=$(echo "$json" | jq -r '.total_cost_usd // 0')
    num_turns=$(echo "$json" | jq -r '.num_turns // 0')

    # Get token usage
    input_tokens=$(echo "$json" | jq -r '.usage.input_tokens // 0')
    output_tokens=$(echo "$json" | jq -r '.usage.output_tokens // 0')
    cache_read=$(echo "$json" | jq -r '.usage.cache_read_input_tokens // 0')
    cache_creation=$(echo "$json" | jq -r '.usage.cache_creation_input_tokens // 0')

    echo
    print_separator

    if [[ "$subtype" == "success" ]]; then
        echo -e "${GREEN}${BOLD}[COMPLETED]${RESET}"
    else
        echo -e "${RED}${BOLD}[${subtype^^}]${RESET}"
    fi

    # Show final result if not already shown in assistant messages
    if [[ -n "$result" && $(echo "$result" | wc -l) -le 5 ]]; then
        echo -e "${DIM}Result:${RESET} $result"
    fi

    echo -e "${DIM}Duration: ${duration_ms}ms | Turns: $num_turns | Cost: \$${total_cost}${RESET}"
    echo -e "${DIM}Tokens: in=$input_tokens out=$output_tokens cache_read=$cache_read cache_create=$cache_creation${RESET}"
    print_separator
    echo
}

# Main processing loop
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines
    if [[ -z "$line" ]]; then
        continue
    fi

    # Try to parse as JSON and get type
    msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || msg_type=""

    if [[ -z "$msg_type" ]]; then
        # Not valid JSON or no type field - print as-is
        echo "$line"
        continue
    fi

    case "$msg_type" in
        "system")
            subtype=$(echo "$line" | jq -r '.subtype // ""')
            if [[ "$subtype" == "init" ]]; then
                format_init "$line"
            else
                # Other system messages - print raw
                echo "$line"
            fi
            ;;
        "assistant")
            format_assistant "$line"
            ;;
        "user")
            format_user "$line"
            ;;
        "result")
            format_result "$line"
            ;;
        *)
            # Unknown type - print raw line
            echo "$line"
            ;;
    esac
done

# End any ongoing text stream
if [[ "$in_text_stream" == "true" ]]; then
    echo
fi
