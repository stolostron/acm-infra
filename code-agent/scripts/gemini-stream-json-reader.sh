#!/bin/bash
# Stream JSON Reader for Gemini CLI output
#
# Converts stream-json format to human-readable output.
# Usage: gemini --output-format stream-json ... | stream-json-reader
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
last_role=""
in_assistant_stream=false

# Print a header box
print_header_box() {
    local session_id="$1"
    local model="$2"
    local timestamp="$3"

    local width=64
    local line=$(printf '%*s' $((width - 2)) '' | tr ' ' "$BOX_H")

    echo -e "${CYAN}${BOX_TL}${line}${BOX_TR}${RESET}"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "Session: ${session_id:0:40}"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "Model: $model"
    printf "${CYAN}${BOX_V}${RESET} %-$((width - 4))s ${CYAN}${BOX_V}${RESET}\n" "Started: $timestamp"
    echo -e "${CYAN}${BOX_BL}${line}${BOX_BR}${RESET}"
    echo
}

# Format init message
format_init() {
    local json="$1"
    local session_id model timestamp

    session_id=$(echo "$json" | jq -r '.session_id // "unknown"')
    model=$(echo "$json" | jq -r '.model // "unknown"')
    timestamp=$(echo "$json" | jq -r '.timestamp // "unknown"')

    print_header_box "$session_id" "$model" "$timestamp"
}

# Format message (user or assistant)
format_message() {
    local json="$1"
    local role content is_delta

    role=$(echo "$json" | jq -r '.role // "unknown"')
    content=$(echo "$json" | jq -r '.content // ""')
    is_delta=$(echo "$json" | jq -r '.delta // false')

    if [[ "$role" == "user" ]]; then
        # End any ongoing assistant stream
        if [[ "$in_assistant_stream" == "true" ]]; then
            echo
            in_assistant_stream=false
        fi

        echo -e "\n${BLUE}${BOLD}[TASK]${RESET}"
        echo -e "${DIM}────────────────────────────────────────${RESET}"
        echo "$content"
        echo -e "${DIM}────────────────────────────────────────${RESET}"
        last_role="user"

    elif [[ "$role" == "assistant" ]]; then
        if [[ "$is_delta" == "true" ]]; then
            # Streaming chunk - print inline
            if [[ "$in_assistant_stream" == "false" ]]; then
                # First chunk - print header
                if [[ "$last_role" != "assistant" ]]; then
                    echo -e "\n${GREEN}${BOLD}[ASSISTANT]${RESET}"
                fi
                in_assistant_stream=true
            fi
            # Print content without newline for streaming effect
            printf '%s' "$content"
        else
            # Complete message (non-delta)
            if [[ "$in_assistant_stream" == "true" ]]; then
                echo
                in_assistant_stream=false
            fi
            if [[ "$last_role" != "assistant" ]]; then
                echo -e "\n${GREEN}${BOLD}[ASSISTANT]${RESET}"
            fi
            echo "$content"
        fi
        last_role="assistant"
    else
        # Unknown role - print as-is
        echo "$json"
    fi
}

# Format tool_use
format_tool_use() {
    local json="$1"
    local tool_name tool_id params description command

    # End any ongoing assistant stream
    if [[ "$in_assistant_stream" == "true" ]]; then
        echo
        in_assistant_stream=false
    fi

    tool_name=$(echo "$json" | jq -r '.tool_name // "unknown"')
    tool_id=$(echo "$json" | jq -r '.tool_id // ""')
    params=$(echo "$json" | jq -r '.parameters // {}')

    echo -e "\n${YELLOW}${BOLD}[TOOL] ${tool_name}${RESET}"

    # Extract common parameters
    description=$(echo "$params" | jq -r '.description // empty')
    command=$(echo "$params" | jq -r '.command // empty')

    if [[ -n "$description" ]]; then
        echo -e "   ${DIM}Description:${RESET} $description"
    fi

    if [[ -n "$command" ]]; then
        echo -e "   ${DIM}Command:${RESET} ${CYAN}$command${RESET}"
    fi

    # Show other parameters (excluding description and command)
    local other_params
    other_params=$(echo "$params" | jq -r 'del(.description, .command) | to_entries | .[] | "   \(.key): \(.value)"' 2>/dev/null || true)
    if [[ -n "$other_params" ]]; then
        echo "$other_params"
    fi

    last_role="tool"
}

# Format tool_result
format_tool_result() {
    local json="$1"
    local tool_id status output

    tool_id=$(echo "$json" | jq -r '.tool_id // ""')
    status=$(echo "$json" | jq -r '.status // "unknown"')
    output=$(echo "$json" | jq -r '.output // ""')

    if [[ "$status" == "success" ]]; then
        echo -e "\n   ${GREEN}[OK]${RESET}"
    else
        echo -e "\n   ${RED}[FAILED] (${status})${RESET}"
    fi

    # Print output with indentation, truncate if too long
    if [[ -n "$output" ]]; then
        local line_count
        line_count=$(echo "$output" | wc -l)

        if [[ $line_count -gt 20 ]]; then
            echo "$output" | head -15 | sed 's/^/   /'
            echo -e "   ${DIM}... ($((line_count - 15)) more lines)${RESET}"
        else
            echo "$output" | sed 's/^/   /'
        fi
    fi

    last_role="tool_result"
}

# Format result (final summary)
format_result() {
    local json="$1"
    local status timestamp total_tokens input_tokens output_tokens cached duration_ms tool_calls

    # End any ongoing assistant stream
    if [[ "$in_assistant_stream" == "true" ]]; then
        echo
        in_assistant_stream=false
    fi

    status=$(echo "$json" | jq -r '.status // "unknown"')
    timestamp=$(echo "$json" | jq -r '.timestamp // "unknown"')

    # Extract stats
    total_tokens=$(echo "$json" | jq -r '.stats.total_tokens // 0')
    input_tokens=$(echo "$json" | jq -r '.stats.input_tokens // .stats.input // 0')
    output_tokens=$(echo "$json" | jq -r '.stats.output_tokens // 0')
    cached=$(echo "$json" | jq -r '.stats.cached // 0')
    duration_ms=$(echo "$json" | jq -r '.stats.duration_ms // 0')
    tool_calls=$(echo "$json" | jq -r '.stats.tool_calls // 0')

    # Calculate duration in seconds
    local duration_sec
    if [[ "$duration_ms" -gt 0 ]]; then
        duration_sec=$(awk "BEGIN {printf \"%.2f\", $duration_ms / 1000}")
    else
        duration_sec="0.00"
    fi

    # Format timestamp to be more readable
    local formatted_time
    formatted_time=$(echo "$timestamp" | sed 's/T/ /; s/\.[0-9]*Z$//')

    echo
    echo

    # Status indicator
    local status_icon status_color status_text
    if [[ "$status" == "success" ]]; then
        status_icon="✓"
        status_color="$GREEN"
        status_text="SUCCESS"
    else
        status_icon="✗"
        status_color="$RED"
        status_text="FAILED"
    fi

    # Print a clean summary box
    local sep_line="════════════════════════════════════════════════════════════"

    echo -e "${status_color}${sep_line}${RESET}"
    echo -e "${status_color}${BOLD}  ${status_icon} ${status_text}${RESET}"
    echo -e "${status_color}${sep_line}${RESET}"
    echo
    echo -e "  ${BOLD}Token Usage${RESET}"
    echo -e "    ${DIM}Total:${RESET}  $(format_number "$total_tokens")    ${DIM}Input:${RESET}  $(format_number "$input_tokens")"
    echo -e "    ${DIM}Output:${RESET} $(format_number "$output_tokens")    ${DIM}Cached:${RESET} $(format_number "$cached")"
    echo
    echo -e "  ${BOLD}Performance${RESET}"
    echo -e "    ${DIM}Duration:${RESET}   ${duration_sec}s"
    echo -e "    ${DIM}Tool Calls:${RESET} ${tool_calls}"
    echo
    echo -e "  ${DIM}Completed: ${formatted_time}${RESET}"
    echo -e "${status_color}${sep_line}${RESET}"
    echo
}

# Helper function to format large numbers with commas
format_number() {
    local num="$1"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        printf "%'d" "$num" 2>/dev/null || echo "$num"
    else
        echo "$num"
    fi
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
        "init")
            format_init "$line"
            ;;
        "message")
            format_message "$line"
            ;;
        "tool_use")
            format_tool_use "$line"
            ;;
        "tool_result")
            format_tool_result "$line"
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

# End any ongoing assistant stream
if [[ "$in_assistant_stream" == "true" ]]; then
    echo
fi
