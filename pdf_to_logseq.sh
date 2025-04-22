#!/bin/bash

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
LOGSEQ_GRAPH_PATH="/Users/carboni/Downloads/test"
LOGSEQ_PAGES_DIR="$LOGSEQ_GRAPH_PATH/pages"

# Check if Logseq pages directory exists
if [ ! -d "$LOGSEQ_PAGES_DIR" ]; then
    echo "Logseq pages directory not found: $LOGSEQ_PAGES_DIR"
    echo "Please modify the LOGSEQ_GRAPH_PATH variable to match your Logseq graph location"
    exit 1
fi

# Create a temporary directory for images
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

# Convert PDF pages to JPG images (lower quality for black and white text)
echo "Converting PDF pages to images..."
magick -density 150 "$input_file" -colorspace Gray -quality 70 "$temp_dir/page-%03d.jpg"

# Get the number of pages
page_count=$(ls "$temp_dir"/page-*.jpg | wc -l)
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
    
    # Convert image to base64
    base64_image=$(base64 -i "$page_file")
    
    # Create JSON payload with the correct prompt
    payload=$(jq -n \
        --arg prompt "extract the content from the image and provide me only with the transcription encoded in Markdown. Do not extract text from the figures in the text. If the text is written in Upper case, transform it appropriately. If a sentence is split into multiple lines due to layout, format it in order to keep its flow. The answer i am expecting is just the transcribed text and nothing else. Do not explain the output and do not include the output into a codeblock" \
        --arg b64_image "$base64_image" \
        '{
            model: "gpt-4o",
            messages: [
                {
                    role: "user",
                    content: [
                        {
                            type: "text",
                            text: $prompt
                        },
                        {
                            type: "image_url",
                            image_url: {
                                url: ("data:image/jpeg;base64," + $b64_image)
                            }
                        }
                    ]
                }
            ],
            max_tokens: 4096
        }')
    
    # Call OpenAI API
    response=$(curl -s https://api.openai.com/v1/chat/completions \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -d "$payload")
    
    # Extract markdown content from response
    markdown_content=$(echo "$response" | jq -r '.choices[0].message.content')
    
    # Check if the API call was successful
    if [ "$markdown_content" = "null" ]; then
        echo "Error processing page $page_number"
        echo "API Response: $response"
    else
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
        if [ $i -gt 0 ]; then
            combined_content+=$'\n\n---\n\n'
        fi
        combined_content+="$markdown_content"
    fi
done

# Use the found title or fall back to the filename
if [ -n "$main_title" ]; then
    base_title="${main_title}"
else
    base_title="${filename}"
fi

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