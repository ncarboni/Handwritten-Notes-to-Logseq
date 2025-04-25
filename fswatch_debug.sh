#!/bin/bash
# Debug wrapper script for pdf_to_logseq.sh

# Log file
LOG_FILE="/tmp/pdf_to_logseq_debug.log"

# Log timestamp and command
echo "===== $(date) =====" >> "$LOG_FILE"
echo "Received argument: $1" >> "$LOG_FILE"

# Check if we received a valid file path
if [[ -f "$1" && "$1" == *.pdf ]]; then
    echo "Valid PDF file detected: $1" >> "$LOG_FILE"
    # Run the script with the file
    /Users/carboni/Documents/Github/Handwritten-Notes-to-Logseq/pdf_to_logseq.sh "$1" >> "$LOG_FILE" 2>&1
else
    echo "Invalid argument - not a PDF file or file doesn't exist: $1" >> "$LOG_FILE"
    
    # Try to list files in the monitored directory
    echo "Files in monitored directory:" >> "$LOG_FILE"
    ls -la /Users/carboni/Documents/Quaderno/Notes >> "$LOG_FILE" 2>&1
fi

# Log completion
echo "Command completed with exit code: $?" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"