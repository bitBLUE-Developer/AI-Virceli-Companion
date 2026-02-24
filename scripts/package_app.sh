#!/usr/bin/env bash
set -euo pipefail

# Package SwiftPM executable output into a macOS .app and optional .dmg.
#
# Usage:
#   ./scripts/package_app.sh \
#     --input "/path/to/Built Products export folder" \
#     --name "AI Virceli" \
#     --bundle-id "com.virceli.app" \
#     --version "1.0.0" \
#     --build "1" \
#     --dmg

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${PROJECT_DIR}/dist"

INPUT_DIR=""
APP_NAME="AI Virceli"
BUNDLE_ID="com.virceli.app"
VERSION="1.0.0"
BUILD_NUMBER="1"
MAKE_DMG="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_DIR="${2:-}"
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --dmg)
      MAKE_DMG="1"
      shift 1
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${INPUT_DIR}" ]]; then
  echo "Missing --input. Pass the Xcode 'Built Products' export folder path." >&2
  exit 1
fi

if [[ ! -d "${INPUT_DIR}" ]]; then
  echo "Input folder not found: ${INPUT_DIR}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"

EXEC_CANDIDATE=""
if [[ -x "${INPUT_DIR}/ClaudeNativeMac" ]]; then
  EXEC_CANDIDATE="${INPUT_DIR}/ClaudeNativeMac"
elif [[ -x "${INPUT_DIR}/bin/ClaudeNativeMac" ]]; then
  EXEC_CANDIDATE="${INPUT_DIR}/bin/ClaudeNativeMac"
else
  EXEC_CANDIDATE="$(find "${INPUT_DIR}" -type f -name "ClaudeNativeMac" -perm -111 | head -n 1 || true)"
fi

if [[ -z "${EXEC_CANDIDATE}" ]]; then
  echo "Could not find executable 'ClaudeNativeMac' under: ${INPUT_DIR}" >&2
  exit 1
fi

cp "${EXEC_CANDIDATE}" "${MACOS_DIR}/ClaudeNativeMac"
chmod +x "${MACOS_DIR}/ClaudeNativeMac"

# Copy runtime frameworks if present in exported folder.
if [[ -d "${INPUT_DIR}/PackageFrameworks" ]]; then
  cp -R "${INPUT_DIR}/PackageFrameworks/"* "${FRAMEWORKS_DIR}/" || true
fi
if [[ -d "${INPUT_DIR}/Frameworks" ]]; then
  cp -R "${INPUT_DIR}/Frameworks/"* "${FRAMEWORKS_DIR}/" || true
fi

# Copy project runtime resources used by the app.
if [[ -d "${PROJECT_DIR}/Resources" ]]; then
  cp -R "${PROJECT_DIR}/Resources/"* "${RES_DIR}/" || true
fi
if [[ -d "${PROJECT_DIR}/public" ]]; then
  mkdir -p "${RES_DIR}/public"
  cp -R "${PROJECT_DIR}/public/"* "${RES_DIR}/public/" || true
fi

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ClaudeNativeMac</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle is launchable on local machine.
codesign --force --deep --sign - "${APP_DIR}"

echo "App packaged:"
echo "  ${APP_DIR}"

if [[ "${MAKE_DMG}" == "1" ]]; then
  DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
  rm -f "${DMG_PATH}"
  hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_DIR}" -ov -format UDZO "${DMG_PATH}" >/dev/null
  echo "DMG packaged:"
  echo "  ${DMG_PATH}"
fi
