#!/bin/bash

# Get the full file path from fswatch/xargs
FILE_PATH="$1"

if [[ "$FILE_PATH" == *.pdf ]]; then
  # Get the directory and filename
  DIR_PATH=$(dirname "$FILE_PATH")
  FILE_NAME=$(basename "$FILE_PATH")
  
  # Change to the directory containing the PDF
  cd "$DIR_PATH"
  
  # Call the original script with the filename
  /Users/carboni/Documents/Github/Handwritten-Notes-to-Logseq/pdf_to_logseq.sh "$DIR_PATH" --file "$FILE_NAME"
fi