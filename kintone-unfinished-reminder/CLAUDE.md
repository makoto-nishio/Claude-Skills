# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの正体

これは Claude Code の **skill**（自然言語ワークフロー定義）であり、従来のビルド対象コードベースではない。中核は `SKILL.md`（Claude が読んで実行する業務手順）であり、`scripts/` は「その skill を無人・定期実行するための Windows 配管」にすぎない。つまり**業務ロジックは PowerShell ではなく `SKILL.md` の日本語手順に書かれている**。コードを探す前に `SKILL.md` を読むこと。

ビルド・lint・テストのコマンドは存在しない。

## 二層アーキテクチャ

```
SKILL.md          ← 業務ロジック（Claude が解釈・実行する手順書）
config.yaml       ← 業務パラメータ（kintone / slack / assignees / trackers / statuses / schedule）
   ↑ 読む
scripts/          ← 配管: 上記 skill を Task Scheduler で無人実行するための Windows スクリプト群
   run-reminder.ps1   Task Scheduler が（launcher.vbs 経由で）叩く実行スクリプト。claude.exe を --print で起動
   deploy-task.ps1    config.yaml の schedule を読み Task Scheduler にタスク登録（冪等）
   uninstall-task.ps1 登録解除
   launcher.vbs       wscript ラッパ（黒窓フラッシュ抑止 + exit code 伝播）
logs/             ← 実行時に自動生成（last_run / last_error / last_output）
```

`config.yaml` が**2 つの異なる消費者から読まれる**点が設計の要:
- **Claude（skill 実行時）** — `kintone.app_id` / `kintone.domain` / `slack.channel_id` / `assignees` / `trackers` / `statuses` を使う
- **`deploy-task.ps1`（タスク登録時）** — `schedule` セクションだけを使う

**Kintone の認証情報は config に書かない。** MCP server (`@kintone/mcp-server`) が環境変数から自動で読み込む。対応する認証方式は 2 種類で、どちらか一方が揃っていればよい: **APIトークン方式**（`KINTONE_BASE_URL` + `KINTONE_API_TOKEN`）と **ID/パスワード方式**（`KINTONE_USERNAME` + `KINTONE_PASSWORD`。接続先 URL は `.mcp.json` 等に埋め込み、OS 環境変数の `KINTONE_BASE_URL` は無いことがある）。`get-records` の `app` 引数は環境変数に無いので `kintone.app_id` で渡す。チケット URL の base は config の `kintone.domain` を優先し、未設定時のみ環境変数 `KINTONE_BASE_URL` にフォールバックする（ID/パスワード方式でも URL を組めるようにするため）。

`schedule` は `daily` か `interval` の**どちらか一方のみ**を有効にする（両方有効はデプロイ時エラー）。`deploy-task.ps1` は YAML パーサを使わず、インデント幅（2/4/6 スペース）で手書きパースしているため、`config.yaml` の**インデントを崩すと黙って読み取りに失敗する**。

## 無人実行という最重要制約

この skill は人間のいない環境（Task Scheduler）で走る前提で設計されている。`SKILL.md` を編集する際、この不変条件を壊さないこと:

- **ユーザーへの質問禁止**（`AskUserQuestion` 不使用）。曖昧さは既定動作で進む
- **OAuth 再認証フローに入らない**（無人ではブラウザを開けないため無意味）。認証切れ・トークン未設定は即 exit して `logs/last_error.log` に追記
- ヘルスチェックを最優先で行う（Slack MCP 接続・Kintone 認証情報の存在＝APIトークン または ユーザー名+パスワードのどちらか）。失敗時は「失敗時の通知」を実行して即 exit

## Kintone 固有の不変条件

- **フィールドコードは固定**: トラッカー=`ドロップダウン_0` / 題名=`文字列__1行__1` / 担当者=`Person` / ステータス=`StatusCode`。これらを変えると検索が空振りする
- **担当者名/メール**: `Person.value[0].name`（表示名）と `Person.value[0].code`（メール）。`assignees`（email 配列）との照合はメール（`code`）で行う
- **複数担当の分類**: チケットの `Person` は配列。`assignees` に含まれる担当者が 1 名ならその人、複数なら最初に見つかった人、0 名なら「その他」セクション（詳細は `SKILL.md`）
- **メンション用の User ID は持たない**: `assignees` は email のみ。Slack メンションは実行時に `slack_search_users` で email→User ID を解決する（完全一致 1 件のみ採用。解決失敗は名字テキストでフォールバック）。email は Slack/Kintone 共通の主身分なので、slack_id を config に二重持ちしない
- **チケット URL**: `{base}/k/{app_id}/show#record={$id}`（base = config `kintone.domain`、無ければ環境変数 `KINTONE_BASE_URL`。末尾スラッシュ除去）

## Slack 通知の不変条件

- **2 段構成**: 親投稿（全員メンション＋件数サマリ）→ 子スレッド（トラッカー別→担当者別）。親の `message_ts` を取得して `thread_ts` に渡す
- **0 件のトラッカー**はスレッドを投稿しない。全 0 件でも親投稿（`0件 🎉`）は送る
- `run-reminder.ps1` のプロンプトは、Claude が「主処理を中断して SKILL.md の整合性レビューを始める」のを防ぐために明示的に禁止事項を列挙している。skill の手順を変えたら、このプロンプトとの整合も確認すること

## Windows 固有の落とし穴

- **`.ps1` は UTF-8 BOM 付きで保存する**。編集ツールが BOM を剥がすと Task Scheduler 実行が `2147942401` (`0x80070001`) 等で失敗する。BOM を戻すには README「`.ps1` を編集したら動かなくなった」のスニペットを使う
- `launcher.vbs` は **BOM 不可**（ANSI または BOM なし UTF-8）。本リポジトリは BOM なし UTF-8 で保存（日本語はコメントのみのため、wscript のパースに影響しない）
- タスクは **ログオン中のユーザーのときだけ走る**（`LogonType Interactive`）。ログオフ中は実行されない

## MCP 名前空間（横展開で頻出の落とし穴）

無人実行（`claude --print`）で使われる Kintone / Slack MCP の名前空間が `run-reminder.ps1` の `--allowedTools` に含まれていないと、全 API 呼び出しが「権限未付与」で拒否され、**何も実行できないまま正常終了する**。`claude mcp list` で接続中のサーバ名を確認し、許可リストに含めること。本リポジトリは Kintone（`mcp__kintone__*`）と Slack（`mcp__plugin_slack_slack__*` / `mcp__claude_ai_Slack__*`）を既定で許可済み。`run-reminder.ps1` には「no-op 検知」があり、出力に権限拒否の兆候があれば exit 0 でも `failed (no-op suspected)` として記録する。

## よく使う運用コマンド

```powershell
# タスク登録 / スケジュール変更後の再登録（冪等）
cd scripts; .\deploy-task.ps1

# 手動で今すぐ実行（隠しウィンドウ。完了は logs/ で確認）
Start-ScheduledTask -TaskName Claude-Kintone-Reminder

# 次回実行予定
Get-ScheduledTask -TaskName Claude-Kintone-Reminder | Get-ScheduledTaskInfo

# ログ確認
Get-Content .\logs\last_run.log
Get-Content .\logs\last_output.log -Encoding utf8

# 登録解除
cd scripts; .\uninstall-task.ps1
```

タスク名は固定で `Claude-Kintone-Reminder`。`last_run.log` が `done` で終わっていれば成功。`failed` なら `last_error.log` / `last_output.log` を見る。
