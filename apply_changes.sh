#!/bin/bash

# A script to process an XML response from an AI, executing commands and
# applying file modifications as specified in the standard AI output format.

# --- Main Script Logic ---

# 1. Validate Input
# -----------------------------------------------------------------------------
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_xml_response_file>"
    echo "Example: $0 ai-response.xml"
    exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found at '$INPUT_FILE'"
    exit 1
fi

echo "Processing response file: $INPUT_FILE"
echo "========================================"

# 2. Initialize State
# -----------------------------------------------------------------------------
# 'search': Default state, looking for a relevant opening tag.
# 'in_reasoning': Capturing the content of the <reasoning> tag.
# 'in_cdata': Capturing content from a CDATA block.
STATE="search"
# 'BLOCK_TYPE' determines the action after CDATA is read (either 'command' or 'file').
BLOCK_TYPE=""
CURRENT_FILE_PATH=""
CURRENT_CONTENT=""

# 3. Process the XML file line by line
# -----------------------------------------------------------------------------
while IFS= read -r line || [ -n "$line" ]; do

    # Regardless of the state, if we find a CDATA start, we switch to handle it.
    if [[ "$STATE" != "in_cdata" && "$line" == *"<![CDATA["* ]]; then
        STATE="in_cdata"
        # Everything after the CDATA tag on this line is the start of our content.
        CURRENT_CONTENT=$(echo "$line" | sed 's/.*<!\[CDATA\[//')

        # If CDATA also ends on this line, handle it right away.
        # The action will be triggered by the "in_cdata" state logic below.
        if [[ "$line" == *"]]>"* ]]; then
            CURRENT_CONTENT=$(echo "$CURRENT_CONTENT" | sed 's/\]\]>.*//')
        else
            # The CDATA block continues on the next line, so we loop to the next line.
            continue
        fi
    fi

    case "$STATE" in
        "search")
            if [[ "$line" == *"<reasoning>"* ]]; then
                echo "--- Reasoning ---"
                STATE="in_reasoning"
                # If </reasoning> is on the same line, handle it and go back to 'search'.
                if [[ "$line" == *"</reasoning>"* ]]; then
                    content=$(echo "$line" | sed -e 's/.*<reasoning>//' -e 's/<\/reasoning>.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    echo "$content"
                    echo "-----------------"
                    STATE="search"
                fi
            elif [[ "$line" == *"<commands>"* ]]; then
                BLOCK_TYPE="command"
                # The state will be switched to 'in_cdata' by the general check above if needed.
            elif [[ "$line" == *"<file path=\""* ]]; then
                BLOCK_TYPE="file"
                CURRENT_FILE_PATH=$(echo "$line" | sed -n 's/.*<file path="\([^"]*\)".*/\1/p')
                # The state will be switched to 'in_cdata' by the general check above if needed.
            fi
            ;;

        "in_reasoning")
            if [[ "$line" == *"</reasoning>"* ]]; then
                content_before_tag=$(echo "$line" | sed 's|</reasoning>.*||')
                echo "$content_before_tag" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
                echo "-----------------"
                STATE="search"
            else
                echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
            fi
            ;;

        "in_cdata")
            # This state is entered either by the general check above, or if we were already in it.
            # If the CDATA block ends on this line, we process it.
            if [[ "$line" == *"]]>"* ]]; then
                # Append the part of the line before the closing marker.
                content_before_marker=$(echo "$line" | sed 's/\]\]>.*//')
                # Check if CURRENT_CONTENT was initialized on a previous line.
                if [ -z "$CURRENT_CONTENT" ]; then
                    CURRENT_CONTENT="$content_before_marker"
                else
                    CURRENT_CONTENT="$CURRENT_CONTENT"$'\n'"$content_before_marker"
                fi

                # --- Perform action based on BLOCK_TYPE ---
                if [[ "$BLOCK_TYPE" == "command" ]]; then
                    # Only execute if there's non-whitespace content
                    if [[ -n "$(echo "$CURRENT_CONTENT" | tr -d '[:space:]')" ]]; then
                        echo; echo "--- Executing Commands ---"
                        # Execute in a subshell. Use -e to exit on error within subshell.
                        bash -e <<< "$CURRENT_CONTENT"
                        EXECUTION_STATUS=$?
                        if [ $EXECUTION_STATUS -eq 0 ]; then
                            echo "-> Commands executed successfully."
                        else
                            echo "-> ERROR: Command execution failed with status $EXECUTION_STATUS."
                        fi
                        echo "--------------------------"
                    fi
                elif [[ "$BLOCK_TYPE" == "file" ]]; then
                    echo; echo "--- Applying File Modification ---"
                    echo "-> Writing to: $CURRENT_FILE_PATH"
                    DIR_NAME=$(dirname "$CURRENT_FILE_PATH")
                    mkdir -p "$DIR_NAME"
                    # Use printf to preserve content exactly as captured
                    printf "%s" "$CURRENT_CONTENT" > "$CURRENT_FILE_PATH"
                    echo "-> Done."
                    echo "--------------------------------"
                fi
                
                # Reset state for the next block
                STATE="search"
                BLOCK_TYPE=""
                CURRENT_FILE_PATH=""
                CURRENT_CONTENT=""
            else
                # We are in a multi-line CDATA block. Append the whole line.
                 if [ -z "$CURRENT_CONTENT" ]; then
                    CURRENT_CONTENT="$line"
                else
                    CURRENT_CONTENT="$CURRENT_CONTENT"$'\n'"$line"
                fi
            fi
            ;;
    esac
done < "$INPUT_FILE"

echo "========================================"
echo "Response processing complete."
