#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

cleanup_paths=()
cleanup() {
  for cleanup_path in "${cleanup_paths[@]}"; do
    rm -rf "$cleanup_path"
  done
}
trap cleanup EXIT

echo "== git status =="
git status --short

echo "== public source marker scan =="
badfile="$(mktemp /tmp/anyconnectclient-publication-audit.XXXXXX)"
private_pattern="${ANYCONNECTCLIENT_PRIVATE_MARKERS:-}"
if [[ -z "$private_pattern" ]]; then
  echo "deployment-specific marker scan skipped; set ANYCONNECTCLIENT_PRIVATE_MARKERS to enable it"
elif command -v rg >/dev/null 2>&1; then
  rg -n --hidden --no-messages -i -e "$private_pattern" \
    --glob '!.git/**' \
    --glob '!.codex/**' \
    --glob '!.agents/**' \
    --glob '!.idea/**' \
    --glob '!ThirdParty/**' \
    --glob '!Tests/**' \
    --glob '!build/**' \
    --glob '!.build/**' \
    --glob '!Assets/AppIcon.iconset/**' \
    --glob '!*.zip' \
    --glob '!.vpn_access_profile' \
    --glob '!.vpn-access-credentials' \
    --glob '!.vpn_access_credentials' \
    . > "$badfile" || true
else
  git grep -n -i -E "$private_pattern" -- \
    ':!ThirdParty/**' \
    ':!Tests/**' \
    ':!build/**' \
    ':!.build/**' \
    ':!Assets/AppIcon.iconset/**' > "$badfile" || true
fi

if [[ -s "$badfile" ]]; then
  echo "FAIL: possible private marker found in public non-vendor source:" >&2
  sed -n '1,120p' "$badfile" >&2
  exit 1
fi

echo "OK: no known private markers in public non-vendor source"

tracked_secret_files="$(git ls-files -- .vpn_access_profile .vpn-access-credentials .vpn_access_credentials)"
if [[ -n "$tracked_secret_files" ]]; then
  echo "FAIL: local secret files are tracked by git:" >&2
  echo "$tracked_secret_files" >&2
  exit 1
fi

echo "== ignored local secret files =="
for secret_path in .vpn_access_profile .vpn-access-credentials .vpn_access_credentials; do
  if [[ -e "$secret_path" ]]; then
    echo "local ignored secret file present: $secret_path"
  fi
done

echo "== release bundle audit =="
release_app="build/release/AnyConnectClient-1.0.0-build1/AnyConnectClient.app"
release_zip="build/release/AnyConnectClient-1.0.0-build1/AnyConnectClient-1.0.0-build1-macos-arm64.zip"
if [[ ! -d "$release_app" && -f "$release_zip" ]]; then
  extracted_release="$(mktemp -d /tmp/anyconnectclient-release.XXXXXX)"
  cleanup_paths+=("$extracted_release")
  ditto -x -k "$release_zip" "$extracted_release"
  release_app="$extracted_release/AnyConnectClient.app"
fi

if [[ -d "$release_app" ]]; then
  codesign --verify --deep --strict "$release_app"
  plutil -p "$release_app/Contents/Info.plist" | grep -E 'CFBundleIcon|CFBundleShortVersionString|CFBundleVersion'

  macho_paths="$(mktemp /tmp/anyconnectclient-macho-paths.XXXXXX)"
  find "$release_app" -type f -perm -111 -exec otool -l {} \; \
    | awk '$1 == "name" || $1 == "path" { print }' \
    | grep -E '/Applications/Xcode|/opt/homebrew|/usr/local|/Users/|/private/tmp' > "$macho_paths" || true

  if [[ -s "$macho_paths" ]]; then
    echo "FAIL: non-portable Mach-O dependency/rpath entries found:" >&2
    sed -n '1,120p' "$macho_paths" >&2
    exit 1
  fi

  echo "OK: release bundle is signed and Mach-O paths are portable"
else
  echo "release bundle not found; skipping bundle audit"
fi
