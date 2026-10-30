#!/bin/zsh
# Developer ID 簽章 → DMG → Apple 公證 → staple
# 用法：./scripts/release.sh [版本號，例如 1.0.0]
#
# 公證帳號（二選一）：
#   本機：先跑一次 xcrun notarytool store-credentials aiusage-notary --apple-id <Apple ID> --team-id <Team ID>
#   CI  ：設環境變數 APPLE_ID、APPLE_APP_PASSWORD
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || VERSION="0.0.${BUILD_NUMBER:-1}"
TEAM_ID="${TEAM_ID:-$(awk -F'"' '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-aiusage-notary}"

command -v xcodegen >/dev/null || { echo "請先 brew install xcodegen"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "✗ Keychain 裡沒有 Developer ID Application 憑證（Xcode → Settings → Accounts → Manage Certificates → + 建一張）"; exit 1; }

echo "▸ v$VERSION  team $TEAM_ID"
rm -rf build dist && mkdir -p dist
xcodegen generate --quiet

echo "▸ Building (universal, Release)…"
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  -quiet build

APP="build/Build/Products/Release/AIUsage.app"
echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime"

echo "▸ Creating DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/AIUsage-$VERSION.dmg"
hdiutil create -volname "AI Usage" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▸ Notarizing（通常 1～5 分鐘）…"
if [[ -n "${APPLE_ID:-}" ]]; then
  AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
else
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
OUT="$(xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait 2>&1)" || true
echo "$OUT"
if ! grep -q "status: Accepted" <<<"$OUT"; then
  ID="$(awk '/^  id:/{print $2; exit}' <<<"$OUT")"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  echo "✗ 公證失敗"; exit 1
fi

xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "✓ $DMG"
