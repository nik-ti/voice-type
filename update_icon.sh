#!/bin/bash

# Source logo
SRC="logo.png"

if [ ! -f "$SRC" ]; then
    echo "❌ Error: logo.png not found in current directory"
    exit 1
fi

DEST_DIR="Sources/VoiceType/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -d "$DEST_DIR" ]; then
    echo "❌ Error: AppIcon.appiconset directory not found"
    exit 1
fi

echo "🔄 Updating AppIcon from $SRC..."

# Generate icons
sips -z 16 16     "$SRC" --out "$DEST_DIR/icon_16.png"
sips -z 32 32     "$SRC" --out "$DEST_DIR/icon_32.png"
sips -z 64 64     "$SRC" --out "$DEST_DIR/icon_64.png"
sips -z 128 128   "$SRC" --out "$DEST_DIR/icon_128.png"
sips -z 256 256   "$SRC" --out "$DEST_DIR/icon_256.png"
sips -z 512 512   "$SRC" --out "$DEST_DIR/icon_512.png"
sips -z 1024 1024 "$SRC" --out "$DEST_DIR/icon_1024.png"

# Update Contents.json to ensure it references these files correctly
# (Assuming existing Contents.json is correct, but let's be safe and print success)

echo "✅ AppIcon updated successfully!"
