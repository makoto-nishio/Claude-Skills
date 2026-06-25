# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの正体

これは Claude Code の **skill**（自然言語ワークフロー定義）であり、従来のビルド対象コードベースではない。中核は `SKILL.md`（Claude が読んで実行する業務手順）であり、`scripts/` は「その skill を無人・定期実行するための Windows 配管」にすぎない。つまり**業務ロジックは PowerShell ではなく `SKILL.md` の日本語手順に書かれている**。コードを探す前に `SKILL.md` を読むこと。

ビルド・lint・テストのコマンドは存在しない。

> ⚠️ **これは `slack-unfinished-reminder`（停滞スレッドリマインド）です。** よく似た別スキル `slack-unanswered-reminder`（未返信投稿リマインダー）が別ディレクトリにあるので混同しないこと。
> - **本スキル**: 完了未チェック ＋ **投稿から `min_elapsed_business_hours`（既定 48）営業時間以上経過**で抽出。**返信確認はしない**（`slack_read_thread` を呼ばない）。経過営業日で 🔴🟡⚪ に色分け。タスク名 `Claude-Slack-Unfinished-Reminder`
> - **別スキル**: 完了未チェック ＋ **チーム未返信**で抽出（`slack_read_thread` で返信確認あり）。時間しきい値・色分けなし。タスク名 `Claude-Slack-Unanswered-Reminder`
> 別ディレクトリ・別タスク名なので同時運用可。本リポジトリのファイルを編集するときは `slack-unfinished-reminder` 側だけを対象にすること。

## 二層アーキテクチャ

```
SKILL.md          ← 業務ロジック（Claude が解釈・実行する手順書）
config.yaml       ← 業務パラメータ（監視 List 名 / 通知先 / team_members / min_elapsed_business_hours / schedule）
   ↑ 読む
scripts/          ← 配管: 上記 skill を Task Scheduler で無人実行するための Windows スクリプト群
   run-reminder.ps1   Task Scheduler が実際に叩く実行スクリプト。claude.exe を --print で起動
   deploy-task.ps1    config.yaml の schedule を読み Task Scheduler にタスク登録（冪等）
   uninstall-task.ps1 登録解除
   launcher.vbs       wscript ラッパ（黒窓フラッシュ抑止 + exit code 伝播）
logs/             ← 実行時に自動生成（last_run / last_error / last_output）
```

`config.yaml` が**2 つの異なる消費者から読まれる**点が設計の要:
- **Claude（skill 実行時）** — `list_name` / `notification_channel` / `team_members` / `min_elapsed_business_hours` を使う（`list_name` は実行時に File ID へ解決される）
- **`deploy-task.ps1`（タスク登録時）** — `schedule` セクションだけを使う

`schedule` は `daily` か `interval` の**どちらか一方のみ**を有効にする（両方有効はデプロイ時エラー）。`deploy-task.ps1` は YAML パーサを使わず、インデント幅（2/4/6 スペース）で手書きパースしているため、`config.yaml` の**インデントを崩すと黙って読み取りに失敗する**。

## 無人実行という最重要制約

この skill は人間のいない環境（Task Scheduler）で走る前提で設計されている。`SKILL.md` を編集する際、この不変条件を壊さないこと:

- **ユーザーへの質問禁止**（`AskUserQuestion` 不使用）。曖昧さは既定動作で進む
- **OAuth 再認証フローに入らない**（無人ではブラウザを開けないため無意味）。認証切れは即 exit して `logs/last_error.log` に追記
- **返信確認はしない**。本スキルは `slack_read_thread` を呼ばず、スレッドの返信状況で絞り込まない（旧「未返信」フィルタは廃止済み。返信チェックが必要なのは別スキル `slack-unanswered-reminder` の方）
- **経過時間は "営業時間" で数える**: `メッセージリンク` の `ts`（投稿時刻）から現在までの経過時間を**土日除外**（祝日は除外しない）で算出し、`min_elapsed_business_hours`（既定 48＝2 営業日）以上のものだけを対象にする。1 営業日 = 24 営業時間。計算は `SKILL.md` の `Get-BusinessHours` スニペットを使う
- **色分け**は経過営業日（=営業時間/24）で 🔴≥20 / 🟡≥10 / ⚪≥2。各項目の行頭に付与し、親メッセージに凡例を載せる
- **「完了」判定は `true` のみ完了**（`false`・空欄は未完了）。`メッセージリンク` から `ts` を復元する際は**末尾 6 桁の前に小数点**（`p1750724758985509` → `1750724758.985509`）。通知の書式は `SKILL.md` の固定テンプレート（親=⚠️見出し+凡例／スレッド=担当者別・色マーカー・`[タイトル](リンク)` の 1 行）を使う

`run-reminder.ps1` のプロンプト（54-73 行目付近）は、Claude が「主処理を中断して SKILL.md の整合性レビューを始める」のを防ぐために明示的に禁止事項を列挙している。skill の手順を変えたら、このプロンプトとの整合も確認すること。

## Windows 固有の落とし穴

- **`.ps1` は UTF-8 BOM 付きで保存する**。編集ツールが BOM を剥がすと Task Scheduler 実行が `2147942401` (`0x80070001`) 等で失敗する。BOM を戻すには README「`.ps1` を編集したら動かなくなった」のスニペットを使う
- `launcher.vbs` は **ANSI** で保存（BOM 不可）
- タスクは **ログオン中のユーザーのときだけ走る**（`LogonType Interactive`）。ログオフ中は実行されない

## 既知の不整合（編集時に踏みやすい）

- `SKILL.md` の `name:`・ディレクトリ名・README/スクリプトのパス例・タスク名は **`slack-unfinished-reminder` / `Claude-Slack-Unfinished-Reminder` に統一済み**。別スキル `slack-unanswered-reminder` の名前を紛れ込ませないこと（過去に `name:` が別スキルと同名で混同していた経緯あり）
- Slack MCP ツールの名前空間は `mcp__plugin_slack_slack__*` に統一済み（`run-reminder.ps1` の `--allowedTools`、`.claude/settings.local.json` とも）。実環境で接続している MCP サーバ名がこれと異なる場合は両方を合わせること（不一致だと権限プロンプトで無人実行が止まる）。List 機能は `slack_search_public`（List 名→File ID 解決）と `slack_read_file`（List を CSV として読む）に依存する

## よく使う運用コマンド

```powershell
# タスク登録 / スケジュール変更後の再登録（冪等）
cd scripts; .\deploy-task.ps1

# 手動で今すぐ実行（隠しウィンドウ。完了は logs/ で確認、3〜5 分）
Start-ScheduledTask -TaskName Claude-Slack-Unfinished-Reminder

# 次回実行予定
Get-ScheduledTask -TaskName Claude-Slack-Unfinished-Reminder | Get-ScheduledTaskInfo

# ログ確認
Get-Content .\logs\last_run.log
Get-Content .\logs\last_output.log -Encoding utf8

# 登録解除
cd scripts; .\uninstall-task.ps1
```

タスク名は固定で `Claude-Slack-Unfinished-Reminder`。`last_run.log` が `done` で終わっていれば成功（対象＝停滞 0 件なら通知は送らない仕様）。`failed` なら `last_error.log` / `last_output.log` を見る。
