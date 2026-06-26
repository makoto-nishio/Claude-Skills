# Kintone チケットリマインダー

Kintone アプリの未対応チケット（障害 / ご質問・調査依頼など）を毎日（または指定間隔で）自動取得し、Slack チャンネルへリマインダーを送信する Claude Code skill です。

トラッカー別・担当者別にまとめ、担当者には Slack メンションを付けて通知します。

Windows Task Scheduler から PowerShell スクリプト経由で Claude Code CLI を起動し、skill を実行します。

> **業務ロジックは `SKILL.md`（日本語の手順書）に書かれています。** コードの改修なしに `config.yaml` を書き換えるだけで、対象アプリ・トラッカー・担当者・スケジュールを変更できます。

## 概要

| 項目 | 値 |
|------|-----|
| 対象アプリ | 問い合わせ管理（App ID: 18 = `config.yaml` の `kintone.app_id`） |
| 対象トラッカー | 障害、ご質問・調査依頼（`config.yaml` の `trackers`） |
| 対象ステータス | 新規、受付済み、対応検討中、対応中、進行中、再検討依頼（`config.yaml` の `statuses`） |
| 対象担当者 | `config.yaml` の `assignees`（会社 email の配列。Slack User ID は実行時に解決） |
| 実行方式 | Windows Task Scheduler + Claude Code CLI |
| 認証 | Kintone: MCP server が APIトークン方式（`KINTONE_BASE_URL`+`KINTONE_API_TOKEN`）または ID/パスワード方式（`KINTONE_USERNAME`+`KINTONE_PASSWORD`）を使用 / Slack: MCP コネクター（claude.ai 等で認証済み） |

> ステータスから「お客様の回答待ち」は除外しています（`config.yaml` でコメントアウト）。対象を変えたい場合は `statuses` を編集してください。

## 30 秒で全体像

1. Kintone の認証情報を環境変数に設定する（APIトークン方式 または ID/パスワード方式）
2. `config.yaml` に「対象アプリ / 投稿先チャンネル / 担当者 / スケジュール」を書く
3. `scripts\deploy-task.ps1` を 1 回実行 → Windows Task Scheduler にタスク登録
4. 以降は指定スケジュールで全自動

---

## ディレクトリ構成

```
kintone-unfinished-reminder/
├── README.md              # 本ファイル（運用ガイド）
├── SKILL.md               # Claude Code 用の skill 定義（業務ロジック）
├── CLAUDE.md              # 編集者向けガイド（不変条件・落とし穴）
├── config.yaml            # 対象アプリ・トラッカー・担当者・スケジュール設定
├── reference/
│   └── notification-format.md  # Slack 通知の書式の正本
├── scripts/               # 自動化スクリプト
│   ├── run-reminder.ps1   # Task Scheduler から呼ばれる実行スクリプト
│   ├── deploy-task.ps1    # Task Scheduler にタスクを登録（冪等）
│   ├── uninstall-task.ps1 # 登録済みタスクを削除
│   └── launcher.vbs       # 黒窓フラッシュ抑止用の wscript ラッパ
└── logs/                  # 実行ログ（実行時に自動生成）
    ├── last_run.log       # 実行開始 / 終了の記録
    ├── last_error.log     # エラー詳細
    └── last_output.log    # claude.exe の全出力（デバッグ用）
```

> **通知の送信方式について**: この skill は専用の Slack App を持ちません。通知は、実行 PC で認証済みの **Slack MCP コネクターの本人アカウント**から送信されます（「設定した人の名前」で投稿されます）。発信元を変えたい場合は MCP コネクター側の再認証が必要です。

---

## 前提条件

| 項目 | 内容 |
|------|------|
| OS | Windows 10 / 11 |
| PowerShell | Windows PowerShell 5.1（標準搭載）または PowerShell 7+ |
| Claude Code CLI | `claude` コマンドが PATH 上にあること（`Get-Command claude` で確認） |
| Kintone MCP | `@kintone/mcp-server` を導入し、認証情報（APIトークン方式 または ID/パスワード方式）を設定済み（導入手順は社内ガイド: [APIトークン方式](https://medley-inc.atlassian.net/wiki/spaces/~918941202/pages/1813257902/Kintone+MCP+Windows) / [ID・パスワード方式](https://medley-inc.atlassian.net/wiki/spaces/~187159273/pages/1832193986/kintone+MCP)） |
| Slack MCP | Slack コネクター（MCP）を認証済み |
| 動作タイミング | PC がログオン中の時間帯にしかタスクは走らない |

> ⚠️ **横展開で最初に詰まるポイント: MCP の名前空間**
> Kintone / Slack MCP ツールの名前空間は環境によって異なります（例: Slack は `mcp__plugin_slack_slack__*` と `mcp__claude_ai_Slack__*`）。**無人実行で使われる名前空間が `run-reminder.ps1` の `--allowedTools` に入っていないと、全 API 呼び出しが「権限未付与」で拒否され、何も実行できないまま正常終了します。**
> 接続中の MCP サーバ名を確認するには:
> ```powershell
> claude mcp list
> ```
> `✔ Connected` のサーバ名が `run-reminder.ps1` の許可リストに含まれているか確認してください。詳細は[トラブルシューティング](#mcp-の権限拒否で何も実行されないが-done-になる横展開で頻出)を参照。

---

## 初期セットアップ

### 1. 環境変数の設定（Kintone 接続情報）

Kintone MCP server が読み込む環境変数を設定します。認証方式は 2 種類あり、**どちらか一方**を設定すれば動きます（導入手順は各方式の社内ガイド参照）。

**方式1: APIトークン方式**（社内ガイド [Kintone MCP（Windows）](https://medley-inc.atlassian.net/wiki/spaces/~918941202/pages/1813257902/Kintone+MCP+Windows)）

```powershell
# ユーザー環境変数として設定（永続化、推奨）
[System.Environment]::SetEnvironmentVariable('KINTONE_BASE_URL',  'https://pmed.cybozu.com', 'User')
[System.Environment]::SetEnvironmentVariable('KINTONE_API_TOKEN', 'YOUR_TOKEN_HERE',         'User')
```

**方式2: ID/パスワード方式**（社内ガイド [kintone MCP（.mcp.json 方式）](https://medley-inc.atlassian.net/wiki/spaces/~187159273/pages/1832193986/kintone+MCP)）

`KINTONE_USERNAME` / `KINTONE_PASSWORD` を環境変数に設定し、接続先 URL はガイドどおり `.mcp.json` で指定します。この方式では `KINTONE_BASE_URL` が OS 環境変数に無いことがあるため、**チケット URL 用に `config.yaml` の `kintone.domain` を設定**してください。

> チケット URL の base は `config.yaml` の `kintone.domain` を優先し、未設定時のみ `KINTONE_BASE_URL` にフォールバックします（**いずれも末尾スラッシュは自動除去**）。APIトークン方式で `domain` を省く場合、`KINTONE_BASE_URL` は末尾スラッシュ・`/k/` 付き等でも skill 側で除去しますが、MCP 接続用としては末尾スラッシュなしが無難です。

**重要**: 環境変数設定後は PowerShell（および Task Scheduler を起動するセッション）を再起動してください。

### 2. `config.yaml` を編集

認証情報は環境変数に任せます。config の `kintone` セクションは `app_id`（必須）と、チケット URL 用の `domain`（任意。未設定なら `KINTONE_BASE_URL` にフォールバック）です。

```yaml
kintone:
  app_id: 18                     # get-records の app 引数（環境変数に無いためここで指定）
  domain: "https://pmed.cybozu.com"  # チケットURL用ベース（任意・末尾スラッシュ無し。未設定なら KINTONE_BASE_URL）

slack:
  channel_id: "C0XXXXXXX"      # 投稿先チャンネル ID

assignees:                      # 対象担当者の会社 email（Slack User ID は実行時に解決）
  - makoto.nishio@medley.jp
  - kenichi.sawamatsu@medley.jp
  # 他の担当者も同様に

trackers:
  - 障害
  - ご質問・調査依頼

statuses:
  - 新規
  - 受付済み
  - 対応検討中
  - 対応中
  - 進行中
  - 再検討依頼
```

| 必要な情報 | 調べ方 |
|-----------|--------|
| Slack Channel ID | チャンネル名を右クリック → 「リンクをコピー」→ URL 末尾の `C0XXXXXXX` |
| 担当者 email | 会社の email をそのまま記載。Slack User ID は実行時に `slack_search_users` で自動解決（手で調べる必要なし） |

### 3. スケジュールモードを選ぶ

`config.yaml` の `schedule` セクションで `daily` または `interval` の**どちらか一方だけ**を有効化します（使わない方は行頭に `#`）。両方有効だとデプロイ時にエラーになります。

| モード | 用途 | 例 |
|-------|------|-----|
| `daily.time` + `weekdays_only: true` | 毎営業日の固定時刻 | 平日 09:00 |
| `daily.time` + `weekdays_only: false` | 毎日固定時刻 | 毎日 09:00 |
| `interval.minutes: 30` | N 分ごと（短間隔・テスト向け） | 30 分ごと |
| `interval.hours: 1` | N 時間ごと | 毎時 |
| `interval` + `between` | 一日の時間帯内で N 時間/分ごと | 09:00-18:00 で毎時 |

> `interval` で `minutes` と `hours` を両方書いた場合は **`minutes` が優先**されます。

---

## デプロイ（Task Scheduler に登録）

```powershell
cd $HOME\.claude\skills\kintone-unfinished-reminder\scripts
.\deploy-task.ps1
```

`config.yaml` のスケジュールを変更したあとは、**同じコマンドをもう一度実行**するだけで上書き更新されます（冪等）。スクリプト本体は変更不要です。

### デプロイ時に作られるタスクの仕様

| 項目 | 値 |
|------|-----|
| タスク名 | `Claude-Kintone-Reminder` |
| 実行ユーザー | 現在のユーザー（対話モード、ログオン中のみ） |
| Action | `wscript.exe "...\scripts\launcher.vbs"`（黒窓抑止） |
| バッテリー駆動時 | 実行可能 |
| 起動を逃した場合 | 復帰後に補完実行 |
| 実行タイムアウト | 30 分 |
| 多重起動 | しない（先発が走行中なら新起動はスキップ） |

---

## 動作確認

### 手動でいますぐ実行

```powershell
Start-ScheduledTask -TaskName Claude-Kintone-Reminder
```

実行は隠しウィンドウで走るため、画面には何も表示されません。完了は `logs/` で確認します。

skill 単体を対話的にテストしたい場合は、CLI で skill を直接呼び出すこともできます:

```powershell
claude "/kintone-unfinished-reminder"
```

### 次回実行予定・最終結果の確認

```powershell
Get-ScheduledTask -TaskName Claude-Kintone-Reminder | Get-ScheduledTaskInfo
Get-ScheduledTaskInfo -TaskName Claude-Kintone-Reminder | Select-Object LastRunTime, LastTaskResult
```

### ログを見る

| ファイル | 中身 |
|---------|------|
| `logs\last_run.log` | `start` / `done` / `failed` の記録 |
| `logs\last_error.log` | エラーの内容（成功時は作成されない） |
| `logs\last_output.log` | claude.exe の出力全文（デバッグ用） |

```powershell
Get-Content $HOME\.claude\skills\kintone-unfinished-reminder\logs\last_run.log -Tail 50
Get-Content $HOME\.claude\skills\kintone-unfinished-reminder\logs\last_output.log -Encoding utf8 -Tail 50
```

---

## Slack 投稿フォーマット

2 段構成です。**親投稿**（催促トーン＋件数サマリ）＋ その**子スレッド返信**（トラッカー別→担当者別の明細）。

### 親投稿（未対応が1件以上）

```markdown
:rotating_light: *未対応チケットが溜まっています。対応 / ステータス更新をお願いします* 🙏

合計 42件（障害 2 / ご質問・調査依頼 40）

担当者別の未対応数:
<@U03N96QEZ> 10件
<@U03CB6Z46> 5件
<@U07NQCG2W31> 3件
<@U03C9BCE7> 24件
```

- 「担当者別の未対応数」は**通常テキスト行**の `<@User ID> 件数`（通常行なのでメンションが展開され `@makoto.nishio 10件` と表示される）。未対応が1件以上ある担当者だけを `assignees` の順で並べます。

**0 件の場合**（メンションも催促もしない。子スレッドも送らない）:

```markdown
本日の未対応チケット: 0件 🎉
```

### 子スレッド（トラッカー別 → 担当者別）

トラッカー見出しだけ `##` を使い、**担当者見出しは通常テキスト行**の `<@User ID> (件数)` にします。各チケットはタイトル自体がリンクになります（生 URL は出しません）。

> ⚠️ 担当者見出しを `###` などの**見出し行にしてはいけません**。Slack は見出し行ではメンション `<@U…>` を展開せず、生の `<@U03N96QEZ>` がそのまま表示されてしまいます。

```markdown
## 障害 (2件)

<@U03N96QEZ> (1件)
- <https://pmed.cybozu.com/k/18/show#record=158480|[#158480] リハビリシステムが異常終了>

## ご質問・調査依頼 (3件)

<@U03CB6Z46> (2件)
...
```

Slack 上では `[#158480] リハビリシステムが異常終了` がクリック可能なリンクとして表示されます。

詳細な分類ルール・書式の正本は [`reference/notification-format.md`](reference/notification-format.md) を参照してください。

---

## スケジュール変更

1. `config.yaml` の `schedule` セクションを編集
2. `scripts\deploy-task.ps1` を再実行

---

## 削除（タスク解除）

```powershell
cd $HOME\.claude\skills\kintone-unfinished-reminder\scripts
.\uninstall-task.ps1
```

タスクが削除されるだけで、skill ファイル本体や `logs/` は残ります。

---

## トラブルシューティング

### MCP の権限拒否で何も実行されないが done になる（横展開で頻出）
- **症状**: `last_run.log` は `done`（または `failed (no-op suspected)`）、`LastTaskResult` は `0` なのに、通知が一切来ない。`last_output.log` に「権限未付与」「実行権限が付与されておらず」などの記述がある
- **原因**: 無人実行（`claude --print`）で使われる Kintone / Slack MCP の名前空間が、`run-reminder.ps1` の `--allowedTools` に含まれていない。許可外のツールは権限プロンプトになり、無人モードでは自動的に拒否される
- **確認**: `claude mcp list` を実行し、`✔ Connected` の Kintone / Slack サーバ名を確認する
- **対処**: `scripts\run-reminder.ps1` の `$allowedTools` に、その名前空間のツール（`mcp__kintone__kintone-get-records` / Slack の `slack_send_message`・`slack_search_users` など）が含まれているか確認し、無ければ追記する。**本リポジトリは Slack の `mcp__plugin_slack_slack__*` と `mcp__claude_ai_Slack__*` を両方既定で許可済み**
- **補足**: この skill には「no-op 検知」が入っており、上記キーワードを出力に検出すると exit 0 でも `failed (no-op suspected)` として記録します

### 「実行されたはずなのに通知が来ない」
1. `logs\last_run.log` の最終行を確認
   - `done` で終わっていれば、未対応 0 件で詳細スレッドが省略されただけ（親投稿は送信される）
   - `failed (no-op suspected)` なら、上記「MCP の権限拒否」を参照
   - `failed (exit ...)` なら `last_error.log` と `last_output.log` を確認
2. `logs\last_output.log` を開いて claude.exe の最終応答を確認

### よくあるエラー

| エラー | 原因 | 対処 |
|--------|------|------|
| `No kintone credentials ... not set` | 認証情報が未設定（トークンも、ユーザー名+パスワードも無い） | `echo $env:KINTONE_API_TOKEN` / `echo $env:KINTONE_USERNAME` で確認。設定後に PowerShell を再起動 |
| `401 Unauthorized` | トークンの値が誤り | トークンを再確認（コピペミス） |
| `ENOTFOUND` / `getaddrinfo` | `KINTONE_BASE_URL` の綴り・末尾スラッシュ・余分なパス | 末尾スラッシュなしの正しい URL に修正 |
| MCP の認証切れ | Slack MCP が未認証 | コネクターを再認証 |
| `channel_not_found` | チャンネル ID が不正 | `config.yaml` の `slack.channel_id` を確認 |
| `claude command not found` | Claude Code CLI が未インストール / PATH 外 | インストール後、`Get-Command claude` で確認 |

### `.ps1` ファイルを編集したら動かなくなった
- 編集ツールが UTF-8 BOM を削った可能性あり。下記コマンドで BOM を付け直してください:
  ```powershell
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  Get-ChildItem .\scripts -Filter *.ps1 | ForEach-Object {
      $c = [System.IO.File]::ReadAllText($_.FullName)
      [System.IO.File]::WriteAllText($_.FullName, $c, $utf8Bom)
  }
  ```
- `2147942401` (= `0x80070001`) は典型的に **PowerShell が `.ps1` をパースできなかった**兆候（BOM が外れているケースが多い）

### PC がログオフ / 休止中だった
- 本タスクは「ユーザーがログオンしているときのみ実行」なので、ログオフ中は走りません
- スリープから復帰した場合は `StartWhenAvailable` 設定により次回起動可能なタイミングで補完実行されます

---

## 参考情報

- Kintone REST API: https://cybozu.dev/ja/kintone/docs/rest-api/
- Claude Code CLI: https://docs.anthropic.com/claude/docs/claude-code
