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

# 2. Validate — theme.xml may be at root or in per-system subdirectories
found=$(find "$WORK_DIR/$NAME" -maxdepth 2 -name "theme.xml" | head -1)
if [ -z "$found" ]; then
    echo "  ERROR: no theme.xml found anywhere"
    exit 1
fi
echo "  Validated: theme.xml found"

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

# 7. Package as .zip
mkdir -p "$OUTPUT_DIR"
(cd "$WORK_DIR" && zip -qr "$OUTPUT_DIR/${NAME}.zip" "$NAME/")
size_mb=$(du -sm "$OUTPUT_DIR/${NAME}.zip" | cut -f1)
echo "  Packaged: ${NAME}.zip (${size_mb}MB)"
echo "  Done."
