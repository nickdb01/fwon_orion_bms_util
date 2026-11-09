#!/bin/bash
set -euo pipefail
ORION_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ORION_ROOT"
ORION_ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then ORION_ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
"$ORION_ROOT/scripts/swiftw" build -c release -debug-info-format none "${ORION_ARCH_FLAGS[@]}"
ORION_BIN_DIR="$("$ORION_ROOT/scripts/swiftw" build -c release -debug-info-format none "${ORION_ARCH_FLAGS[@]}" --show-bin-path)"
ORION_APP="$ORION_ROOT/dist/Orion Diagnostics.app"
mkdir -p "$ORION_APP/Contents/MacOS" "$ORION_APP/Contents/Resources" "$ORION_ROOT/.build/AppIcon.iconset"
cp "$ORION_BIN_DIR/OrionDiagnostics" "$ORION_APP/Contents/MacOS/OrionDiagnostics"
cat > "$ORION_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OrionDiagnostics</string>
<key>CFBundleIdentifier</key><string>local.oriondiagnostics.mac</string>
<key>CFBundleName</key><string>Orion Diagnostics</string>
<key>CFBundleDisplayName</key><string>Orion Diagnostics</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"; fi
export CLANG_MODULE_CACHE_PATH="$ORION_ROOT/.build/clang-cache"
xcrun swift "$ORION_ROOT/scripts/make-icon.swift" "$ORION_ROOT/.build/AppIcon.png"
for ORION_SIZE in 16 32 128 256 512; do
    sips -z "$ORION_SIZE" "$ORION_SIZE" "$ORION_ROOT/.build/AppIcon.png" --out "$ORION_ROOT/.build/AppIcon.iconset/icon_${ORION_SIZE}x${ORION_SIZE}.png" >/dev/null
    ORION_DOUBLE=$((ORION_SIZE * 2))
    sips -z "$ORION_DOUBLE" "$ORION_DOUBLE" "$ORION_ROOT/.build/AppIcon.png" --out "$ORION_ROOT/.build/AppIcon.iconset/icon_${ORION_SIZE}x${ORION_SIZE}@2x.png" >/dev/null
done
python3 "$ORION_ROOT/scripts/make-icns.py" "$ORION_ROOT/.build/AppIcon.iconset" "$ORION_APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signing permits local execution. Developer ID distribution is separate.
codesign --force --sign - --timestamp=none "$ORION_APP"
codesign --verify --deep --strict "$ORION_APP"
ditto -c -k --sequesterRsrc --keepParent "$ORION_APP" "$ORION_ROOT/dist/Orion-Diagnostics-macOS.zip"
printf 'Built %s\n' "$ORION_APP"
