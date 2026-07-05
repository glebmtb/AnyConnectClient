#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
BUILD_NUMBER="${2:-1}"
APP_NAME="AnyConnectClient"
EXECUTABLE_NAME="AnyConnectClientApp"
RELEASE_ROOT="$ROOT_DIR/build/release/$APP_NAME-$VERSION-build$BUILD_NUMBER"
APP_BUNDLE="$RELEASE_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
ZIP_PATH="$RELEASE_ROOT/$APP_NAME-$VERSION-build$BUILD_NUMBER-macos-arm64.zip"

APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"
APP_ICON_GENERATOR="$ROOT_DIR/Scripts/generate-app-icon.swift"
OPENCONNECT_SOURCE="$ROOT_DIR/ThirdParty/openconnect-9.21/openconnect"
OCPROXY_SOURCE="$ROOT_DIR/ThirdParty/ocproxy/ocproxy"
SWIFTPM_EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/release/$EXECUTABLE_NAME"

if [[ -e "$RELEASE_ROOT" ]]; then
  echo "Release output already exists: $RELEASE_ROOT" >&2
  echo "Move it away or choose another build number." >&2
  exit 2
fi

for binary in "$OPENCONNECT_SOURCE" "$OCPROXY_SOURCE"; do
  if [[ ! -x "$binary" ]]; then
    echo "Required runtime binary is missing or not executable: $binary" >&2
    exit 2
  fi
done

cd "$ROOT_DIR"
if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  swift "$APP_ICON_GENERATOR" >/dev/null
fi
swift build -c release --product "$EXECUTABLE_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS"
ditto "$SWIFTPM_EXECUTABLE" "$APP_MACOS/$EXECUTABLE_NAME"
ditto "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
ditto "$OPENCONNECT_SOURCE" "$APP_RESOURCES/openconnect"
ditto "$OCPROXY_SOURCE" "$APP_RESOURCES/ocproxy"
chmod 755 "$APP_MACOS/$EXECUTABLE_NAME" "$APP_RESOURCES/openconnect" "$APP_RESOURCES/ocproxy"

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.anyconnectclient</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSFaceIDUsageDescription</key>
  <string>Unlock the VPN credential vault for this app session.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

is_bundleable_dependency() {
  local path="$1"
  [[ "$path" == /opt/homebrew/* || "$path" == /usr/local/* ]]
}

copy_dependencies() {
  local binary="$1"
  chmod u+w "$binary"

  if [[ "$binary" == "$APP_FRAMEWORKS/"* ]]; then
    install_name_tool -id "@rpath/${binary:t}" "$binary" 2>/dev/null || true
  fi

  local deps
  deps=("${(@f)$(otool -L "$binary" | awk 'NR > 1 { print $1 }')}")
  local dep
  for dep in "${deps[@]}"; do
    if ! is_bundleable_dependency "$dep"; then
      continue
    fi

    local dep_name="${dep:t}"
    local bundled="$APP_FRAMEWORKS/$dep_name"
    if [[ ! -f "$bundled" ]]; then
      ditto "$dep" "$bundled"
      chmod 755 "$bundled"
      copy_dependencies "$bundled"
    fi

    install_name_tool -change "$dep" "@executable_path/../Frameworks/$dep_name" "$binary"
  done
}

remove_nonportable_rpaths() {
  local binary="$1"
  local rpaths
  rpaths=("${(@f)$(otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ')}")

  local rpath
  for rpath in "${rpaths[@]}"; do
    case "$rpath" in
      /Applications/Xcode.app/*|/opt/homebrew/*|/usr/local/*|/Users/*|/private/tmp/*)
        chmod u+w "$binary"
        install_name_tool -delete_rpath "$rpath" "$binary" 2>/dev/null || true
        ;;
    esac
  done
}

copy_dependencies "$APP_RESOURCES/openconnect"
copy_dependencies "$APP_RESOURCES/ocproxy"

while IFS= read -r -d '' binary; do
  remove_nonportable_rpaths "$binary"
done < <(find "$APP_BUNDLE" -type f -perm +111 -print0)

codesign --force --deep --sign - "$APP_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "$APP_BUNDLE"
echo "$ZIP_PATH"
