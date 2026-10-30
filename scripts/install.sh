#!/bin/zsh
# Release build → 安裝到 /Applications → 啟動
set -euo pipefail
cd "${0:A:h}/.."

command -v xcodegen >/dev/null || { echo "請先 brew install xcodegen"; exit 1; }
xcodegen generate --quiet

echo "▸ Building Release…"
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build \
  -allowProvisioningUpdates -quiet build

APP="build/Build/Products/Release/AIUsage.app"
[[ -d "$APP" ]] || { echo "找不到 $APP，build 失敗？"; exit 1; }

echo "▸ Installing to /Applications…"
pkill -x AIUsage 2>/dev/null || true
sleep 1
rm -rf /Applications/AIUsage.app
cp -R "$APP" /Applications/

# 移除 Xcode debug build 註冊的舊 widget，避免小工具圖庫裡出現兩個
for p in $(pluginkit -mAvvv -p com.apple.widgetkit-extension 2>/dev/null \
           | awk '/com.jlmxstudio.aiusage.widget/{f=1} f&&/Path =/{print $3; f=0}'); do
  [[ "$p" == /Applications/* ]] || pluginkit -r "$p" 2>/dev/null || true
done

open /Applications/AIUsage.app
echo "✓ 完成。到選單列點開面板 → 勾「登入時啟動」；桌面右鍵 → 編輯小工具 → 搜尋「AI 用量」"
