#!/bin/bash
rm -rf VoiceType.app
mkdir -p VoiceType.app/Contents/MacOS
mkdir -p VoiceType.app/Contents/Resources

# Copy executable
# Get build path dynamically
BUILD_PATH=$(swift build --show-bin-path -c release)
echo "Build path: $BUILD_PATH"

# Copy executable
if [ -f "$BUILD_PATH/VoiceType" ]; then
    cp "$BUILD_PATH/VoiceType" VoiceType.app/Contents/MacOS/
else
    echo "❌ Error: VoiceType binary not found in $BUILD_PATH"
    exit 1
fi

# Copy Info.plist (Prefer correct source)
if [ -f "VoiceType/Info.plist" ]; then
    cp VoiceType/Info.plist VoiceType.app/Contents/
elif [ -f "Info.plist" ]; then
    cp Info.plist VoiceType.app/Contents/
else
    echo "⚠️ Info.plist not found!"
fi

# Copy resources
# First checking for bundle created by SPM
if [ -d ".build/release/VoiceType_VoiceType.bundle" ]; then
    echo "Using SPM bundle resources..."
    cp -r .build/release/VoiceType_VoiceType.bundle VoiceType.app/Contents/Resources/
fi

# Compile Metal shaders for MLX (if not already done)
MLX_METAL_PATH=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
METAL_BUILD_DIR="temp_metal_build"
if [ ! -f "$METAL_BUILD_DIR/default.metallib" ]; then
    echo "Compiling Metal shaders..."
    mkdir -p "$METAL_BUILD_DIR"
    find "$MLX_METAL_PATH" -name "*.metal" -print0 | while IFS= read -r -d '' file; do
        filename=$(basename "$file")
        /usr/bin/xcrun metal -c "$file" -I "$MLX_METAL_PATH" -o "$METAL_BUILD_DIR/$filename.air"
    done
    /usr/bin/xcrun metallib "$METAL_BUILD_DIR"/*.air -o "$METAL_BUILD_DIR/default.metallib"
fi

# Create MLX bundle with Metal library
mkdir -p VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle
cp "$METAL_BUILD_DIR/default.metallib" VoiceType.app/Contents/Resources/mlx-swift_Cmlx.bundle/

# Always compile assets for the main app icon
echo "Compiling assets..."
/usr/bin/xcrun actool Sources/VoiceType/Resources/Assets.xcassets --compile VoiceType.app/Contents/Resources --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist /tmp/partial.plist

# Copy Info.plist to inside Contents (redundant but standard locally) - NO, already did it above correctly.
# The previous script did it twice. We do it once above.

# update Info.plist inside the app bundle
# Verify file exists first
if [ -f "VoiceType.app/Contents/Info.plist" ]; then
    # Update Info.plist variables
    sed -i '' 's/\$(EXECUTABLE_NAME)/VoiceType/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.nikti.VoiceType/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(PRODUCT_NAME)/VoiceType/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(MARKETING_VERSION)/1.0/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(CURRENT_PROJECT_VERSION)/1/g' VoiceType.app/Contents/Info.plist
    sed -i '' 's/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g' VoiceType.app/Contents/Info.plist
else
    echo "❌ Error: Info.plist missing in built app bundle"
    exit 1
fi

# Copy entitlements
if [ -f "VoiceType.entitlements" ]; then
    cp VoiceType.entitlements VoiceType.app/Contents/Resources/
fi

# Sign app
codesign --force --deep --sign - --entitlements VoiceType.entitlements VoiceType.app

echo "✅ App packaged to VoiceType.app"
