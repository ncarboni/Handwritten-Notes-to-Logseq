#!/bin/zsh

# Configuration
LOGSEQ_GRAPH_PATH="/Users/carboni/Documents/Notes"
LOGSEQ_PAGES_DIR="$LOGSEQ_GRAPH_PATH/pages"
INDEX_FILE=".pdf_processing_index.json"

# Check dependencies
if ! command -v magick &> /dev/null; then
    echo "ImageMagick is not installed. Please install it with: brew install imagemagick"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install it with: brew install jq"
    exit 1
fi

# Load API key from .env file in home directory
ENV_FILE="$HOME/.env"
if [[ -f "$ENV_FILE" ]]; then
    # Source the .env file to load variables
    export $(grep OPENAI_API_KEY "$ENV_FILE" | xargs)
fi

# Check if OPENAI_API_KEY is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "OPENAI_API_KEY not found in environment or $ENV_FILE"
    echo "Please create a $ENV_FILE file with the following line:"
    echo "OPENAI_API_KEY=your-api-key-here"
    exit 1
fi

# Function to initialize or load the index
load_or_create_index() {
    if [[ -f "$INDEX_FILE" ]]; then
        cat "$INDEX_FILE"
    else
        echo "{}"
    fi
}

# Function to update the index
update_index() {
    local filename="$1"
    local timestamp="$2"
    local index=$(load_or_create_index)
    
    echo "$index" | jq --arg file "$filename" --arg time "$timestamp" '. + {($file): $time}' > "$INDEX_FILE"
}

# Function to check if a file needs processing
needs_processing() {
    local filename="$1"
    local index=$(load_or_create_index)
    
    # Get last processed timestamp
    local last_processed=$(echo "$index" | jq -r --arg file "$filename" '.[$file] // empty')
    
    if [[ -z "$last_processed" ]]; then
        # File has never been processed
        return 0
    fi
    
    # Get file's last modification time
    local file_mtime=$(stat -f "%m" "$filename")
    local last_processed_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_processed" "+%s" 2>/dev/null)
    
    if [[ $? -ne 0 || $file_mtime -gt $last_processed_epoch ]]; then
        # File has been modified since last processing
        return 0
    fi
    
    return 1
}

# Function to create links to existing pages
create_page_links() {
    local content="$1"
    local pages_dir="$LOGSEQ_PAGES_DIR"
    local journals_dir="$LOGSEQ_GRAPH_PATH/journals"
    local pages_file=$(mktemp)
    
    # Excluded keywords (case-insensitive)
    local excluded_keywords=("TODO" "DOING" "Journal" "Notes" "Logseq")
    
    # Get list of existing pages (excluding highlights and @ files)
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
            fi
        fi
    done
    
    # Find virtual pages (those referenced in [[brackets]] in all markdown files)
    for dir in "$pages_dir" "$journals_dir"; do
        if [[ -d "$dir" ]]; then
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
                        fi
                    done
                fi
            done
        fi
    done
    
    # Remove duplicates and sort by length (longest first)
    sort -u "$pages_file" | awk '{ print length, $0 }' | sort -nr | cut -d" " -f2- > "${pages_file}.sorted"
    mv "${pages_file}.sorted" "$pages_file"
    
    # Replace matching text with links using Perl (more reliable for complex replacements)
    local result="$content"
    
    # Create a temporary script file for Perl
    local perl_script=$(mktemp)
    cat > "$perl_script" <<'EOF'
#!/usr/bin/perl
use strict;
use warnings;

my $pages_file = $ARGV[0];
my $content = do { local $/; <STDIN> };

# Read pages from file
open(my $fh, '<', $pages_file) or die "Can't open $pages_file: $!";
my @pages = <$fh>;
chomp @pages;
close($fh);

# Process each page
foreach my $page (@pages) {
    # Skip empty lines
    next if $page =~ /^\s*$/;
    
    # Escape special regex characters
    my $escaped_page = quotemeta($page);
    
    # Replace whole words that aren't already in brackets
    $content =~ s/(?<!\[\[)\b($escaped_page)\b(?!\]\])/[[$1]]/gi;
}

print $content;
EOF
    
    # Run the Perl script
    result=$(echo "$content" | perl "$perl_script" "$pages_file")
    
    # Clean up temporary files
    rm -f "$pages_file" "$perl_script"
    
    echo "$result"
}

# Function to process a single PDF
process_pdf() {
    local pdf_file="$1"
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    echo "Converting PDF pages to images..."
    magick -density 150 "$pdf_file" -colorspace Gray -quality 70 "$temp_dir/page-%03d.jpg"
    
    local page_files=("$temp_dir"/page-*.jpg)
    local page_count=${#page_files[@]}
    echo "Found $page_count pages"
    
    local pdf_file_absolute=$(cd "$(dirname "$pdf_file")" && pwd)/$(basename "$pdf_file")
    local filename=$(basename "$pdf_file" .pdf)
    local main_title=""
    local combined_content=""
    
    # Process each page
    for ((i=0; i<page_count; i++)); do
        local page_file="$temp_dir/page-$(printf "%03d" $i).jpg"
        local page_number=$((i+1))
        echo "Processing page $page_number of $page_count..."
        
        # Convert image to base64 and ensure no line breaks
        local base64_image=$(base64 -i "$page_file" | tr -d '\n')
        
        # Create a temporary file for the JSON payload
        local payload_file=$(mktemp)
        
        # Create JSON payload
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
        local response_file=$(mktemp)
        curl -s https://api.openai.com/v1/chat/completions \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -d "@$payload_file" > "$response_file"
        
        # Clean up payload file
        rm -f "$payload_file"
        
        # Extract markdown content from response
        local markdown_content=$(jq -r '.choices[0].message.content' "$response_file")
        
        # Check if the API call was successful
        if [ "$markdown_content" = "null" ] || [ -z "$markdown_content" ]; then
            echo "Error processing page $page_number"
            cat "$response_file"
            rm -f "$response_file"
            return 1
        else
            echo "Successfully processed page $page_number"
            
            # Look for the first level 1 heading if we haven't found one yet
            if [ -z "$main_title" ]; then
                local title_line=$(echo "$markdown_content" | grep -m 1 '^#[[:space:]]')
                if [ -n "$title_line" ]; then
                    main_title=$(echo "$title_line" | sed 's/^#[[:space:]]*//')
                    main_title=$(echo "$main_title" | tr -d '\n\r')
                    main_title=$(echo "$main_title" | sed 's/[^a-zA-Z0-9 -]//g')
                    main_title=$(echo "$main_title" | sed 's/[[:space:]]\+/-/g')
                fi
            fi
            
            combined_content+="$markdown_content"
        fi
        
        # Clean up response file
        rm -f "$response_file"
    done
    
    # Use the found title or fall back to the filename
    if [ -n "$main_title" ]; then
        local base_title="${main_title}"
    else
        local base_title="${filename}"
    fi
    
    # Create links to existing pages
    echo "Matching content to existing pages..."
    combined_content=$(create_page_links "$combined_content")
    
    # Create the single note file
    local note_file="$LOGSEQ_PAGES_DIR/${base_title}.md"
    
    # Write the note with proper metadata
    cat > "$note_file" << EOF
title:: ${base_title}
source:: ![${base_title}](${pdf_file_absolute})
date:: $(date +"%Y-%m-%d")

#QuadernoNote

## extracted text:
${combined_content}
EOF
    
    echo "Logseq note created: $note_file"
    return 0
}

# Main function
main() {
    local target_dir="${1:-.}"
    local force_all=0
    
    # Check for force option
    if [[ "$2" == "--force" ]]; then
        force_all=1
    fi
    
    # Change to target directory
    cd "$target_dir" || exit 1
    
    echo "Scanning directory: $(pwd)"
    echo "----------------------------------------"
    
    local processed_count=0
    local skipped_count=0
    local error_count=0
    
    # Find all PDF files
    for pdf_file in *.pdf; do
        if [[ -f "$pdf_file" ]]; then
            if [[ $force_all -eq 1 ]] || needs_processing "$pdf_file"; then
                echo "Processing: $pdf_file"
                if process_pdf "$pdf_file"; then
                    # Update index with current timestamp
                    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
                    update_index "$pdf_file" "$current_time"
                    echo "Successfully processed and indexed: $pdf_file"
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
    
    # Summary
    echo "Processing Summary:"
    echo "Processed: $processed_count files"
    echo "Skipped: $skipped_count files"
    echo "Errors: $error_count files"
}

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
}

# Process arguments
case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac