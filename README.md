# AI Usage — Claude / Codex 用量桌面小工具

原生 macOS WidgetKit 小工具（小／中／大三種尺寸）＋一個常駐選單列的小 app。

- **Claude**：5 小時、每週、每週·特定模型（Opus/Sonnet…）的額度百分比和重置倒數；額外用量有開的話也會顯示
- **Codex**：5 小時、每週額度和重置倒數
- **本機 token 統計**：今日／7 天總量、7 天每日長條圖（Claude＋Codex 疊在一起）、各模型用量排行

## 架構

```
AIUsage.app（選單列，非 sandbox）
 ├─ 每 5 分鐘 + 睡眠喚醒時更新
 ├─ Claude 額度：讀 Keychain「Claude Code-credentials」的 OAuth token → GET api.anthropic.com/api/oauth/usage
 ├─ Codex 額度：codex app-server（JSON-RPC account/rateLimits/read）→ 失敗就讀 ~/.codex/sessions 最新的 rate_limits
 ├─ token 統計：掃 ~/.claude/projects/**/*.jsonl、~/.codex/sessions/**/*.jsonl（只在本機算）
 └─ 寫 snapshot.json 到 App Group container → WidgetCenter.reloadAllTimelines()
        ↓
AIUsageWidget.appex（sandbox）只負責讀 snapshot.json 顯示
```

Widget extension 一定要開 sandbox，沒辦法自己讀 `~/.claude`、Keychain 或執行 `codex`，所以實際抓資料的工作都交給 host app 做。

## 建置

需求：macOS 14 以上、Xcode 15 以上，Claude Code 和 Codex CLI 都至少登入過一次。

```bash
brew install xcodegen
cd AIUsage
# 1. 把 project.yml 裡的 DEVELOPMENT_TEAM 改成你的 Team ID
#    （Xcode → Settings → Accounts；免費 Apple ID 的 Personal Team 也可以）
xcodegen generate
open AIUsage.xcodeproj
```

2. 在 Xcode 選 **AIUsage** scheme → Run。選單列會出現 `C 42%  X 18%`，點開是完整面板
3. 建議把 app 放進 `/Applications`（Product → Archive → Export，或直接從 DerivedData 拷貝出來），widget 會註冊得比較穩定
4. 在桌面按右鍵 →「編輯小工具」→ 搜尋「AI 用量」→ 拖到桌面
5. 在面板勾選「登入時啟動」

點 widget 會叫 app 馬上更新一次（`aiusage://refresh`）。

## 你可能會碰到的狀況

- **Keychain 授權視窗**：app 會先用 `/usr/bin/security` 讀 token，通常不會跳視窗；如果跳了，選「永遠允許」
- **「Claude token 過期」**：app 刻意**不**幫你 refresh token，因為 Anthropic 會輪替 refresh token，這裡一 refresh，Claude Code 手上那份就會失效而被登出。只要開一下 Claude Code，token 就會自動更新。在這段期間，widget 會繼續顯示上一次抓到的數字
- **Codex 數字比較舊**：沒抓到 `codex` 執行檔，或 app-server 沒回應時，會改用 session log。這時的數字只會跟你最後一次用 Codex 時一樣新，面板會寫出資料取得的時間。另外，log 裡已經過了重置時間的視窗會直接顯示 0%
- **Widget 沒有馬上更新**：WidgetKit 對背景 reload 有每日額度，所以 app 只在百分比變動時才 reload，另外最多每 30 分鐘強制 reload 一次。重置倒數用的是系統的相對時間，會自己跳，不用 reload
- 這兩支額度 API 都**沒有公開文件**（就是 Claude Code `/usage` 和 Codex `/status` 用的那兩支），改版時會在面板上顯示「回應格式看不懂」。要修的話，看 `ClaudeUsageFetcher.parse` 和 `CodexUsageFetcher.parseAppServer`

## 檔案

| 檔案 | 用途 |
| --- | --- |
| `project.yml` | XcodeGen 設定（兩個 target、App Group、entitlements） |
| `Shared/Models.swift` | 資料模型、格式化、日期解析 |
| `Shared/SharedStore.swift` | App Group 裡 snapshot.json 的讀寫 |
| `Shared/UsageViews.swift` | widget 和面板共用的 SwiftUI 元件（進度條、欄位、Charts 長條圖） |
| `App/ClaudeUsageFetcher.swift` | Claude token 讀取 + usage API |
| `App/CodexUsageFetcher.swift` | codex app-server JSON-RPC + log 的 rate_limits 解析 |
| `App/LocalTokenScanner.swift` | 掃本機 jsonl 算每日／各模型 token（有快取，沒變的檔案不重讀） |
| `App/UsageModel.swift` | 定時更新、合併結果、控制 widget reload |
| `App/AIUsageApp.swift` | 選單列 app 和面板 |
| `Widget/AIUsageWidget.swift` | WidgetKit timeline 和三種尺寸 |
