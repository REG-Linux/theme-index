#!/bin/bash
#
# Generate themes.json from processed theme zips and theme-list.json.
#
# Usage: generate-index.sh <theme_list> <zips_dir> <screenshots_dir> <release_tag> <output_json>
#

set -e

THEME_LIST="$1"
ZIPS_DIR="$2"
SCREENSHOTS_DIR="$3"
RELEASE_TAG="$4"
OUTPUT_JSON="$5"
REPO="${6:-REG-Linux/theme-index}"

if [ -z "$THEME_LIST" ] || [ -z "$OUTPUT_JSON" ]; then
    echo "Usage: $0 <theme_list.json> <zips_dir> <screenshots_dir> <release_tag> <output.json> [repo]"
    exit 1
fi

echo '{"data":[' > "$OUTPUT_JSON"
first=true

while read -r entry; do
    name=$(echo "$entry" | jq -r '.name')
    author=$(echo "$entry" | jq -r '.author')
    repo=$(echo "$entry" | jq -r '.repo')

    zip_file="$ZIPS_DIR/${name}.zip"
    if [ ! -f "$zip_file" ]; then
        echo "WARNING: $zip_file not found, skipping $name"
        continue
    fi

    # Size in MB
    size_mb=$(du -sm "$zip_file" | cut -f1)

    # Last commit date from GitHub
    last_update=$(gh api "repos/$repo/commits?per_page=1" --jq '.[0].commit.committer.date' 2>/dev/null | cut -dT -f1)
    [ -z "$last_update" ] && last_update="unknown"

    # Screenshot extension
    screenshot=""
    for ext in jpg png; do
        if [ -f "$SCREENSHOTS_DIR/${name}.${ext}" ]; then
            screenshot="screenshots/${name}.${ext}"
            break
        fi
    done

    # Download URL
    download_url="https://github.com/${REPO}/releases/download/${RELEASE_TAG}/${name}.zip"

    if [ "$first" = true ]; then
        first=false
    else
        echo ',' >> "$OUTPUT_JSON"
    fi

    cat >> "$OUTPUT_JSON" <<ENTRY
  {
    "theme": "$name",
    "author": "$author",
    "download_url": "$download_url",
    "size": $size_mb,
    "screenshot": "$screenshot",
    "last_update": "$last_update"
  }
ENTRY

done < <(jq -c '.[]' "$THEME_LIST")

echo ']}' >> "$OUTPUT_JSON"

echo "Generated $OUTPUT_JSON"
