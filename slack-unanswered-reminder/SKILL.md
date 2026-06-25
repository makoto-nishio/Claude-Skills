---
name: slack-unanswered-reminder
description: Use when asked to remind a team about unfinished items in a Slack QA List that team members have not yet replied to. One-shot check; scheduling is handled separately by Windows Task Scheduler, not this skill.
---

# Slack 未返信投稿リマインダー（QA List ベース）

## 概要

Slack の QA List で「完了」が未チェックの項目を抽出し、各項目のスレッドを確認して、**チームが誰も返信していない**ものだけをチームにリマインドする。一回の実行で「List 名→File ID 解決 → CSV 読込 → 未完了項抽出 → 各スレッド確認 → チーム未返信を抽出 → 2段構成で通知」まで行う。

定期実行のタイミングは本 skill の責務外（Windows Task Scheduler 側。詳細は README / CLAUDE.md）。

## 使用タイミング

- QA List の未完了項で、チームが未返信のものを検出・リマインドしたい
- **使わない**: 単発の手動確認（Slack 検索で十分）／外部ツールで監視済み

## 設定（`config.yaml`）

設定値はすべて同ディレクトリの `config.yaml` から読む。skill 本体に直書きしない。**skill 実行時に Claude が使うのは以下3キーのみ**:

| キー | 説明 |
|------|------|
| `list_name` | 監視対象の Slack List 名（1つ）。実行時に File ID へ解決 |
| `notification_channel` | 通知先チャンネル ID または User ID（1つ） |
| `team_members` | チームメンバー。各要素は **User ID または email**（混在可）。email は実行時に User ID へ解決（profile email の完全一致1件のみ採用。0件・複数件は無視） |

> `schedule.*` は **deploy-task.ps1 が読む**キーで Claude は使わない。スキーマは README / CLAUDE.md を参照。

**発信元**: 通知は `notification_channel`（=送信先）に送るが、**送信者は Slack MCP のログイン身分**（OAuth トークン所有者、例: `U03CB6Z46`）。config では変えられない。

## 無人実行モード（前提・厳守）

自動実行が前提。**いかなる場面でもユーザーに質問しない**。

- `AskUserQuestion` 禁止／OAuth 再認証フロー（`slack_authenticate` 等）に入らない
- 設定の曖昧さ・選択肢 → 既定動作で進む（対象0件なら通常 exit）
- 想定外エラー・認証切れ → 「失敗時の通知」を実行して即 exit

## 実行ワークフロー

各ステップの判定ルールの正本は後述の「ルール一覧」表。本節は手順と順序のみ。

0. **ヘルスチェック**: `slack_search_users` で `team_members` 先頭1件を確認。失敗（MCP 未接続・認証切れ・不通）なら**再認証に入らず**「失敗時の通知」→ 即 exit。
1. **設定読込と正規化**: `list_name` / `notification_channel` / `team_members` を取得。`team_members` の各要素を User ID へ正規化（`@` を含む=email は `slack_search_users` で解決、`@` なし=そのまま User ID）。
2. **List 解決**: `slack_search_public`（`content_types="files"`, `query="<list_name> type:lists"`）でタイトル完全一致を探す。0件・複数件は exit、1件ならその File ID。
3. **List 読込**: `slack_read_file` で CSV 取得。列= `タイトル, 問い合わせ内容, 回答希望日, 投稿者, 開始日, 期日, 担当者, 進捗率(％), Status, NextAction, 完了, メッセージリンク`。クォート内の改行・カンマは区切りにしない。
4. **未完了抽出**: 「完了」が `true` の行だけ完了。`false`・空欄は未完了として残す。
5. **各未完了項のスレッド確認**:
   1. `メッセージリンク` から `channel_id` と `ts` を取り出す（空・不正な行はスキップ）。
   2. `slack_read_thread`（**`response_format="detailed"`**）で**全返信**を取得し、各**返信(replies)**の **User ID** を得る（親投稿の本文は判定に使わない）。
   3. **チーム未返信のみ残す**（判定は User ID。表示名で照合しない）。判定基準は**スレッド返信(replies)内にチームメンバーの返信があるか**のみ。残す行は「担当者」列(email)も保持。
6. **担当者でグルーピング**:
   1. `team_members` 各 User ID を `slack_read_user_profile` で email 解決し `email→User ID` 表を作る（List の「担当者」列は email）。
   2. 未返信項を「担当者」email でグループ分け（team 内→本人グループ／空欄・チーム外→「未割当」）。
   3. 並びは `team_members` の config 順（項目があるグループのみ）、最後に「未割当」。番号は各グループ内で1から。
7. **通知送信（2段構成・対象1件以上のときのみ）**:
   1. **親メッセージ**: `notification_channel` に「全員メンション＋見出し（日付・List名・N件）」だけを投稿し、`message_ts` を控える。
   2. **スレッド返信**: その `message_ts` を `thread_ts` に詳細リストを投稿（書式は `reference/notification-format.md`）。冒頭の全員メンションは入れない。`reply_broadcast` は使わない。

## 通知メッセージのフォーマット

通知本文を組み立てる前に、**`reference/notification-format.md` を必ず読み、その書式に従う**。要点だけ先に示すと: 2段構成（親メッセージ=全員メンション＋見出しのみ／スレッド返信=担当者別グループ）。詳細の各項目は**1行**で、`<{メッセージリンク}|{タイトル}>` のリンク記法でタイトルをリンク化し生 URL は出さない。`【MM-DD HH:MM】` はリンクの外に置く。**タイトル内の `@xxx`（`<@U…>` / `<!subteam^…>` / `@表示名` 等のメンション記法）は削除してからリンク化する**（意図しない通知発火・表示崩れを防ぐ）。

## ルール一覧（判定の正本）

| 項目 | ルール |
|------|------|
| **データソース** | `list_name` の Slack List（`slack_read_file` で CSV 取得）。時間範囲の制限なし |
| **「完了」判定** | `true` のときだけ完了。`false`・空欄は未完了 |
| **List 解決** | タイトル完全一致で1件に絞る。0件・複数件は exit（推測しない） |
| **CSV パース** | セル内の改行・カンマはクォート内では区切りにしない（1レコードが複数行にまたがる） |
| **ts 復元** | `p` の後ろの数字列の**末尾6桁の前に小数点**（`p1750724758985509`→`1750724758.985509`）。桁ミスでスレッドが見つからない |
| **リンクなし項目** | `メッセージリンク` が空・不正ならスキップ（通知に含めない） |
| **スレッド確認** | `slack_read_thread` を **detailed** で呼び全返信を取得。`concise` は表示名のみで User ID が出ないため使わない |
| **返信者判定** | 必ず **User ID** で照合。表示名で照合しない（例: `U03CB6Z46` の表示名は config ラベルと異なり、表示名照合だと本人の返信を取りこぼす実害あり） |
| **チーム返信の判定** | **スレッド返信(replies)内**にチームメンバーの User ID があれば「返信済み」（→ 除外）。**ボットの親自動投稿に含まれる担当者メンションは返信済み判定に使わない**（このQA Listの親投稿は全てボット `コア機能チームQA` が担当者を `<@…>` でメンションするため、これを数えると未返信を取りこぼす実害あり） |
| **被メンション=返信済み** | 「被メンション=返信済み」扱いにするのは**スレッド返信(replies)内で人間がメンションして対応を振った** User ID のみ（`team_members` 外でも）。**親自動投稿のメンションは対象外** |
| **email 解決** | profile email の完全一致1件のみ採用。0件・複数件は無視（`@` なしはそのまま User ID） |
| **担当者の突合** | List の「担当者」列は email。`slack_read_user_profile` で得た team_members の email と照合 |
| **通知の構成** | 親=全員メンション＋見出しのみ／スレッド返信=担当者別グループ（本人のみ@、未割当は最後・無@、番号は各グループ内で1から）。**書式の正本は `reference/notification-format.md`** |
| **タイトルの @ 除去** | タイトル文字列に含まれる `@xxx`（`<@U…>` / `<!subteam^…>` / `@表示名` 等のメンション記法）はすべて削除してからリンク化する（意図しない通知発火・表示崩れ防止。前後の余分な空白も詰める） |
| **未返信ゼロ** | 通知を一切送らない |

## エラーハンドリングと失敗時の通知

- List 解決0件/複数件、`slack_read_file` 失敗、API 連続失敗、Slack MCP 認証切れ → **再認証に入らず** `logs/last_error.log` に追記して即 exit。
- メッセージリンクを解析できない行はスキップ。API 失敗は1回リトライ→継続失敗で「失敗時の通知」。
- 重複防止が必要なら `slack_read_channel` で通知先履歴を確認。

失敗時のログ追記（Bash ツールから PowerShell 実行）:

```powershell
$logDir = "$env:USERPROFILE\.claude\skills\slack-unanswered-reminder\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Slack reminder failed: <reason>" | Out-File "$logDir\last_error.log" -Append -Encoding utf8
```

## スケジューリング

本 skill は「呼ばれたら1回実行する」だけ。定期実行（Task Scheduler 登録・スケジュール変更・ログ確認・スクリプト構成）は **README.md / CLAUDE.md** を参照。`config.yaml` の `schedule` 編集 → `scripts\deploy-task.ps1` 再実行で反映。
