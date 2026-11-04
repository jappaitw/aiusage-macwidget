# AI Usage — AI 服務用量桌面小工具

原生 macOS WidgetKit 小工具（小／中／大三種尺寸）＋一個常駐選單列的小 app。會**自動偵測**這台 Mac 上已安裝或已登入的 AI 服務，有偵測到才顯示：

| 服務 | 顯示內容 | 資料來源 |
| --- | --- | --- |
| Claude（Claude Code） | 5 小時／每週／每週·模型 | Keychain 裡的 OAuth token → `api.anthropic.com/api/oauth/usage` |
| Codex | 5 小時／每週 | `codex app-server`，或 `~/.codex/sessions` |
| Cursor | 本期用量（含 Auto、API 模型） | Cursor 的 `state.vscdb` → Dashboard API |
| GitHub Copilot | Premium 請求／Chat／補全（月） | `~/.config/github-copilot` → `copilot_internal/user` |
| Gemini CLI | 各模型額度 | `~/.gemini/oauth_creds.json` → Code Assist quota |
| Antigravity | 各模型群組 5 小時／每週 | `~/.gemini/antigravity-cli` → Code Assist quota summary |

ChatGPT 和 Claude 的桌面版沒有對外提供用量資料：ChatGPT 方案的額度只能透過 Codex 看，Claude 方案的額度只能透過 Claude Code 看。要新增其他服務，只需實作 `UsageProvider`，再把它加進 `ProviderRegistry.all`（`App/Providers.swift`）。

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
# 1. project.yml 已設定 DEVELOPMENT_TEAM（KunWei Lin team）；換帳號再改
#    （Xcode → Settings → Accounts；免費 Apple ID 的 Personal Team 也可以）
xcodegen generate
open AIUsage.xcodeproj
```

2. 在 Xcode 選 **AIUsage** scheme → Run。選單列會出現 `C 42%  X 18%`，點開是完整面板
3. 建議把 app 放進 `/Applications`（Product → Archive → Export，或直接從 DerivedData 拷貝出來），widget 會註冊得比較穩定
4. 在桌面按右鍵 →「編輯小工具」→ 搜尋「AI 用量」→ 拖到桌面
5. 在面板勾選「登入時啟動」

點 widget 會叫 app 馬上更新一次（`aiusage://refresh`）。

## 正式安裝（不靠 Xcode 跑）

```bash
./scripts/install.sh
```

這支 script 會用 Release 設定 build，裝到 `/Applications/AIUsage.app` 並啟動。裝好後，在面板上勾「登入時啟動」。之後改了程式碼，`git pull` 完再跑一次這支 script 就會更新。

## 發佈 DMG（universal：所有 Apple Silicon 和 Intel Mac 都能裝）

`scripts/release.sh` 會 build **universal binary（arm64 + x86_64）**，app 和 widget extension 都會用 `lipo` 驗證兩種架構齊全，所以同一個 DMG 在任何 M 系列（M1～M4…）和 Intel 的 Mac 上都能安裝，不需要 Xcode。有兩種模式：

### 模式 A：Developer ID 簽章＋Apple 公證（建議）

需要付費的 Apple Developer Program。產出的 DMG 使用者下載後直接打開就能裝。

**在本機發佈**

```bash
# 只需設定一次：先在 Xcode → Settings → Accounts → Manage Certificates → ＋ 建立 Developer ID Application 憑證
xcrun notarytool store-credentials aiusage-notary --apple-id <你的 Apple ID> --team-id <Team ID>
./scripts/release.sh 1.0.0      # 會產生 dist/AIUsage-1.0.0.dmg
```

**用 GitHub Actions 發佈**：在 repo 設定以下四個 secrets，之後只要 `git tag v1.0.0 && git push --tags`，就會自動 build、簽章、公證，並把 DMG 掛到 GitHub Release。

| Secret | 內容 |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | 匯出的 Developer ID .p12 檔，轉成 base64 |
| `MACOS_CERT_PASSWORD` | .p12 的密碼 |
| `APPLE_ID` | Apple ID email |
| `APPLE_APP_PASSWORD` | 在 appleid.apple.com 建立的 App 專用密碼 |

### 全自動發佈（auto-release workflow）

推送到 `claude/**` 分支且 build 綠燈後，`auto-release` workflow 會自動：開 PR → 合併進 main → 把最新 `v*` tag 的 patch 版號 +1 打新 tag → 觸發 release，把 DMG 掛上 GitHub Release。commit 訊息含 `[no-release]` 時只合併不發版；要停用就刪掉 `.github/workflows/auto-release.yml`。（需要在 repo 的 Actions 設定勾選「Allow GitHub Actions to create and approve pull requests」。）

### 模式 B：Ad-hoc 簽章（免費，不公證）

沒有付費開發者帳號也能發佈。Keychain 裡找不到 Developer ID 憑證時，`release.sh` 會自動退回這個模式（或直接 `ADHOC=1 ./scripts/release.sh 1.0.0` 強制），產出 `dist/AIUsage-<版本>-unsigned.dmg`。GitHub Actions 也一樣：**不設任何 secrets** 直接 `git tag v1.0.0 && git push --tags`，就會發佈 ad-hoc 版的 Release。

因為沒有經過 Apple 公證，使用者把 app 拖進「應用程式」後，第一次啟動前要先解除 Gatekeeper 隔離（擇一）：

```bash
xattr -dr com.apple.quarantine /Applications/AIUsage.app
```

或：右鍵點 app → 開啟（macOS 15 以上會先被擋下來，要再到 系統設定 → 隱私權與安全性 → 捲到最下面按「強制打開」）。macOS 15 以上第一次啟動時，若跳出詢問是否允許存取其他 app 的資料（App Group），選「允許」widget 才讀得到資料。

### 安裝（使用者端）

1. 從 [Releases](../../releases) 下載 DMG → 打開 → 把 **AIUsage** 拖進 **Applications**
2. v1.0.6 起的正式版都經過 Developer ID 簽章＋Apple 公證，下載後直接打開即可；只有檔名帶 `-unsigned` 的舊版才需要照上面的方式解除隔離
3. 桌面右鍵 →「編輯小工具」→ 搜尋「AI 用量」→ 拖到桌面；面板勾「登入時啟動」

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
