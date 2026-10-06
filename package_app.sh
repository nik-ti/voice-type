#!/bin/bash
# Build and validate a fresh app, then install it to /Applications/VoiceType.app.
# Shader caches are keyed by their source and compiler; failed builds preserve the installed app.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
if ! mkdir .build/package.lock 2>/dev/null; then
    echo "Another packaging run is active (.build/package.lock)." >&2
    exit 1
fi
install_dir="${VOICETYPE_INSTALL_DIR:-/Applications}"
installed="$install_dir/VoiceType.app"
stage=""
backup=""
cleanup() {
    if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -d "$installed" ]; then
        mv "$backup" "$installed"
    fi
    if [ -n "$stage" ] && [ -d "$stage" ]; then rm -rf "$stage"; fi
    rmdir .build/package.lock
}
trap cleanup EXIT

swift build -c release --disable-automatic-resolution
build_path="$(swift build -c release --show-bin-path --disable-automatic-resolution)"
test -x "$build_path/VoiceType"
stage="$(mktemp -d "$PWD/.build/package.XXXXXX")"
app="$stage/VoiceType.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_path/VoiceType" "$app/Contents/MacOS/VoiceType"
for resource in "$build_path"/*.bundle; do
    [ ! -d "$resource" ] || cp -R "$resource" "$app/Contents/Resources/"
done

metal_source="$PWD/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
metal_version="$(xcrun metal --version)"
shader_key="$(python3 - "$metal_source" "$metal_version" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
digest = hashlib.sha256(sys.argv[2].encode())
for path in sorted(root.rglob('*')):
    if path.is_file():
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
print(digest.hexdigest()[:20])
PY
)"
shader_cache="$PWD/.build/metal-$shader_key"
if [ ! -s "$shader_cache/default.metallib" ]; then
    echo "Compiling MLX shaders for this source and compiler..."
    mkdir -p "$stage/metal"
    index=0
    while IFS= read -r -d '' source; do
        index=$((index + 1))
        xcrun metal -c "$source" -I "$metal_source" -o "$stage/metal/$index.air"
    done < <(find "$metal_source" -name '*.metal' -print0)
    xcrun metallib "$stage/metal"/*.air -o "$stage/metal/default.metallib"
    mkdir -p "$shader_cache"
    cp "$stage/metal/default.metallib" "$shader_cache/default.metallib"
fi
mkdir -p "$app/Contents/Resources/mlx-swift_Cmlx.bundle"
cp "$shader_cache/default.metallib" "$app/Contents/Resources/mlx-swift_Cmlx.bundle/"

xcrun actool Sources/VoiceType/Resources/Assets.xcassets \
    --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$stage/assets.plist"
revision="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then revision="$revision-dirty"; fi
build_id="$(date -u +%Y%m%dT%H%M%SZ)-$revision"
python3 - "$app" "$stage/assets.plist" "$build_id" <<'PY'
from pathlib import Path
import plistlib
import sys
source = Path('VoiceType/Info.plist')
if not source.exists():
    source = Path('Info.plist')
info = plistlib.loads(source.read_bytes())
info.update(plistlib.loads(Path(sys.argv[2]).read_bytes()))
info.update(CFBundleDevelopmentRegion='en', CFBundleExecutable='VoiceType',
            CFBundleIdentifier='com.nikti.VoiceType', CFBundleName='VoiceType',
            CFBundlePackageType='APPL', CFBundleShortVersionString='1.0.1',
            CFBundleVersion='2', LSMinimumSystemVersion='14.0', VoiceTypeBuildID=sys.argv[3])
info.pop('NSAppleEventsUsageDescription', None)
Path(sys.argv[1], 'Contents', 'Info.plist').write_bytes(plistlib.dumps(info))
PY
cp VoiceType.entitlements "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist"
codesign --force --deep --sign - --entitlements VoiceType.entitlements "$app"
codesign --verify --deep --strict "$app"
test -s "$app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"

# Quit the running copy so the new build is what actually opens.
osascript -e 'quit app id "com.nikti.VoiceType"' >/dev/null 2>&1 || true
if [ -d "$installed" ]; then
    backup="$PWD/.build/VoiceType.previous.$build_id.app"
    mv "$installed" "$backup"
fi
mv "$app" "$installed"
# Older builds were left in the project folder; remove that copy so only one app exists.
if [ -d VoiceType.app ]; then mv VoiceType.app "$PWD/.build/VoiceType.project-copy.$build_id.app"; fi
echo "Installed $installed ($build_id)"
if [ -n "$backup" ]; then echo "Previous app retained at $backup"; fi
