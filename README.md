# Handwritten Notes to Logseq Note - Converter

This script automatically **converts a PDF into a Logseq note** by:
- Extracting text from the PDF using OpenAI OCR
- Formatting the extracted content in **Logseq block syntax**
- **Linking** references to existing and virtual pages in your Logseq graph
- Saving the result as a clean `.md` page directly inside your graph

## Features
- Converts each page of a PDF to an image and performs OCR using OpenAI's GPT models
- Outputs extracted text formatted for **Logseq** (Roam-like Markdown blocks)
- **Automatically links** page references to:
  - Existing Logseq pages
  - Virtual pages mentioned but not yet created
- Skips unwanted links (e.g., `TODO`, `Journal`, `Notes`)
- Creates a properly formatted Logseq `.md` file with title, source, and metadata

## Requirements

- [ImageMagick](https://imagemagick.org/index.php) (`brew install imagemagick` on macOS)
- [jq](https://stedolan.github.io/jq/) (`brew install jq`)
- OpenAI API Key (you must export it: `export OPENAI_API_KEY='your-api-key'`)
- A working Logseq graph (local directory structure)

## Installation

1. Clone this repository or copy the script.
2. Ensure you have installed the required tools (`ImageMagick`, `jq`).
3. Set your OpenAI API key as an environment variable:
   ```bash
   export OPENAI_API_KEY="your-api-key"
   ```
4. Edit the `LOGSEQ_GRAPH_PATH` variable in the script to point to your Logseq graph location.