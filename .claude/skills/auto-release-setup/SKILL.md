---
name: auto-release-setup
description: 在目前專案建立全自動發佈流程（推分支 → CI 綠燈 → 自動開 PR → 自動合併進 main → 版號 patch +1 打 tag → 自動發 GitHub Release）。macOS app 專案另含 universal（arm64 + x86_64）DMG 的建置與簽章。當使用者要求設定「自動發佈」「auto release」「自動 PR/merge」「推完自動出新版」時使用。
---

# 自動發佈流程 SOP

目標：開發者（或 Claude）推程式碼到工作分支後，不需要任何手動步驟，
幾分鐘內新版本就出現在 GitHub Releases。

```
push 到 claude/** 分支 → build workflow 綠燈
  → auto-release workflow：開 PR → merge 進 main
  → 讀最新 v* tag、patch +1、打在 main 的新 HEAD 上
  → 明確 dispatch release workflow（GITHUB_TOKEN 推的 tag 不會自動觸發）
  → release workflow 建置產物、掛上 GitHub Release
```

## 步驟 1：確認有名為 `build` 的 CI workflow

必要條件：`on: [push]`、build 失敗時 job 要是紅的（這是自動合併唯一的守門員）。
沒有的話先建一個最小的編譯／測試 workflow，名稱取 `build`（auto-release 用名字對應）。

## 步驟 2：建立 release workflow

需求：`on: push: tags: ['v*']` 加上 `workflow_dispatch`（dispatch 在 tag ref 上執行時
`GITHUB_REF_NAME` 就是 tag 名，拿來當版號）。發佈步驟要能處理「release 已存在」
（先 `gh release view` 判斷，存在就 `gh release upload --clobber`，不存在才 `gh release create`），
因為使用者也可能從網頁 Draft a new release 先建了同名 release。

macOS app 專案另外注意（完整參考實作：`jappaitw/aiusage-macwidget` 的
`scripts/release.sh` 和 `.github/workflows/release.yml`）：

- xcodebuild 加 `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`，build 完對 app 本體和
  每個 appex 跑 `lipo -archs` 驗證兩種架構都在，缺了就 fail
- 沒有 Developer ID 憑證時退回 ad-hoc 簽章（`CODE_SIGN_IDENTITY="-"`、`DEVELOPMENT_TEAM=""`、
  拿掉 `--timestamp`、跳過公證），DMG 檔名加 `-unsigned` 後綴
- ad-hoc 簽章下 App Group 授權無效，sandbox 的 widget/extension 讀不到 group container：
  host app 要多寫一份資料到 `~/Library/Application Support/<App>/`，extension 的 entitlements
  加 `com.apple.security.temporary-exception.files.home-relative-path.read-only` 指向該資料夾
- 公證版需要 repo secrets：`MACOS_CERT_P12_BASE64`、`MACOS_CERT_PASSWORD`、`APPLE_ID`、
  `APPLE_APP_PASSWORD`；workflow 用「secret 存在與否」決定走哪條（注意 `secrets` 不能直接
  寫在 step 的 `if:`，要先放進 job 層級的 `env` 再判斷）

## 步驟 3：建立 `.github/workflows/auto-release.yml`

照抄以下範本（視專案調整 `claude/` 分支前綴和 `build` workflow 名稱）：

```yaml
name: auto-release
on:
  workflow_run:
    workflows: [build]
    types: [completed]

permissions:
  contents: write
  pull-requests: write
  actions: write

jobs:
  merge-and-release:
    if: >
      github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.event == 'push' &&
      startsWith(github.event.workflow_run.head_branch, 'claude/')
    runs-on: ubuntu-latest
    env:
      GH_TOKEN: ${{ github.token }}
      BRANCH: ${{ github.event.workflow_run.head_branch }}
      SHA: ${{ github.event.workflow_run.head_sha }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Create PR if missing
        run: |
          PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
          if [ -z "$PR" ]; then
            gh pr create --head "$BRANCH" --base main \
              --title "$(git log -1 --format=%s "$SHA")" \
              --body "由 auto-release workflow 自動建立：build 綠燈後自動合併並發佈新版。"
            PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number')
          fi
          echo "PR=$PR" >> "$GITHUB_ENV"

      - name: Merge PR
        run: |
          HEAD=$(git rev-parse "origin/$BRANCH")
          if [ "$HEAD" != "$SHA" ]; then
            echo "::notice::分支已有更新的 commit，等最新 build 的結果"
            echo "SKIP=1" >> "$GITHUB_ENV"
            exit 0
          fi
          gh pr merge "$PR" --merge

      - name: Tag next version and trigger release
        if: env.SKIP != '1'
        run: |
          if git log -1 --format=%B "$SHA" | grep -q '\[no-release\]'; then
            echo "::notice::[no-release]，只合併不發版"
            exit 0
          fi
          git fetch origin main --tags
          LATEST=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
          LATEST=${LATEST:-v1.0.0}
          IFS=. read -r MA MI PA <<<"${LATEST#v}"
          NEXT="v$MA.$MI.$((PA+1))"
          git tag "$NEXT" "$(git rev-parse origin/main)"
          git push origin "$NEXT"
          gh workflow run release.yml --ref "$NEXT"
```

## 步驟 4：請使用者做兩件一次性設定

1. repo Settings → Actions → General → Workflow permissions →
   勾選「Allow GitHub Actions to create and approve pull requests」→ Save
   （沒勾的話自動開 PR 會被拒絕）
2. 手動合併「加入這些 workflow」的那個 PR（`workflow_run` 觸發的 workflow
   必須存在於 default branch 才會生效）

## 步驟 5：實測整條鏈

推一個小 commit（例如 README 更新）到 `claude/**` 分支，然後依序確認：
build 綠燈 → auto-release run 成功 → 新 tag 出現 → release workflow 成功 →
Release 頁面有產物。用 API 輪詢，不要只看有沒有錯誤訊息。

## 注意事項

- 自動合併唯一的守門員是 build workflow，merge 前務必讓它涵蓋編譯／測試
- 每個綠燈 push 都會發一版；commit 訊息加 `[no-release]` 可只合併不發版
- 要暫停整個自動化：刪掉 `auto-release.yml`
- GITHUB_TOKEN 推 tag／merge 不會觸發其他 workflow（GitHub 防遞迴），
  所以 release 一定要用 `gh workflow run` 明確 dispatch
- 版號規則是「最新 v* tag 的 patch +1」；要跳 minor/major 就手動打一個
  （例如 `v1.1.0`）再讓自動化從那裡續跳
