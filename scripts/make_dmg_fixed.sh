#!/usr/bin/env bash
set -euo pipefail

# Fixed-path DMG builder for internal distribution.
#
# Usage:
#   1) Put app bundle here:
#      /Users/jaydensuh/Documents/Codex/PJ1/dist/app-drop/Virceli.app
#   2) Run:
#      /Users/jaydensuh/Documents/Codex/PJ1/native-macos/scripts/make_dmg_fixed.sh
#   3) Output DMG:
#      /Users/jaydensuh/Documents/Codex/PJ1/dist/dmg/Virceli-install.dmg

PROJECT_ROOT="/Users/jaydensuh/Documents/Codex/PJ1"
INPUT_APP="${PROJECT_ROOT}/dist/app-drop/Virceli.app"
OUTPUT_DIR="${PROJECT_ROOT}/dist/dmg"
OUTPUT_DMG="${OUTPUT_DIR}/Virceli-install.dmg"
VOLUME_NAME="Virceli"

if [[ ! -d "${INPUT_APP}" ]]; then
  echo "App not found:"
  echo "  ${INPUT_APP}"
  echo ""
  echo "Put your built Virceli.app in the fixed input folder and run again."
  exit 1
fi

STAGE_DIR="$(mktemp -d /tmp/virceli-dmg-fixed.XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"
cp -R "${INPUT_APP}" "${STAGE_DIR}/Virceli.app"
ln -s /Applications "${STAGE_DIR}/Applications"

rm -f "${OUTPUT_DMG}"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DMG}"

echo "Done."
echo "Input app : ${INPUT_APP}"
echo "Output DMG: ${OUTPUT_DMG}"
