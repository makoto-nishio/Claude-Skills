---
name: kintone-unfinished-reminder
description: Use when asked to remind a team about unfinished/未対応 Kintone tickets (障害・ご質問・調査依頼 など) by posting a Slack reminder. Fetches records by tracker/status/assignee from Kintone and posts a parent message + per-tracker threads. One-shot check; scheduling is handled separately by Windows Task Scheduler, not this skill.
---

# Kintone チケットリマインダー

## 概要

**Kintoneアプリから特定条件の未対応チケットを取得し、Slackにリマインダーを投稿する**。一回の実行で「Kintone APIからチケット取得 → トラッカー・担当者別に分類 → Slack投稿（親投稿+スレッド）」を行う。実行のタイミング（毎日何時に動かすか）は本スキルの責務外で、Windows Task Schedulerで別途設定する。

## 使用タイミング

**以下の場合に使用**:
- Kintoneの未対応チケットをSlackに通知したい
- チーム全員へ未対応チケットのリマインダーを送信したい
- 一回限りのチケット確認を実行したい

**以下の場合は使わない**:
- 単発の手動確認のみ（Kintone画面で十分）
- 外部ツールで既に監視済み

## 設定（`config.yaml`）

設定値はすべて同じディレクトリの `config.yaml` から読み込む。スキル本体には設定を直書きしない。**skill 実行時に Claude が使うのは以下のキーのみ**:

| キー | 型 | 説明 |
|------|------|------|
| `kintone.app_id` | 整数 | 対象アプリID（例: 18）。`get-records` の `app` 引数に使う |
| `kintone.domain` | 文字列（任意） | チケットURL組み立て用のベースURL（末尾スラッシュ無し）。未設定なら環境変数 `KINTONE_BASE_URL` にフォールバック |
| `slack.channel_id` | 文字列 | 投稿先チャンネルID（例: C0XXXXXXX） |
| `assignees` | 配列 | 対象担当者の **email 配列**。Kintone の担当者照合キー兼、実行時に `slack_search_users` で Slack User ID へ解決してメンションに使う |
| `trackers` | 文字列の配列 | 対象トラッカー（例: ["障害", "ご質問・調査依頼"]） |
| `statuses` | 文字列の配列 | 対象ステータス（例: ["新規", "受付済み", ...]） |

> `schedule.*` は **deploy-task.ps1 が読む**キーで Claude は使わない。スキーマ・使い方は README.md / CLAUDE.md を参照。

**重要**: Kintone の**認証情報**は config に書かない。MCP server (`@kintone/mcp-server`) が環境変数から自動で読み込む。対応する認証方式は 2 種類（どちらか一方が揃っていればよい）:
- **APIトークン方式**: `KINTONE_BASE_URL`（例: `https://pmed.cybozu.com`）+ `KINTONE_API_TOKEN`（「問い合わせ管理」app の参照用トークン）
- **ID/パスワード方式**: `KINTONE_USERNAME` + `KINTONE_PASSWORD`（接続先 URL は `.mcp.json` 等で指定。OS 環境変数の `KINTONE_BASE_URL` は無いことがある）

**チケット URL の組み立て**には config の `kintone.domain` を優先して使い、未設定なら環境変数 `KINTONE_BASE_URL` にフォールバックする（どちらの認証方式でも URL を作れるようにするため）。

`get-records` の `app` 引数だけは環境変数に無いため、`config.yaml` の `kintone.app_id` で指定する。

**発信元**: 通知は `slack.channel_id`（=送信先）に送るが、**送信者は Slack MCP のログイン身分**（OAuth トークン所有者）。config では変えられない。

## 無人実行モード（前提）

このスキルは自動実行（Windows Task Scheduler等）が前提。**AIはいかなる場面でもユーザーに質問してはならない**。

- `AskUserQuestion` ツールは使用禁止
- OAuth再認証フロー（Slack MCP）には入らない
- 設定の曖昧さ・選択肢の判断 → 既定動作で進む（処理対象0件なら通常exit）
- 想定外のエラー → 「失敗時の通知」を実行して即exit
- 「ユーザーに確認したい」と感じた場面は、すべて即exit扱い

## 実行ワークフロー

### 0. ヘルスチェック（最優先・無人実行向け）

主要API呼び出し前に軽量な検証を行う：

1. **Slack MCP接続確認**: `slack_search_users` で `assignees` の先頭 email を1件解決してみる
   - 失敗時（Slack MCP未接続、認証期限切れ、ネットワーク不通など）:
     - **OAuth再認証フローには絶対に入らない**（無人実行では人がブラウザを開けないため意味がない）
     - 「失敗時の通知」セクションのPowerShellを実行
     - 通知後すぐにexit。後続のステップは一切実行しない

2. **認証情報の確認**: Kintone の認証情報が 2 方式のどちらかで揃っているか確認（Bash で `echo` する）:
   - **APIトークン方式**: `KINTONE_API_TOKEN` がある（接続には `KINTONE_BASE_URL` も必要）
   - **ID/パスワード方式**: `KINTONE_USERNAME` と `KINTONE_PASSWORD` の両方がある
   - **どちらの方式も成立しない**（トークンも無く、ユーザー名／パスワードも揃わない）場合のみ「失敗時の通知」を実行してexit
   - 注: 認証情報が実際に有効かは MCP 接続でしか分からない。ここでは「設定が存在するか」だけを見て、最終判断はステップ2の `get-records` の成否で行う

### 1. 設定の読み込み

`./config.yaml` を読み、各キーの値を取得する。

### 2. Kintoneからチケット取得

各トラッカーについて並列に `mcp__kintone__kintone-get-records` を呼び出す：

```javascript
// 障害チケット取得
mcp__kintone__kintone-get-records({
  app: "18",
  filters: {
    inValues: [
      { field: "ドロップダウン_0", values: ["障害"] },
      { field: "Person", values: assigneeEmails },
      { field: "StatusCode", values: statuses }
    ]
  },
  fields: ["$id", "文字列__1行__1", "Person", "StatusCode"],
  orderBy: [{ field: "更新日時", order: "desc" }],
  limit: 500
})
```

**重要なフィールド名**:
- トラッカー: `ドロップダウン_0`
- 題名: `文字列__1行__1`
- 担当者: `Person`
- ステータス: `StatusCode`

**チケットURL生成**: base URL は config の `kintone.domain` を優先して使う。未設定なら環境変数 `KINTONE_BASE_URL` にフォールバック（Bash で `echo "$KINTONE_BASE_URL"`）。**末尾スラッシュは必ず除去**してから組み立てる。
```
{base}/k/{app_id}/show#record={$id}
（base = config の kintone.domain、無ければ env の KINTONE_BASE_URL）
例: https://pmed.cybozu.com/k/18/show#record=12345
```

### 3. チケットの分類

取得したチケットを以下の順で分類:
1. トラッカー種別（障害、ご質問・調査依頼）
2. 担当者別（各assigneeのメールアドレスで）

**担当者分類ルール**:
- チケットの`Person`フィールドには1名以上の担当者が含まれる（配列）
- **1名のみ担当**: その担当者のセクションに分類
- **複数名担当**: 以下の優先順位で分類
  1. `assignees`リストに含まれる担当者が1名のみ → その担当者のセクションに分類
  2. `assignees`リストに含まれる担当者が複数 → 最初に見つかった担当者のセクションに分類
  3. `assignees`リストに含まれる担当者が0名 → 「その他」セクションに分類

**重要**: `assignees`リストに含まれない担当者（有田さん、福田さんなど）が共同担当でも、`assignees`リストの担当者がいれば、その担当者のセクションに分類する。

### 4. Slack投稿

#### 事前: 担当者 email → Slack User ID 解決
親投稿のメンションと子スレッドの担当者見出しのため、`assignees` の各 email を `slack_search_users` で Slack User ID に解決する（profile email の完全一致 1 件のみ採用。0件・複数件は解決失敗）。**解決できない email はメンションせず、config コメントの名字テキストで表示**してチケットを取りこぼさない。

**書式の正本は `reference/notification-format.md`。** 本文を組み立てる前に必ず読み、その書式に従う。要点だけ先に示すと: 2段構成（親投稿=全員メンション＋トラッカー別件数サマリ／子スレッド=`## トラッカー` の下に `### <@担当者slack_id> (件数)` でグルーピング）。**担当者見出しは表示名ではなく Slack メンション**（解決した User ID。解決失敗時は名字テキスト）。各チケットは **Slack のリンク記法 `- <{URL}|[#番号] 題名>` で1行**にし、タイトル自体をリンクにする（**生 URL は本文に出さない**）。

実装:
1. **親投稿**: `slack_send_message` で `slack.channel_id` に投稿し、`message_ts` を取得
2. **子スレッド**: `slack_send_message` に `thread_ts` で親投稿の `message_ts` を指定。0件のトラッカーは投稿しない

### 5. 実行完了

ログに成功を記録してexit。

## エラーハンドリング

| エラー種別 | 対処 |
|------------|------|
| **認証情報なし** | APIトークン（`KINTONE_API_TOKEN`）も、ID/パスワード（`KINTONE_USERNAME`+`KINTONE_PASSWORD`）も揃わない → 失敗時の通知を実行してexit |
| **Slack MCP未接続** | `slack_search_users` 失敗 → 失敗時の通知を実行してexit |
| **Kintone API失敗** | レート制限、認証エラー等 → 失敗時の通知を実行してexit |
| **チャンネルID不正** | `slack_send_message` で `channel_not_found` → 失敗時の通知を実行してexit |
| **設定ファイル読み込み失敗** | config.yamlが存在しない、形式不正 → 失敗時の通知を実行してexit |

**重要**: OAuth再認証フローには絶対に入らない。認証切れは「失敗」として扱う。

## 失敗時の通知（Windows）

Kintone API失敗やSlack MCP認証切れの際は、`logs/last_error.log` にエントリを追記する。**Slack通知に依存しない**ので、Slack自体が落ちていても後から原因を追える。

実装例（Bashツールから実行するPowerShell）:

```powershell
$logDir = "$env:USERPROFILE\.claude\skills\kintone-unfinished-reminder\logs"
$logPath = "$logDir\last_error.log"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Kintone reminder failed: <error reason here>" | Out-File -FilePath $logPath -Append -Encoding utf8
```

| 項目 | 内容 |
|------|------|
| ログファイル | `%USERPROFILE%\.claude\skills\kintone-unfinished-reminder\logs\last_error.log` |
| 依存 | Windows標準のみ（追加モジュール不要） |
| 確認方法 | 定期的にログファイルを確認する。連日エントリが追加されていれば再認証が必要 |

## スケジューリングについて

本スキル自体は「呼び出されたら一回実行する」ためのもの。定期実行は **Windows Task Scheduler + PowerShell** で行う。

### ディレクトリ構成

```
kintone-unfinished-reminder/
├── SKILL.md               # 本ファイル（スキル定義 = 業務ロジック）
├── README.md              # 運用ガイド（セットアップ・スケジュール・トラブルシューティング）
├── CLAUDE.md              # 編集者向けガイド（不変条件・落とし穴）
├── config.yaml            # 設定
├── reference/
│   └── notification-format.md  # Slack 通知の書式の正本
├── scripts/               # 自動化スクリプト
│   ├── run-reminder.ps1   # Task Scheduler が（launcher.vbs 経由で）呼ぶ実行スクリプト
│   ├── deploy-task.ps1    # config を読み Task Scheduler に登録（冪等）
│   ├── uninstall-task.ps1 # 登録済みタスクを削除
│   └── launcher.vbs       # wscript 経由で黒窓フラッシュを抑止
└── logs/                  # 実行時に生成されるログ
    ├── last_run.log
    ├── last_error.log
    └── last_output.log
```

### 使い方

```powershell
# 初回登録または時刻変更後の再登録
cd $HOME\.claude\skills\kintone-unfinished-reminder\scripts
.\deploy-task.ps1

# 手動でテスト実行
Start-ScheduledTask -TaskName Claude-Kintone-Reminder

# 次回実行予定の確認
Get-ScheduledTask -TaskName Claude-Kintone-Reminder | Get-ScheduledTaskInfo

# 削除
.\uninstall-task.ps1
```

### 時刻 / 頻度を変えるには

`config.yaml` の `schedule` セクション（`daily` または `interval` のいずれか）を編集 → `scripts\deploy-task.ps1` を再実行するだけ。スクリプトは変更不要。

### 実行ログ（`logs/`）

| ファイル | 内容 |
|---------|------|
| `last_run.log` | 実行開始/終了/失敗の記録 |
| `last_error.log` | エラー詳細（認証切れ・API失敗時など） |
| `last_output.log` | claude.exeの全出力（デバッグ用） |

連日 `last_error.log` にエントリが追加されていれば Slack MCP再認証が必要。

## クイックリファレンス

| 項目 | 実装 |
|------|------|
| **Kintone 認証情報** | APIトークン方式（`KINTONE_BASE_URL`+`KINTONE_API_TOKEN`）または ID/パスワード方式（`KINTONE_USERNAME`+`KINTONE_PASSWORD`）。MCP が自動使用。config には書かない |
| **対象アプリID** | config.yaml の `kintone.app_id`（`get-records` の `app`） |
| **チケットURLのbase** | config.yaml の `kintone.domain`、無ければ環境変数 `KINTONE_BASE_URL`（末尾スラッシュ除去） |
| **対象トラッカー** | config.yaml の `trackers` で指定 |
| **対象ステータス** | config.yaml の `statuses` で指定 |
| **0件の場合** | 親投稿は送信、子スレッドは送信しない |
| **チケットURL** | `{base}/k/{app_id}/show#record={$id}`（base = config `kintone.domain`、無ければ env `KINTONE_BASE_URL`。末尾スラッシュ除去） |

## よくあるミス

| ミス | 対処 |
|------|------|
| **フィールド名の誤り** | 必ず `ドロップダウン_0`, `文字列__1行__1`, `Person`, `StatusCode` を使用 |
| **担当者の名前表示** | `Person.value[0].name` で名前取得、メールアドレスは `Person.value[0].code` |
| **Slack ID解決漏れ** | `assignees` の email を `slack_search_users` で User ID に解決。解決失敗（0件・複数件）は名字テキストでフォールバック表示し、チケットは落とさない |
| **スレッド投稿失敗** | 親投稿の `message_ts` を必ず取得して `thread_ts` に渡す |
| **認証情報未確認** | ヘルスチェックで APIトークン または ユーザー名+パスワード のどちらかが揃っているか確認する |
