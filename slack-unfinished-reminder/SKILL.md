---
name: slack-unfinished-reminder
description: Use when asked to check a Slack QA List for unfinished ("完了" unchecked) items whose linked message was posted at least a configurable number of business hours ago (default 48 business hours = 2 business days, weekends excluded), and send a "stagnant thread" reminder to the team. Reads a named Slack List, takes items whose "完了" column is unchecked AND whose linked message is older than min_elapsed_business_hours (business hours), groups them by assignee, color-codes each by elapsed business days, and posts a reminder. No thread reply-check is performed. One-shot check; scheduling (cron, daily run, etc.) is handled separately by Windows Task Scheduler via scripts/deploy-task.ps1, not by this skill.
---

# Slack 停滞スレッドリマインド（QA List ベース）

> **このスキルは `slack-unfinished-reminder`（停滞スレッドリマインド）です。よく似た別スキル `slack-unanswered-reminder`（未返信投稿リマインダー）と混同しないこと。**
>
> | | **本スキル** `slack-unfinished-reminder` | 別スキル `slack-unanswered-reminder` |
> |---|---|---|
> | 通称 | 停滞スレッドリマインド | 未返信投稿リマインダー |
> | 抽出条件 | 完了未チェック ＋ **投稿から 48 営業時間（可変）以上経過** | 完了未チェック ＋ **チームが未返信** |
> | 経過時間しきい値 | あり（`min_elapsed_business_hours`／営業時間） | なし |
> | スレッド返信確認 | **しない**（`slack_read_thread` を呼ばない） | する（`slack_read_thread` で User ID 照合） |
> | 色分け（🔴🟡⚪） | あり（経過営業日で色分け） | なし |
> | Task Scheduler タスク名 | `Claude-Slack-Unfinished-Reminder` | `Claude-Slack-Unanswered-Reminder` |
>
> 両スキルは別ディレクトリ・別タスク名で独立しており、同時に運用できる。本ファイルを編集するときは、必ず `slack-unfinished-reminder`（本スキル）側だけを対象にすること。

## 概要

**Slack の QA List で「完了」が未チェック、かつ投稿（スレッド作成）から一定の "営業時間"（既定 48 営業時間＝2 営業日。`min_elapsed_business_hours` で可変）以上経過した項目を抽出し、担当者ごとにまとめてリマインドする**。一回の実行で「List 名から File ID を解決 → List を読む → 完了未チェック項を抽出 → 投稿からの経過 "営業時間" で絞り込み（`min_elapsed_business_hours` 以上） → 担当者でグルーピング・経過営業日で色分け → 通知メッセージを投稿」を行う。実行のタイミング（毎日何時に動かすか）は本 skill の責務外で、Task Scheduler 側で設定する。

**経過時間は "営業時間" で数える**: 土日に当たる時間は経過から除外する（祝日は除外しない）。1 営業日 = 24 営業時間として扱う（例: 48 営業時間 = 2 営業日）。基準は List の更新日ではなく、各項目の `メッセージリンク` が指す**元投稿の投稿時刻**（投稿直後・週末分はまだ猶予扱いにするため）。

> **重要（旧仕様からの変更）**: かつては「チームの誰も返信していない（未返信）」項目に絞っていたが、**この未返信フィルタは廃止**した。現在は**スレッドの返信状況を一切確認せず**、「完了未チェック かつ 48 営業時間以上経過」だけで対象を決める（`slack_read_thread` は使わない）。旧来の暦時間しきい値 `monitoring_period_days` / `min_elapsed_hours` も廃止し、営業時間ベースの `min_elapsed_business_hours` に置き換えた。

## 使用タイミング

**以下の場合に使用**:
- QA List 上の未完了（完了未チェック）項目で、投稿から一定営業時間以上「停滞」しているものをチェックしたい
- チームへ停滞スレッドのリマインダーを担当者別に送信したい
- 一回限りの停滞検出を実行したい

**以下の場合は使わない**:
- 単発の手動確認のみ（Slack 検索で十分）
- 外部ツール（PagerDuty 等）で既に監視済み

## 設定

設定値はすべて同じディレクトリの `config.yaml` から読み込む。skill 本体には設定を直書きしない。

### `config.yaml` のスキーマ

| キー | 型 | 説明 |
|------|------|------|
| `list_name` | 文字列 | 監視対象の Slack List 名（1 つのみ）。実行時にこの名前から File ID を解決する |
| `notification_channel` | 文字列 | 通知先チャンネル ID または User ID（DM 送信時、1 つのみ） |
| `team_members` | 文字列の配列 | チームメンバー。各要素は **User ID または email**（混在可）。email は実行時に User ID へ解決する（完全一致 1 件のみ採用。0 件・複数件は無視） |
| `min_elapsed_business_hours` | 整数 (1 以上) | **投稿からの経過 "営業時間" しきい値**。各項目の `メッセージリンク` の `ts`（投稿時刻）から現在までの経過時間を**土日を除外して**算出し（祝日は除外しない。1 営業日 = 24 営業時間）、**この値以上経過した未完了項のみ**を対象にする。省略・空欄・0 以下のときは **48**（＝2 営業日）を既定値として使う |
| `schedule.daily.time` | 文字列 (HH:MM) | **daily モード時**: 起動時刻（24 時間制） |
| `schedule.daily.weekdays_only` | 真偽値 | **daily モード時**: true: 月-金のみ / false: 毎日 |
| `schedule.interval.hours` | 整数 (1 以上) | **interval モード時**: 何時間ごとに実行するか |
| `schedule.interval.weekdays_only` | 真偽値 (省略可) | **interval モード時**: true で月-金のみ、false/省略で毎日 |
| `schedule.interval.between.start` | 文字列 (HH:MM) | **interval モード時**: 一日のうち実行開始時刻（省略可、end とセット） |
| `schedule.interval.between.end` | 文字列 (HH:MM) | **interval モード時**: 一日のうち実行終了時刻（省略可、start とセット） |

> **廃止したキー**: `monitored_channels`、`monitoring_period_days`、`min_elapsed_hours`（暦時間版）。データソースは `list_name` の List に一本化し、経過判定は営業時間ベースの `min_elapsed_business_hours` に統一した。対象チャンネルは各 List 項目の `メッセージリンク` から動的に決まる。

### 設定例

```yaml
list_name: "コア機能チームQAリスト"

notification_channel: C0XXXXXXXXX

# 投稿後この "営業時間"（土日除外）以上経過した未完了項のみ通知（既定 48＝2営業日）
min_elapsed_business_hours: 48

team_members:
  - U0XXXXXXX
  - U0XXXXXXX
  - U0XXXXXXX

# daily または interval のどちらか一方を有効にする
schedule:
  daily:
    time: "13:00"
    weekdays_only: true
```

実際の値は `config.yaml` を参照する。skill 本体には書かない。

> **発信元アカウント**: `notification_channel` は送信先のみを決め、発信者は決めない。投稿は Slack MCP がログイン中のアカウント名義で行われる（skill 内では変更不可）。詳細は [README.md](README.md) 参照。

## 無人実行モード（前提）

この skill は自動実行（Task Scheduler 等）が前提。**AI はいかなる場面でもユーザーに質問してはならない**。

- `AskUserQuestion` ツールは使用禁止
- OAuth 再認証フロー（`slack_authenticate` 等）には入らない
- 設定の曖昧さ・選択肢の判断 → 既定動作で進む（処理対象 0 件なら通常 exit）
- 想定外のエラー → 「失敗時の通知」を実行して即 exit
- 「ユーザーに確認したい」と感じた場面は、すべて即 exit 扱い

## 実行ワークフロー

0. **ヘルスチェック（最優先・無人実行向け）**: 主要 API を呼ぶ前に軽量な検証を行う
   - `slack_search_users` で `team_members` の先頭エントリ（User ID または email）を 1 件確認する
   - 失敗時（Slack MCP 未接続、認証期限切れ、ネットワーク不通など）:
     - **OAuth 再認証フローには絶対に入らない**（無人実行では人がブラウザを開けないため意味がない）
     - 下記「失敗時の通知」セクションの PowerShell を実行する
     - 通知後すぐに exit。後続のステップは一切実行しない

1. **設定の読み込みと `team_members` の正規化**:
   1. `./config.yaml` を読み、`list_name` / `notification_channel` / `team_members` / `min_elapsed_business_hours` を取得する
      - `min_elapsed_business_hours` が未設定・空欄・数値でない・0 以下のときは **48**（＝2 営業日）を使う
      - **現在時刻のエポック秒**を取得しておく（Bash ツールから `date +%s`、または PowerShell の `[int][double]::Parse((Get-Date -UFormat %s))`）。これを基準に各項目の経過営業時間を算出する
   2. `team_members` の各要素は **User ID または email** のどちらでもよい（混在可）。返信者判定は最終的に User ID で行うため、**この時点で全要素を User ID へ正規化**する:
      - 要素が `@` を含む → **email** とみなす。`slack_search_users` を `query=<email>` で呼ぶ
        - 返ってきたユーザーのうち、**profile の email が完全一致**（大文字小文字を無視）するものだけを採用候補とする
        - **完全一致が 1 件 → その User ID を採用**
        - **0 件 または 2 件以上 → そのエントリは無視**（`team_members` から除外。無人モードなので質問・推測しない）
      - 要素が `@` を含まない → そのまま **Slack User ID** として扱う
   3. 正規化後の **User ID の集合**を、以降のステップで `team_members` として使う（元の config の順序は保ち、無視したエントリは詰める）

2. **List の解決（名前 → File ID）**: `slack_search_public` を `content_types="files"`、`query="<list_name> type:lists"` で呼び、`list_name` と**タイトルが完全一致**する List を探す
   - 一致が **0 件** → 「失敗時の通知」に解決失敗（候補 0 件）を記録して exit
   - 一致が **複数件**（同名 List） → 無人モードでは判断できない。「失敗時の通知」に候補件数を記録して exit
   - 一致が **1 件** → その `File ID` を採用

3. **List の読み込み**: `slack_read_file` を File ID で呼び、CSV を取得する
   - CSV の列: `タイトル, 問い合わせ内容, 回答希望日, 投稿者, 開始日, 期日, 担当者, 進捗率(％), Status, NextAction, 完了, メッセージリンク`
   - **CSV パースの注意**: セル内に改行・カンマを含む値はダブルクォートで囲まれている。クォート内の改行・カンマは区切りとして扱わない（1 レコードが複数行にまたがる）

4. **未完了項の抽出**: 「完了」列が `true` の行だけを「完了」とみなす。**`false` または空欄の行はすべて未完了**として候補に残す

5. **投稿からの経過 "営業時間" で絞り込み（`min_elapsed_business_hours`）と色分け**: 未完了項のうち、**投稿から `min_elapsed_business_hours` 営業時間以上経過したものだけ**を残す。週末分・直近分（猶予内）はここで除外する
   1. **リンクの解析**: 各行の `メッセージリンク`（`https://{workspace}.slack.com/archives/{channel_id}/p{ts_no_dot}`）から `channel_id` と `ts` を取り出す
      - `ts` 復元: `p` の後ろの数字列の**末尾 6 桁の前**に小数点を挿入（例: `p1750724758985509` → `1750724758.985509`）
      - **`メッセージリンク` が空・不正で `ts` を復元できない行はスキップ**（経過時間を判定できないため候補から除外）
   2. **経過営業時間の算出**: `ts`（投稿）から現在までの経過時間のうち、**土日に当たる時間を除外**した秒数を営業時間に直す（祝日は除外しない。JST で判定）。計算は手算ではなく、Bash/PowerShell で下記スニペットを使う:
      ```powershell
      $jst = [System.TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')
      function Get-BusinessHours([double]$tsPost, [double]$now) {
          $start = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::FromUnixTimeSeconds([int64]$tsPost), $jst).DateTime
          $end   = [System.TimeZoneInfo]::ConvertTime([datetimeoffset]::FromUnixTimeSeconds([int64]$now),    $jst).DateTime
          $sec = 0.0; $cur = $start
          while ($cur -lt $end) {
              $segEnd = $cur.Date.AddDays(1); if ($segEnd -gt $end) { $segEnd = $end }
              if ($cur.DayOfWeek -ne 'Saturday' -and $cur.DayOfWeek -ne 'Sunday') { $sec += ($segEnd - $cur).TotalSeconds }
              $cur = $segEnd
          }
          return [math]::Round($sec / 3600.0, 2)
      }
      ```
      `経過営業日 = 経過営業時間 / 24` も算出する（色分けに使用）
   3. **絞り込み**: `経過営業時間 < min_elapsed_business_hours` の行は**候補から除外**。`>= min_elapsed_business_hours` の行だけを次ステップへ渡す
   4. **色分けマーカー**（経過営業日に応じて、各項目の表示用に決める）:
      - `経過営業日 >= 20` → 🔴
      - `else 経過営業日 >= 10` → 🟡
      - `else 経過営業日 >= 2` → ⚪
      - （しきい値が既定 48 営業時間＝2 営業日なら、残った全項目は必ず ⚪ 以上になる。`min_elapsed_business_hours` を 48 未満に下げて 2 営業日未満の項目が残った場合のみ、その項目は色マーカーなし）
   5. ここで残った件数が 0 なら、以降の通知は行わず通常 exit する
   6. 各行について「**担当者**」列の値（email）を保持する（次のグルーピングで使用。空欄なら空のまま）

   > **スレッドの返信確認は行わない**。旧仕様の「チーム未返信の絞り込み」は廃止済み。`slack_read_thread` は本ワークフローでは呼ばない。

6. **担当者でグルーピングして本文を整形**: 詳細（スレッド返信）は「担当者」ごとにまとめる
   1. **email↔User ID 対応表**: `team_members` の各 User ID について `slack_read_user_profile` を呼び、email を取得して `email → User ID` の対応表を作る（List の「担当者」列は email のため、突合に必要）
   2. **振り分け**: 対象の各項目を「担当者」列（email）でグループに振り分ける
      - 担当者 email が `team_members` のいずれかに一致 → その **User ID のグループ**へ
      - 担当者が空欄、または `team_members` の誰にも一致しない（チーム外） → **「未割当」グループ**へ
   3. **並び順**: `team_members`（config の順序）のうち**項目があるグループだけ**を上から並べ、**最後に「未割当」グループ**（項目がある場合のみ）。項目ゼロのグループは出さない
   4. **メンション**: 親メッセージは `team_members` 全員をメンション。スレッド返信は**各グループ見出しに担当者本人のみ**をメンション。**「未割当」グループはメンションしない**
   5. 番号は**各グループ内で 1 から**振り直す（グループをまたいで連番にしない）。親メッセージの「N 件」は全グループの合計件数
   6. **各グループ見出しに件数 `（N件）`** を付け、**各項目に色マーカー**（ステップ 5 で決めた 🔴/🟡/⚪）を行頭に付ける。各項目は 1 行で、タイトルを `[タイトル](メッセージリンク)` のリンクにする
7. **通知の送信（2 段構成）**: 「未完了 かつ `min_elapsed_business_hours` 以上経過」の項目が 1 件以上ある場合のみ送信する（0 件なら一切送信しない）
   1. **親メッセージ（見出し）**: `notification_channel` に `slack_send_message` で「メンション全員 + 見出し（⚠️ 停滞スレッドリマインド・日付・N 件）+ 説明文 + 凡例」**だけ**を投稿する。詳細項目は載せない。返ってきた `message_ts` を控える
   2. **スレッド返信（詳細）**: 上で得た `message_ts` を `thread_ts` に指定して `slack_send_message` を再度呼び、詳細リスト（担当者別グループ・見出しに件数・各項目は「色マーカー＋番号＋日時＋タイトルリンク」の 1 行）を投稿する。**冒頭に全員メンションは入れない**（担当者ごとに各グループ見出しで本人をメンションするため、重複通知になる）。`reply_broadcast` は **使わない**（詳細をチャンネルへ再掲しないため）

## 通知メッセージのフォーマット

**送信前に必ず [`reference/notification-format.md`](reference/notification-format.md) を読み、その固定テンプレート・整形ルールどおりに整形すること。** 概要だけ示す（厳密な書式・注意点は同ファイルが正）:

- **2 段構成**: 親メッセージ（`⚠️ 停滞スレッドリマインド（日付）` + 全員メンション + 件数 + 説明 + 凡例）→ スレッド返信に担当者別の詳細
- スレッド返信は担当者でグルーピング（見出し末尾に `（N件）`、本人のみ @、未割当は最後・無 @）。各項目は **1 行**で `{色} {番号}. 【MM-DD HH:MM】[タイトル](メッセージリンク)`
- 凡例・色は経過営業日で 🔴≥20 / 🟡≥10 / ⚪≥`{D}`（`{D}` = `min_elapsed_business_hours`/24）

## クイックリファレンス

| 項目 | 実装 |
|------|------|
| **データソース** | `list_name` の Slack List（`slack_read_file` で CSV を取得） |
| **対象範囲** | List 上の「完了」未チェック項のうち、**投稿から `min_elapsed_business_hours`（既定 48 営業時間＝2 営業日）以上経過したもの**。返信状況は問わない |
| **「完了」判定** | 値が `true` のときだけ完了。`false`・空欄は未完了 |
| **経過時間の判定** | 各項目の `メッセージリンク` の `ts`（投稿時刻）から現在までの経過時間を**土日除外**（祝日は除外しない）で営業時間に換算し、`>= min_elapsed_business_hours` の項目のみ対象。未設定・0 以下は 48 を使う |
| **色分け** | 経過営業日（=営業時間/24）で 🔴≥20 / 🟡≥10 / ⚪≥2。各項目の番号前に付与し、親メッセージに凡例を載せる |
| **返信確認** | **行わない**（旧仕様の未返信フィルタは廃止。`slack_read_thread` は使わない） |
| **リンクなしの項目** | `ts` を復元できないためスキップ（通知に含めない） |
| **ts 復元** | `p1234567890985509` → `1234567890.985509`（末尾 6 桁の前に小数点） |
| **通知の構成** | 親メッセージ=⚠️見出し+全員メンション+件数+説明+凡例／スレッド返信=担当者別グループ（見出しに `（N件）`、本人のみ @、未割当は最後・無 @、各項目は「色マーカー+番号+日時+`[タイトル](リンク)`」の 1 行、番号は各グループ内で 1 から） |
| **`team_members` の形式** | 各要素は User ID または email（混在可）。email は起動時に `slack_search_users` で User ID へ解決（profile email の完全一致 1 件のみ採用。0 件・複数件は無視） |
| **担当者の突合** | List の「担当者」列は email。`slack_read_user_profile` で得た team_members の email と照合してグループ分け |
| **対象ゼロの場合** | 通知を送信しない |

## よくあるミス

| ミス | 対処 |
|------|------|
| **完了の判定を緩める** | `true` 以外（`false`・空欄）はすべて未完了。空欄を「完了」にしない |
| **経過時間の基準を間違える** | 経過時間は List の更新日でなく `メッセージリンク` の `ts`（元投稿の投稿時刻）で測る。`min_elapsed_business_hours` 未満の項目は未完了でも通知しない |
| **暦時間で数えてしまう** | しきい値は **営業時間**（土日除外）。単純な `(now - ts)/3600` ではなく、土日分を除いて換算する（祝日は除外しない）。1 営業日 = 24 営業時間 |
| **返信確認をしてしまう** | 本仕様では返信状況を見ない。`slack_read_thread` は呼ばない（未返信フィルタは廃止済み） |
| **色マーカーを付け忘れる** | 各詳細項目の番号前に経過営業日に応じた 🔴/🟡/⚪ を付ける。親メッセージには凡例を載せる |
| **List 名で曖昧検索** | タイトル完全一致で 1 件に絞る。0 件・複数件は exit（無人モードで推測しない） |
| **CSV のクォート無視** | セル内改行・カンマを区切りと誤認しない。クォート規則に従ってパースする |
| **ts 復元ミス** | 末尾 6 桁の前に小数点。桁を間違えると投稿時刻・経過時間が狂う |
| **リンクなし項目の扱い** | `メッセージリンク` が無い行はスキップ（誤って通知に含めない） |
| **email 解決を緩める** | email は profile email の完全一致 1 件のみ採用。0 件・複数件は無視（推測で User ID を当てない）。`@` を含まない要素はそのまま User ID 扱い |

## エラーハンドリング

- **List 解決**: `slack_search_public` の結果が 0 件 / 複数件なら「失敗時の通知」を実行して exit（候補件数を記録）
- **List 読み込み**: `slack_read_file` 失敗（File ID 無効・権限不足など）を捕捉
- **メッセージリンク**: 解析できない行はスキップ
- **メンバー ID**: `slack_search_users` で有効性を確認
- **API 失敗**: ログ出力 → 1 回リトライ → 継続失敗時は「失敗時の通知」を実行
- **認証失敗（Slack MCP）**: OAuth 再認証フローに入らず即時 exit。「失敗時の通知」を実行
- **重複防止**: 必要なら通知チャンネルの履歴を `slack_read_channel` で検索して、同じ項目を二重に通知しない

## 失敗時の通知（Windows）

認証切れ・API 連続失敗・List 解決失敗の際は、Slack に依存せず `logs/last_error.log` に追記する（Bash ツールから PowerShell を実行）:

```powershell
$logDir = "$env:USERPROFILE\.claude\skills\slack-unfinished-reminder\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Slack reminder failed: <error reason here>" | Out-File -FilePath "$logDir\last_error.log" -Append -Encoding utf8
```

## スケジューリング・運用・ディレクトリ構成について

本 skill は「呼び出されたら一回実行する」もの。定期実行（Task Scheduler）・デプロイ手順・ディレクトリ構成・ログの見方など**人間向けの運用情報は [README.md](README.md) を参照**（ここでは重複させない）。
