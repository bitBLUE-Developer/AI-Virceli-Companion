#!/usr/bin/env bash
set -euo pipefail

# Build an install-style DMG:
# - contains "<App>.app"
# - contains "Applications" symlink for drag-and-drop install
#
# Usage:
#   ./scripts/make_install_dmg.sh \
#     --app "/absolute/path/Virceli.app" \
#     --out "/absolute/path/Virceli.dmg"

APP_PATH=""
OUT_PATH=""
VOLNAME="Virceli"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --out)
      OUT_PATH="${2:-}"
      shift 2
      ;;
    --volname)
      VOLNAME="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${APP_PATH}" || -z "${OUT_PATH}" ]]; then
  echo "Usage: $0 --app /abs/path/App.app --out /abs/path/App.dmg [--volname Name]" >&2
  exit 1
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App not found: ${APP_PATH}" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d /tmp/virceli-dmg-stage.XXXXXX)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

APP_NAME="$(basename "${APP_PATH}")"
mkdir -p "${STAGE_DIR}"
cp -R "${APP_PATH}" "${STAGE_DIR}/${APP_NAME}"
ln -s /Applications "${STAGE_DIR}/Applications"

mkdir -p "$(dirname "${OUT_PATH}")"
rm -f "${OUT_PATH}"
hdiutil create \
  -volname "${VOLNAME}" \
  -srcfolder "${STAGE_DIR}" \
  -ov \
  -format UDZO \
  "${OUT_PATH}"

echo "DMG created:"
echo "  ${OUT_PATH}"
