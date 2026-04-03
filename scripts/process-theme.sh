#!/bin/bash
#
# Process a single theme for REG-Station:
#   1. Clone (shallow)
#   2. Validate (theme.xml or theme.json exists)
#   3. Strip videos and .git
#   4. Downscale oversized images
#   5. ETC1 compress opaque textures
#   6. Extract screenshot
#   7. Convert XML to JSON (REG-ES native format)
#   8. Package as .zip
#
# Usage: process-theme.sh <name> <github_repo> <output_dir> <screenshots_dir> [etctool_path]
#

set -e

NAME="$1"
REPO="$2"
OUTPUT_DIR="$3"
SCREENSHOTS_DIR="$4"
ETCTOOL="${5:-}"

if [ -z "$NAME" ] || [ -z "$REPO" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <name> <repo> <output_dir> <screenshots_dir> [etctool_path]"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "=== Processing: $NAME ==="

# 1. Clone (shallow, single branch)
echo "  Cloning $REPO..."
git clone --depth 1 "https://github.com/$REPO.git" "$WORK_DIR/$NAME" 2>/dev/null
if [ ! -d "$WORK_DIR/$NAME" ]; then
    echo "  ERROR: clone failed"
    exit 1
fi

# 2. Validate — theme.xml or theme.json may be at root or in per-system subdirectories
found=$(find "$WORK_DIR/$NAME" -maxdepth 2 \( -name "theme.xml" -o -name "theme.json" \) | head -1)
if [ -z "$found" ]; then
    echo "  ERROR: no theme.xml or theme.json found anywhere"
    exit 1
fi
echo "  Validated: theme file found ($(basename "$found"))"

# 3. Strip .git and video files
rm -rf "$WORK_DIR/$NAME/.git" "$WORK_DIR/$NAME/.github"
find "$WORK_DIR/$NAME" -type f \( \
    -iname "*.mp4" -o -iname "*.webm" -o -iname "*.ogv" \
    -o -iname "*.avi" -o -iname "*.mkv" \
\) -delete -print 2>/dev/null | while read f; do
    echo "  Stripped video: $(basename "$f")"
done

# 4. Downscale oversized images (>1920 in any dimension)
if command -v convert >/dev/null 2>&1; then
    find "$WORK_DIR/$NAME" -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) | while read img; do
        dims=$(identify -format "%w %h" "$img" 2>/dev/null) || continue
        w=$(echo "$dims" | cut -d' ' -f1)
        h=$(echo "$dims" | cut -d' ' -f2)
        if [ "$w" -gt 1920 ] || [ "$h" -gt 1080 ]; then
            echo "  Downscaling: $(basename "$img") (${w}x${h})"
            convert "$img" -resize "1920x1080>" "$img"
        fi
    done
else
    echo "  WARNING: ImageMagick not found, skipping downscale"
fi

# 5. ETC1 compress opaque textures (JPEGs only — always opaque, no alpha check needed)
if [ -n "$ETCTOOL" ] && command -v "$ETCTOOL" >/dev/null 2>&1; then
    echo "  ETC1 compressing JPEGs..."
    compressed=0
    find "$WORK_DIR/$NAME" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | while read img; do
        stem="${img%.*}"
        "$ETCTOOL" "$img" -format ETC1 -effort 80 -output "${stem}.pkm" 2>/dev/null || true
    done
    echo "  ETC1 done"
else
    echo "  Skipping ETC1 (no EtcTool)"
fi

# 6. Extract screenshot — try multiple sources
mkdir -p "$SCREENSHOTS_DIR"
screenshot=""

# A) Check theme repo for common screenshot locations
for candidate in \
    "$WORK_DIR/$NAME/_inc/screenshot.jpg" \
    "$WORK_DIR/$NAME/_inc/screenshot.png" \
    "$WORK_DIR/$NAME/screenshot.jpg" \
    "$WORK_DIR/$NAME/screenshot.png" \
    "$WORK_DIR/$NAME/_inc/images/screenshot.jpg" \
    "$WORK_DIR/$NAME/_inc/images/screenshot.png"; do
    if [ -f "$candidate" ]; then
        screenshot="$candidate"
        break
    fi
done

# B) Try GitHub repo social preview image
if [ -z "$screenshot" ]; then
    og_url=$(curl -sL "https://github.com/$REPO" | grep -o 'og:image.*content="[^"]*"' | grep -o 'https://repository-images[^"]*' | head -1)
    if [ -n "$og_url" ]; then
        curl -sfL "$og_url" -o "$SCREENSHOTS_DIR/${NAME}.jpg" 2>/dev/null && \
            echo "  Screenshot from GitHub social preview" && screenshot="done"
    fi
fi

if [ -n "$screenshot" ] && [ "$screenshot" != "done" ]; then
    ext="${screenshot##*.}"
    cp "$screenshot" "$SCREENSHOTS_DIR/${NAME}.${ext}"
    echo "  Screenshot: ${NAME}.${ext}"
elif [ -z "$screenshot" ]; then
    # C) Keep existing screenshot if already in repo
    if [ -f "screenshots/${NAME}.jpg" ]; then
        echo "  Screenshot: keeping existing"
    else
        echo "  WARNING: no screenshot found"
    fi
fi

# 7. Convert XML theme files to JSON
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/convert_theme_xml_to_json.py"
SCHEMA="$SCRIPT_DIR/theme_schema.json"

xml_count=$(find "$WORK_DIR/$NAME" -type f -iname "*.xml" | wc -l)
if [ "$xml_count" -gt 0 ] && [ -f "$CONVERTER" ] && [ -f "$SCHEMA" ]; then
    echo "  Converting $xml_count XML files to JSON..."
    python3 "$CONVERTER" "$WORK_DIR/$NAME" --schema "$SCHEMA" || {
        echo "  ERROR: XML to JSON conversion failed"
        exit 1
    }
    # Remove original XML files — REG-ES only loads JSON
    find "$WORK_DIR/$NAME" -type f -iname "*.xml" -delete
    json_count=$(find "$WORK_DIR/$NAME" -type f -iname "*.json" | wc -l)
    echo "  Converted: $json_count JSON files, XML originals removed"
else
    if [ "$xml_count" -eq 0 ]; then
        echo "  No XML files to convert (theme already JSON)"
    else
        echo "  WARNING: converter or schema not found, skipping XML→JSON conversion"
    fi
fi

# 8. Package as .zip
mkdir -p "$OUTPUT_DIR"
(cd "$WORK_DIR" && zip -qr "$OUTPUT_DIR/${NAME}.zip" "$NAME/")
size_mb=$(du -sm "$OUTPUT_DIR/${NAME}.zip" | cut -f1)
echo "  Packaged: ${NAME}.zip (${size_mb}MB)"
echo "  Done."
