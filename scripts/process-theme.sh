#!/bin/bash
#
# Process a single theme for REG-Station:
#   1. Clone (shallow)
#   2. Validate (theme.xml exists)
#   3. Strip videos and .git
#   4. Downscale oversized images
#   5. ETC1 compress opaque textures
#   6. Extract screenshot
#   7. Package as .zip
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

# 2. Validate
if [ ! -f "$WORK_DIR/$NAME/theme.xml" ]; then
    echo "  WARNING: no theme.xml at root, checking subdirs..."
    # Some themes nest the theme.xml one level deep
    found=$(find "$WORK_DIR/$NAME" -maxdepth 2 -name "theme.xml" | head -1)
    if [ -z "$found" ]; then
        echo "  ERROR: no theme.xml found"
        exit 1
    fi
    echo "  Found: $found"
fi

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

# 5. ETC1 compress opaque textures
if [ -n "$ETCTOOL" ] && command -v "$ETCTOOL" >/dev/null 2>&1; then
    echo "  ETC1 compressing..."
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/../../compress-theme-etc1.sh" ]; then
        bash "$SCRIPT_DIR/../../compress-theme-etc1.sh" "$WORK_DIR/$NAME" "$ETCTOOL" 80
    else
        # Inline fallback: compress JPEGs only (always opaque)
        find "$WORK_DIR/$NAME" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | while read img; do
            stem="${img%.*}"
            "$ETCTOOL" "$img" -format ETC1 -effort 80 -output "${stem}.pkm" 2>/dev/null && \
                echo "  PKM: $(basename "${stem}.pkm")"
        done
    fi
else
    echo "  Skipping ETC1 (no EtcTool)"
fi

# 6. Extract screenshot
mkdir -p "$SCREENSHOTS_DIR"
screenshot=""
# Look for common screenshot locations
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

if [ -n "$screenshot" ]; then
    ext="${screenshot##*.}"
    cp "$screenshot" "$SCREENSHOTS_DIR/${NAME}.${ext}"
    echo "  Screenshot: ${NAME}.${ext}"
else
    echo "  WARNING: no screenshot found"
fi

# 7. Package as .zip
mkdir -p "$OUTPUT_DIR"
(cd "$WORK_DIR" && zip -qr "$OUTPUT_DIR/${NAME}.zip" "$NAME/")
size_mb=$(du -sm "$OUTPUT_DIR/${NAME}.zip" | cut -f1)
echo "  Packaged: ${NAME}.zip (${size_mb}MB)"
echo "  Done."
