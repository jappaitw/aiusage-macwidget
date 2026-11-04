#!/bin/zsh
# Universal（arm64 + x86_64）Release build → DMG，所有 Apple Silicon／Intel Mac 都能安裝
# 用法：./scripts/release.sh [版本號，例如 1.0.0]
#
# 兩種模式：
#   Developer ID（預設，Keychain 裡有「Developer ID Application」憑證時）：
#     簽章 → DMG → Apple 公證 → staple，使用者下載後直接打開
#     公證帳號（二選一）：
#       本機：先跑一次 xcrun notarytool store-credentials aiusage-notary --apple-id <Apple ID> --team-id <Team ID>
#       CI  ：設環境變數 APPLE_ID、APPLE_APP_PASSWORD
#   Ad-hoc（ADHOC=1，或找不到 Developer ID 憑證時自動退回）：
#     不需要付費開發者帳號，產出 *-unsigned.dmg；使用者第一次打開要過 Gatekeeper
#     （右鍵開啟，或 xattr -dr com.apple.quarantine /Applications/AIUsage.app）
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || VERSION="0.0.${BUILD_NUMBER:-1}"
TEAM_ID="${TEAM_ID:-$(awk -F'"' '/DEVELOPMENT_TEAM:/{print $2; exit}' project.yml)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-aiusage-notary}"

command -v xcodegen >/dev/null || { echo "請先 brew install xcodegen"; exit 1; }

ADHOC="${ADHOC:-0}"
if [[ "$ADHOC" != 1 ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "ℹ Keychain 裡沒有 Developer ID Application 憑證，改用 ad-hoc 簽章（不公證）"
  ADHOC=1
fi

if [[ "$ADHOC" == 1 ]]; then
  IDENTITY="-"
  TEAM_ID=""
  SIGN_FLAGS=""
  DMG="dist/AIUsage-$VERSION-unsigned.dmg"
else
  SIGN_FLAGS="--timestamp"
  DMG="dist/AIUsage-$VERSION.dmg"
fi

echo "▸ v$VERSION  team ${TEAM_ID:-（ad-hoc）}"
rm -rf build dist && mkdir -p dist
xcodegen generate --quiet

echo "▸ Building (universal arm64 + x86_64, Release)…"
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  -quiet build

APP="build/Build/Products/Release/AIUsage.app"

echo "▸ Verifying architectures…"
for bin in "$APP/Contents/MacOS/AIUsage" \
           "$APP/Contents/PlugIns/AIUsageWidget.appex/Contents/MacOS/AIUsageWidget"; do
  archs="$(lipo -archs "$bin")"
  echo "  $(basename "$bin"): $archs"
  for want in arm64 x86_64; do
    grep -qw "$want" <<<"$archs" || { echo "✗ $bin 缺少 $want"; exit 1; }
  done
done

echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
[[ "$ADHOC" == 1 ]] || codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Runtime"

echo "▸ Creating DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI Usage" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "$ADHOC" == 1 ]]; then
  echo "✓ $DMG（ad-hoc，未公證）"
  echo "  使用者安裝後第一次啟動："
  echo "    xattr -dr com.apple.quarantine /Applications/AIUsage.app"
  echo "  或右鍵 → 開啟（macOS 15 要再到 系統設定 → 隱私權與安全性 → 強制打開）"
  exit 0
fi

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
