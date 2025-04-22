#!/bin/zsh

# Check if a file is provided
if [ $# -eq 0 ]; then
    echo "Please provide a PDF file"
    exit 1
fi

input_file="$1"

# Check if the file exists and is a PDF
if [ ! -f "$input_file" ]; then
    echo "File not found: $input_file"
    exit 1
fi

if [[ ! "$input_file" =~ \.pdf$ ]]; then
    echo "Input file must be a PDF"
    exit 1
fi

# Check if necessary tools are installed
if ! command -v magick &> /dev/null; then
    echo "ImageMagick is not installed. Please install it with: brew install imagemagick"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install it with: brew install jq"
    exit 1
fi

# Check if OpenAI API key is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "OPENAI_API_KEY environment variable is not set"
    echo "Please set it with: export OPENAI_API_KEY='your-api-key'"
    exit 1
fi

# Set Logseq graph path - modify this to your Logseq graph location
LOGSEQ_GRAPH_PATH="/Users/carboni/Documents/Notes"
LOGSEQ_PAGES_DIR="$LOGSEQ_GRAPH_PATH/pages"

# Check if Logseq pages directory exists
if [ ! -d "$LOGSEQ_PAGES_DIR" ]; then
    echo "Logseq pages directory not found: $LOGSEQ_PAGES_DIR"
    echo "Please modify the LOGSEQ_GRAPH_PATH variable to match your Logseq graph location"
    exit 1
fi

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

# Create a temporary directory for images
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

# Convert PDF pages to JPG images (lower quality for black and white text)
echo "Converting PDF pages to images..."
magick -density 150 "$input_file" -colorspace Gray -quality 70 "$temp_dir/page-%03d.jpg"

# Get the number of pages
page_files=("$temp_dir"/page-*.jpg)
page_count=${#page_files[@]}
echo "Found $page_count pages"

# Get absolute path of input file
input_file_absolute=$(cd "$(dirname "$input_file")" && pwd)/$(basename "$input_file")

# Create output filename
filename=$(basename "$input_file" .pdf)
main_title=""
combined_content=""

# Process each page
for ((i=0; i<page_count; i++)); do
    page_file="$temp_dir/page-$(printf "%03d" $i).jpg"
    page_number=$((i+1))
    echo "Processing page $page_number of $page_count..."
    
    # Convert image to base64 and ensure no line breaks
    base64_image=$(base64 -i "$page_file" | tr -d '\n')
    
    # Create a temporary file for the JSON payload
    payload_file=$(mktemp)
    
    # Create JSON payload using printf and direct file writing
    cat > "$payload_file" << EOF
{
  "model": "gpt-4o",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "extract the content from the image and provide me only with the transcription encoded in Markdown using the block syntax used by Roam and Logseq. Do not extract text from the figures in the text. If the text is written in Upper case, transform it appropriately. If a sentence is split into multiple lines due to the note layout and form, format it in the correct order to keep the flow of the sentence. The answer i am expecting is just the transcribed text and nothing else. Do not explain the output and do not include the output into a codeblock"
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
    response_file=$(mktemp)
    curl -s https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "@$payload_file" > "$response_file"
    
    # Clean up payload file
    rm -f "$payload_file"
    
    # Extract markdown content from response
    markdown_content=$(jq -r '.choices[0].message.content' "$response_file")
    
    # Check if the API call was successful
    if [ "$markdown_content" = "null" ] || [ -z "$markdown_content" ]; then
        echo "Error processing page $page_number"
        cat "$response_file"
    else
        echo "Successfully processed page $page_number"
        
        # Look for the first level 1 heading if we haven't found one yet
        if [ -z "$main_title" ]; then
            title_line=$(echo "$markdown_content" | grep -m 1 '^#[[:space:]]')
            if [ -n "$title_line" ]; then
                main_title=$(echo "$title_line" | sed 's/^#[[:space:]]*//')
                main_title=$(echo "$main_title" | tr -d '\n\r')
                main_title=$(echo "$main_title" | sed 's/[^a-zA-Z0-9 -]//g')
                main_title=$(echo "$main_title" | sed 's/[[:space:]]\+/-/g')
            fi
        fi
        
        # Add content with page separator (if not first page)
        #if [ $i -gt 0 ]; then
        #    combined_content+=$'\n\n---\n\n'
        #fi
        combined_content+="$markdown_content"
    fi
    
    # Clean up response file
    rm -f "$response_file"
done

# Use the found title or fall back to the filename
if [ -n "$main_title" ]; then
    base_title="${main_title}"
else
    base_title="${filename}"
fi

# Create links to existing pages
echo "Matching content to existing pages..."
combined_content=$(create_page_links "$combined_content")

# Create the single note file
note_file="$LOGSEQ_PAGES_DIR/${base_title}.md"

# Write the note with proper metadata
cat > "$note_file" << EOF
title:: ${base_title}
source:: ![${base_title}](${input_file_absolute})
date:: $(date +"%Y-%m-%d")

#QuadernoNote

## extracted text:
${combined_content}
EOF

echo "Logseq note created: $note_file"