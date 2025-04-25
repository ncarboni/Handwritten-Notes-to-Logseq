#!/bin/zsh

# Configuration
LOGSEQ_GRAPH_PATH="/Users/carboni/Documents/Notes"
LOGSEQ_PAGES_DIR="$LOGSEQ_GRAPH_PATH/pages"
INDEX_FILE="/Users/carboni/Documents/Github/Handwritten-Notes-to-Logseq/.pdf_processing_index.json"
LOG_FILE="/tmp/pdf_to_logseq.log"
LOCK_FILE="/tmp/pdf_to_logseq.lock"

# Check for lock file to prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
    # Check if the lock is stale (older than 15 minutes)
    if [ $(($(date +%s) - $(stat -f %m "$LOCK_FILE"))) -lt 900 ]; then
        echo "Another instance is running. Exiting."
        exit 0
    else
        echo "Removing stale lock file."
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
touch "$LOCK_FILE"

# Create a unique identifier for this file
if [[ -n "$1" && "$1" == *.pdf ]]; then
    file_hash=$(echo "$1" | md5)
    SPECIFIC_LOCK="/tmp/pdf_to_logseq_${file_hash}.lock"
    
    # Check if this specific file is being processed
    if [ -f "$SPECIFIC_LOCK" ]; then
        recent_time=$(($(date +%s) - $(stat -f %m "$SPECIFIC_LOCK")))
        if [ $recent_time -lt 60 ]; then
            echo "This file was processed in the last 60 seconds. Skipping."
            exit 0
        fi
    fi
    touch "$SPECIFIC_LOCK"
fi

# Remove lock file on exit, regardless of how the script exits
trap 'rm -f "$LOCK_FILE"' EXIT

# Start logging to the log file instead of standard output
exec > >(tee -a "$LOG_FILE") 2>&1

echo "====== PDF to Logseq Script Started ======" "$(date)"
echo "Graph path: $LOGSEQ_GRAPH_PATH"
echo "Pages directory: $LOGSEQ_PAGES_DIR"
echo "Index file: $INDEX_FILE"
echo "Log file: $LOG_FILE"

# Check dependencies
echo "Checking dependencies..."
if ! command -v magick &> /dev/null; then
    echo "ERROR: ImageMagick is not installed. Please install it with: brew install imagemagick"
    exit 1
else
    echo "✓ ImageMagick found"
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed. Please install it with: brew install jq"
    exit 1
else
    echo "✓ jq found"
fi

# Load API key from .env file in home directory
echo "Loading environment variables..."
ENV_FILE="$HOME/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Source the .env file to load variables
    echo "Found .env file at $ENV_FILE"
    export $(grep OPENAI_API_KEY "$ENV_FILE" | xargs)
    echo "Loaded environment variables from $ENV_FILE"
else
    echo "No .env file found at $ENV_FILE"
fi

# Check if OPENAI_API_KEY is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "ERROR: OPENAI_API_KEY not found in environment or $ENV_FILE"
    echo "Please create a $ENV_FILE file with the following line:"
    echo "OPENAI_API_KEY=your-api-key-here"
    exit 1
else
    echo "✓ OPENAI_API_KEY found"
fi

if [[ ! -f "$INDEX_FILE" ]] || ! jq empty "$INDEX_FILE" 2>/dev/null; then
  echo "{}" > "$INDEX_FILE"
fi


# Function to initialize or load the index
# Replace your load_or_create_index function
load_or_create_index() {
  echo "Loading index file..."
  if [[ -f "$INDEX_FILE" ]] && jq empty "$INDEX_FILE" 2>/dev/null; then
    echo "Index file found and is valid"
    cat "$INDEX_FILE"
  else
    echo "Index file not found or corrupted, creating new index"
    echo "{}" > "$INDEX_FILE"
    echo "{}"
  fi
}

# Function to update the index
update_index() {
    local filename="$1"
    local timestamp="$2"
    
    # Use absolute path as the key in the index
    local absolute_path
    if [[ "$filename" == /* ]]; then
        absolute_path="$filename"
    else
        absolute_path="$(cd "$(dirname "$filename")" && pwd)/$(basename "$filename")"
    fi
    
    echo "Updating index for: $absolute_path with timestamp: $timestamp"
    local index=$(load_or_create_index)
    
    echo "$index" | jq --arg file "$absolute_path" --arg time "$timestamp" '. + {($file): $time}' > "$INDEX_FILE"
    echo "Index updated successfully"
}

# Function to check if a file needs processing
needs_processing() {
    local filename="$1"
    
    # Use absolute path for consistency
    local absolute_path
    if [[ "$filename" == /* ]]; then
        absolute_path="$filename"
    else
        absolute_path="$(cd "$(dirname "$filename")" && pwd)/$(basename "$filename")"
    fi
    
    echo "Checking if file needs processing: $absolute_path"
    local index=$(load_or_create_index)
    
    # Get last processed timestamp
    local last_processed=$(echo "$index" | jq -r --arg file "$absolute_path" '.[$file] // empty')
    
    if [[ -z "$last_processed" ]]; then
        # File has never been processed
        echo "File has never been processed before"
        return 0
    fi
    
    # Get file's last modification time
    local file_mtime=$(stat -f "%m" "$absolute_path")
    echo "File modification time: $file_mtime"
    local last_processed_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_processed" "+%s" 2>/dev/null)
    echo "Last processed time: $last_processed ($last_processed_epoch)"
    
    # Allow a 10-second grace period to prevent duplicate processing
    if [[ $? -ne 0 || $(($file_mtime - $last_processed_epoch)) -gt 10 ]]; then
        # File has been modified since last processing (more than 10 seconds ago)
        echo "File has been modified since last processing"
        return 0
    fi
    
    echo "File has not been modified since last processing or was recently processed"
    return 1
}

# Function to create links to existing pages - Modified to capture and redirect log output
create_page_links() {
    local content="$1"
    local pages_dir="$LOGSEQ_PAGES_DIR"
    local journals_dir="$LOGSEQ_GRAPH_PATH/journals"
    local pages_file=$(mktemp)
    
    echo "Creating links to existing pages..."
    echo "Temporary file for page names: $pages_file"
    
    # Excluded keywords (case-insensitive)
    local excluded_keywords=("TODO" "DOING" "Journal" "Notes" "Logseq")
    echo "Excluded keywords: ${excluded_keywords[*]}"
    
    # Get list of existing pages (excluding highlights and @ files)
    echo "Scanning existing pages in $pages_dir..."
    local page_count=0
    for page_file in "$pages_dir"/*.md; do
        if [[ -f "$page_file" ]]; then
            page_name="${page_file:t:r}"  # basename without extension in zsh
            
            # Skip if it contains "(highlights)"
            if [[ "$page_name" == *"(highlights)"* ]]; then
                continue
            fi
            
            # Skip if it starts with "@"
            if [[ "$page_name" == @* ]]; then
                continue
            fi
            
            # Skip if it matches any excluded keyword (case-insensitive)
            local skip=0
            for keyword in "${excluded_keywords[@]}"; do
                if [[ "${(L)page_name}" == "${(L)keyword}" ]]; then
                    skip=1
                    break
                fi
            done
            
            if [[ $skip -eq 0 ]]; then
                echo "$page_name" >> "$pages_file"
                ((page_count++))
            fi
        fi
    done
    echo "Found $page_count pages in pages directory"
    
    # Find virtual pages (those referenced in [[brackets]] in all markdown files)
    echo "Scanning for virtual pages (referenced in brackets)..."
    local virtual_count=0
    for dir in "$pages_dir" "$journals_dir"; do
        if [[ -d "$dir" ]]; then
            echo "Scanning directory: $dir"
            for file in "$dir"/*.md; do
                if [[ -f "$file" ]]; then
                    # Extract all [[references]] from the file
                    grep -o '\[\[[^]]*\]\]' "$file" 2>/dev/null | while read -r reference; do
                        # Extract the content between brackets
                        virtual_page="${reference#\[\[}"
                        virtual_page="${virtual_page%\]\]}"
                        
                        # Skip if it contains "(highlights)"
                        if [[ "$virtual_page" == *"(highlights)"* ]]; then
                            continue
                        fi
                        
                        # Skip if it starts with "@"
                        if [[ "$virtual_page" == @* ]]; then
                            continue
                        fi
                        
                        # Skip if it matches any excluded keyword (case-insensitive)
                        local skip=0
                        for keyword in "${excluded_keywords[@]}"; do
                            if [[ "${(L)virtual_page}" == "${(L)keyword}" ]]; then
                                skip=1
                                break
                            fi
                        done
                        
                        if [[ $skip -eq 0 ]]; then
                            echo "$virtual_page" >> "$pages_file"
                            ((virtual_count++))
                        fi
                    done
                fi
            done
        fi
    done
    echo "Found $virtual_count virtual pages in references"
    
    # Remove duplicates and sort by length (longest first)
    echo "Sorting and removing duplicates..."
    sort -u "$pages_file" | awk '{ print length, $0 }' | sort -nr | cut -d" " -f2- > "${pages_file}.sorted"
    mv "${pages_file}.sorted" "$pages_file"
    local unique_count=$(wc -l < "$pages_file")
    echo "Total unique pages: $unique_count"
    
    # Replace matching text with links using Perl (more reliable for complex replacements)
    echo "Creating Perl script for text replacement..."
    local result="$content"
    
    # Create a temporary script file for Perl
    local perl_script=$(mktemp)
    echo "Perl script location: $perl_script"
    
    # IMPORTANT: Redirect Perl's STDERR to our log file
    cat > "$perl_script" << EOF
#!/usr/bin/perl
use strict;
use warnings;

# Open our log file for Perl output
open(STDERR, '>>', '$LOG_FILE') or die "Can't redirect STDERR to $LOG_FILE: \$!";

my \$pages_file = \$ARGV[0];
my \$content = do { local \$/; <STDIN> };

# Read pages from file
open(my \$fh, '<', \$pages_file) or die "Can't open \$pages_file: \$!";
my @pages = <\$fh>;
chomp @pages;
close(\$fh);

my \$replacements = 0;

# Process each page
foreach my \$page (@pages) {
    # Skip empty lines
    next if \$page =~ /^\\s*\$/;
    
    # Escape special regex characters
    my \$escaped_page = quotemeta(\$page);
    
    # Replace whole words that aren't already in brackets
    while (\$content =~ s/(?<!\[\[)\\b(\$escaped_page)\\b(?!\]\])/[[\$1]]/gi) {
        \$replacements++;
    }
}

print STDERR "Total replacements made: \$replacements\\n";
print \$content;
EOF
    
    # Run the Perl script and capture only its STDOUT for the result
    result=$(echo "$content" | perl "$perl_script" "$pages_file")
    
    # Clean up temporary files
    echo "Cleaning up temporary files..."
    rm -f "$pages_file" "$perl_script"
    
    echo "Link creation completed"
    echo "$result"
}

# Function to process a single PDF
process_pdf() {
    local pdf_file="$1"
    
    # Use absolute path for the PDF file
    local absolute_path
    if [[ "$pdf_file" == /* ]]; then
        absolute_path="$pdf_file"
    else
        absolute_path="$(cd "$(dirname "$pdf_file")" && pwd)/$(basename "$pdf_file")"
    fi
    
    # Check if the file was recently processed
    if ! needs_processing "$absolute_path"; then
        echo "SKIPPING: $absolute_path was recently processed"
        return 0
    fi
    
    echo "========================================="
    echo "PROCESSING PDF: $absolute_path"
    echo "========================================="
    
    local temp_dir=$(mktemp -d)
    echo "Created temporary directory: $temp_dir"
    trap 'echo "Cleaning up temporary directory $temp_dir"; rm -rf "$temp_dir"' EXIT
    
    echo "Converting PDF pages to images using ImageMagick..."
    magick -density 150 "$absolute_path" -colorspace Gray -quality 70 "$temp_dir/page-%03d.jpg"
    echo "Conversion status: $?"
    
    local page_files=("$temp_dir"/page-*.jpg)
    local page_count=${#page_files[@]}
    echo "Found $page_count pages in PDF"
    
    echo "Absolute PDF path: $absolute_path"
    local filename=$(basename "$absolute_path" .pdf)
    echo "Base filename: $filename"
    local main_title=""
    local combined_content=""
    
    # Process each page
    for ((i=0; i<page_count; i++)); do
        local page_file="$temp_dir/page-$(printf "%03d" $i).jpg"
        local page_number=$((i+1))
        echo "========================================="
        echo "Processing page $page_number of $page_count: $page_file"
        echo "========================================="
        
        # Convert image to base64 and ensure no line breaks
        echo "Converting image to base64..."
        local base64_image=$(base64 -i "$page_file" | tr -d '\n')
        echo "Base64 conversion complete. Length: ${#base64_image} characters"
        
        # Create a temporary file for the JSON payload
        local payload_file=$(mktemp)
        echo "Created JSON payload file: $payload_file"
        
        # Create JSON payload
        echo "Creating OpenAI API request payload..."
        cat > "$payload_file" << EOF
{
  "model": "gpt-4o",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "extract the content from the image and provide me only with the transcription encoded in Markdown using the block syntax used by Roam and Logseq. Do not extract text from the figures in the text. If the text is written in Upper case, transform it appropriately. If a sentence is split into multiple lines due to layout, format it in order to keep its flow. The answer i am expecting is just the transcribed text and nothing else. Do not explain the output and do not include the output into a codeblock"
        },
        {
          "type": "image_url",
          "image_url": {
            "url": "data:image/jpeg;base64,${base64_image}"
          }
        }
      ]
    }
  ],
  "max_tokens": 4096
}
EOF
        
        # Call OpenAI API and save response
        echo "Calling OpenAI API..."
        local response_file=$(mktemp)
        echo "Response will be saved to: $response_file"
        curl -s https://api.openai.com/v1/chat/completions \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -d "@$payload_file" > "$response_file"
        
        # Clean up payload file
        echo "Removing payload file"
        rm -f "$payload_file"
        
        # Extract markdown content from response
        echo "Extracting markdown content from API response..."
        local markdown_content=$(jq -r '.choices[0].message.content' "$response_file")
        
        # Check if the API call was successful
        if [ "$markdown_content" = "null" ] || [ -z "$markdown_content" ]; then
            echo "ERROR: API call failed for page $page_number"
            echo "API Response:"
            cat "$response_file"
            rm -f "$response_file"
            return 1
        else
            echo "Successfully processed page $page_number"
            echo "Content length: ${#markdown_content} characters"
            
            # Look for the first level 1 heading if we haven't found one yet
            if [ -z "$main_title" ]; then
                echo "Looking for title in markdown content..."
                local title_line=$(echo "$markdown_content" | grep -m 1 '^#[[:space:]]')
                if [ -n "$title_line" ]; then
                    main_title=$(echo "$title_line" | sed 's/^#[[:space:]]*//')
                    main_title=$(echo "$main_title" | tr -d '\n\r')
                    main_title=$(echo "$main_title" | sed 's/[^a-zA-Z0-9 -]//g')
                    main_title=$(echo "$main_title" | sed 's/[[:space:]]\+/-/g')
                    echo "Found title: $main_title"
                else
                    echo "No title found in this page"
                fi
            fi
            
            echo "Appending content to combined markdown"
            combined_content+="$markdown_content"
        fi
        
        # Clean up response file
        echo "Removing response file"
        rm -f "$response_file"
    done
    
    # Use the found title or fall back to the filename
    if [ -n "$main_title" ]; then
        local base_title="${main_title}"
        echo "Using extracted title: $base_title"
    else
        local base_title="${filename}"
        echo "Using filename as title: $base_title"
    fi
    
    # Important: Temporarily restore stdout to the console for the file creation
    # Save current stdout
    exec {ORIGINAL_STDOUT}>&1
    
    # Create links to existing pages - capture output separately
    echo "Matching content to existing pages..."
    # Call create_page_links with our redirection in place
    combined_content=$(create_page_links "$combined_content")
    
    # Create the single note file - write directly to file without logging
    local note_file="$LOGSEQ_PAGES_DIR/${base_title}.md"
    echo "Creating Logseq note at: $note_file"
    
    # Write to the note file without any log output mixed in
    exec > "$note_file"
    echo "title:: ${base_title}"
    echo "source:: ![${base_title}](${absolute_path})"
    echo "date:: $(date +"%Y-%m-%d")"
    echo ""
    echo "#QuadernoNote"
    echo ""
    echo "## extracted text:"
    echo "$combined_content"
    
    # Restore stdout to log file
    exec >&${ORIGINAL_STDOUT}
    
    echo "Logseq note created: $note_file"
    echo "Content length: ${#combined_content} characters"
    
    # Update index with current timestamp
    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
    update_index "$absolute_path" "$current_time"
    echo "Successfully processed and indexed: $absolute_path"
    
    return 0
}

# Special handling for fswatch integration - MOVED AFTER ALL FUNCTIONS ARE DEFINED
if [[ "$1" == *.pdf && -f "$1" ]]; then
    echo "===== $(date) =====" >> "$LOG_FILE"
    echo "Direct file mode detected"
    echo "Processing file: $1"
    
    # Now we can call process_pdf because it's defined above
    process_pdf "$1"
    EXIT_CODE=$?
    echo "Process completed with exit code: $EXIT_CODE"
    exit $EXIT_CODE
fi

# Show help
show_help() {
    echo "Usage: $0 [directory] [--force]"
    echo ""
    echo "Options:"
    echo "  directory    Directory containing PDFs (default: current directory)"
    echo "  --force      Force processing of all PDFs, even if already processed"
    echo ""
    echo "Example:"
    echo "  $0                    # Process PDFs in current directory"
    echo "  $0 ./my_pdfs          # Process only new/modified PDFs"
    echo "  $0 ./my_pdfs --force  # Process all PDFs regardless of index"
    echo ""
    echo "When used with fswatch:"
    echo "  fswatch -0 -e \".*\" -i \"\\.pdf$\" /path/to/watch | xargs -0 -n1 $0"
}

# Process arguments based on whether this is a file or directory
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        # If it's a file that exists, we've already handled it above
        # Only proceed with directory scan mode if it's not a PDF file
        if [[ "$1" != *.pdf || ! -f "$1" ]]; then
            # Original main function for directory scanning
            echo "Directory scan mode. Starting main function..."
            
            local target_dir="${1:-.}"
            local force_all=0
            
            # Check for force option
            if [[ "$2" == "--force" ]]; then
                force_all=1
                echo "Force mode enabled: Will process all PDFs regardless of previous processing"
            else
                echo "Normal mode: Will only process new or modified PDFs"
            fi
            
            # Change to target directory
            echo "Changing to target directory: $target_dir"
            cd "$target_dir" || { echo "ERROR: Failed to change to directory $target_dir"; exit 1; }
            
            echo "Current working directory: $(pwd)"
            echo "----------------------------------------"
            
            local processed_count=0
            local skipped_count=0
            local error_count=0
            
            # Find all PDF files
            echo "Scanning for PDF files..."
            local pdf_count=0
            for pdf_file in *.pdf; do
                if [[ -f "$pdf_file" ]]; then
                    ((pdf_count++))
                    echo "Found PDF #$pdf_count: $pdf_file"
                    
                    if [[ $force_all -eq 1 ]] || needs_processing "$pdf_file"; then
                        echo "Processing: $pdf_file"
                        if process_pdf "$pdf_file"; then
                            ((processed_count++))
                        else
                            echo "Error processing: $pdf_file"
                            ((error_count++))
                        fi
                    else
                        echo "Skipping already processed: $pdf_file"
                        ((skipped_count++))
                    fi
                    echo "----------------------------------------"
                fi
            done
            
            if [[ $pdf_count -eq 0 ]]; then
                echo "No PDF files found in directory"
            fi
            
            # Summary
            echo "========================================="
            echo "PROCESSING SUMMARY:"
            echo "----------------------------------------"
            echo "Total PDFs found: $pdf_count"
            echo "Processed: $processed_count files"
            echo "Skipped: $skipped_count files"
            echo "Errors: $error_count files"
            echo "========================================="
        fi
        ;;
esac