# Handwritten Notes to Logseq Note - Converter

#logseq

This script automatically **converts PDFs into Logseq notes** by:
- Extracting text from scanned PDFs using OpenAI's GPT OCR capabilities
- Formatting the extracted content in **Logseq block syntax** (Roam-like Markdown)
- **Linking** references to existing and virtual (referenced but non-existent) pages in your Logseq graph
- Automatically skipping already processed PDFs, unless modified
- Saving each processed note as a clean `.md` file directly inside your graph
- The script uses the OpenAI API to perform OCR and transcription.  



## Features

- Converts each page of a PDF to an image and performs OCR using OpenAI GPT models
- Outputs extracted text using Logseq/roam block markdown
- **Automatically links** page mentions to:
  - Existing Logseq pages
  - Virtual (referenced but missing) pages
- Skips unwanted links (e.g., `TODO`, `Journal`, `Notes`)
- Tracks already processed PDFs in a lightweight `.pdf_processing_index.json`
- Detects modified PDFs and reprocesses them only when needed
- Supports `--force` option to reprocess all PDFs
- Clean title extraction and filename generation
- Metadata embedded in the note (`title::`, `source::`, `date::`, tags)

## Requirements

- [ImageMagick](https://imagemagick.org/index.php) (`brew install imagemagick` on macOS)
- [jq](https://stedolan.github.io/jq/) (`brew install jq`)
- OpenAI API Key (you must export it: `export OPENAI_API_KEY='your-api-key'`)
- A working Logseq graph (local directory structure)

## Installation

1. Clone this repository or copy the script.
2. Ensure you have installed the required tools (`ImageMagick`, `jq`).
3. Set your OpenAI API key as an environment variable in your home directory (`~/.env`):
   ```bash
   export OPENAI_API_KEY="your-api-key"
   ```
4. Edit the `LOGSEQ_GRAPH_PATH` variable in the script to point to your Logseq graph location.

## Usage
```bash
./pdf_to_logseq.sh [directory] [--force]
```


## Examples

Process new or modified PDFs in the current directory:

```bash
./pdf_to_logseq.sh
```
Process PDFs in a specific folder:

```bash
./pdf_to_logseq.sh ./my_notes
```

Force reprocess all PDFs in a folder:

```bash
./pdf_to_logseq.sh ./my_notes --force
```