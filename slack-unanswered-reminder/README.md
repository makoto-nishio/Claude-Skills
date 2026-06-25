# Slack 未返信投稿リマインダー

Slack の QA List で「完了が未チェックかつチームメンバーが誰も返信していない項目」を毎日（または指定間隔で）自動チェックし、別チャンネルへリマインダーを送信する Claude Code skill です。

各項目の `メッセージリンク` から元スレッドを辿り、チームが未返信のものだけをリマインドします。

Windows Task Scheduler から PowerShell スクリプト経由で Claude Code CLI を起動し、skill を実行します。

> **このリポジトリは複数チームでの横展開を前提にしています。** 業務ロジックは `SKILL.md`（日本語の手順書）に書かれており、コードの改修なしに `config.yaml` を書き換えるだけで自チーム向けに運用できます。

## こんなチームに

- Slack の QA / 問い合わせ List を運用していて、「対応漏れ（誰も返信していない案件）」を定期的に拾いたい
- 毎朝・定時に「未対応リスト」を担当者別にまとめて通知したい
- 監視のためだけに人手を割きたくない（PC がログオンしていれば全自動）

## 30 秒で全体像

1. `config.yaml` に「監視する List 名 / 通知先チャンネル / チームメンバー / 実行スケジュール」を書く
2. `scripts\deploy-task.ps1` を 1 回実行 → Windows Task Scheduler にタスク登録
3. 以降は指定スケジュールで全自動。未返信が 0 件なら通知は送らない

> はじめての方は **[初期セットアップ](#初期セットアップ)** → **[デプロイ](#デプロイtask-scheduler-に登録)** → **[動作確認](#動作確認)** の順で進めてください。
> 非技術者向けの紹介は [`docs/overview.md`](docs/overview.md) を参照。

---

## ディレクトリ構成

```
slack-unanswered-reminder/
├── README.md              # 本ファイル（運用ガイド）
├── SKILL.md               # Claude Code 用の skill 定義
├── config.yaml            # 監視対象・スケジュール・チームメンバー設定
├── docs/                  # 追加ドキュメント
│   └── overview.md             # 全社向け紹介資料（非技術者向け。何ができるか・導入・使い方）
├── scripts/               # 自動化スクリプト
│   ├── run-reminder.ps1   # Task Scheduler から呼ばれる実行スクリプト
│   ├── deploy-task.ps1    # Task Scheduler にタスクを登録
│   ├── uninstall-task.ps1 # 登録済みタスクを削除
│   └── launcher.vbs       # 黒窓フラッシュ抑止用の wscript ラッパ
└── logs/                  # 実行ログ（実行時に自動生成）
    ├── last_run.log       # 実行開始 / 終了の記録
    ├── last_error.log     # エラー詳細
    └── last_output.log    # claude.exe の全出力（デバッグ用）
```

---

## 関連ドキュメント

| ドキュメント | 場所 | 内容 |
|------------|------|------|
| **本 README** | 本ファイル | skill 全体の運用ガイド（業務ロジック・スケジュール・ログ・トラブルシューティング） |
| [`docs/overview.md`](docs/overview.md) | このリポジトリ | 全社向け紹介資料（非技術者向け。何ができるか・導入の流れ・日々の使い方・FAQ） |

> **通知の送信方式について**: この skill は専用の Slack App を持ちません。通知は、実行 PC で認証済みの **Slack MCP コネクター（claude.ai）の本人アカウント**から送信されます（つまり「設定した人の名前」で投稿されます）。発信元を変えたい場合は MCP コネクター側の再認証が必要です。詳細は `SKILL.md` の「通知の発信元アカウントについて」を参照。

---

## 前提条件

| 項目 | 内容 |
|------|------|
| OS | Windows 10 / 11 |
| PowerShell | Windows PowerShell 5.1（標準搭載）または PowerShell 7+ |
| Claude Code CLI | `claude` コマンドが PATH 上にあること（`Get-Command claude` で確認） |
| Slack MCP | claude.ai 側で Slack コネクターを認証済み（https://claude.ai/customize/connectors） |
| 動作タイミング | PC がログオン中の時間帯にしかタスクは走らない |

> ⚠️ **横展開で最初に詰まるポイント: Slack MCP の名前空間**
> Slack MCP ツールの名前空間は環境によって異なります（例: `mcp__plugin_slack_slack__*` と `mcp__claude_ai_Slack__*`）。**無人実行で使われる名前空間が `run-reminder.ps1` の `--allowedTools` に入っていないと、全 API 呼び出しが「権限未付与」で拒否され、何も実行できないまま正常終了します。**
> 自分の環境で接続中の Slack サーバ名を確認するには:
> ```powershell
> claude mcp list
> ```
> `... slack ... ✔ Connected` と出るサーバ名（`plugin:slack:slack` → `mcp__plugin_slack_slack__`、`claude.ai Slack` → `mcp__claude_ai_Slack__`）が、`run-reminder.ps1` の許可リストに含まれているか確認してください。**本リポジトリは主要 2 種を両方許可済み**ですが、これら以外の名前空間の環境では追記が必要です。詳細は[トラブルシューティング](#slack-mcp-の権限拒否で何も実行されないが-done-になる横展開で頻出)を参照。

---

## 初期セットアップ

### 1. `config.yaml` を編集

エディタで `config.yaml` を開き、自分の環境に合わせて値を変更します。

```yaml
# 監視対象の Slack List 名（1 つ。実行時にこの名前から File ID を解決する）
list_name: "コア機能チームQAリスト"

# 通知先チャンネル ID または User ID（DM の場合）
notification_channel: C0XXXXXXXXX

# 実行スケジュール（daily または interval のどちらか一方を有効化）
schedule:
  # 方式1: 毎日 / 平日のみ、特定時刻
  daily:
    time: "13:00"
    weekdays_only: true

  # 方式2: 一定間隔ごと（minutes または hours。minutes 優先・最小 1 分）
  # interval:
  #   minutes: 30                # 分単位（短間隔・テスト向け）
  #   hours: 1                   # 時間単位（minutes と併記時は minutes 優先）
  #   weekdays_only: true        # オプション
  #   between:                   # オプション
  #     start: "09:00"
  #     end: "18:00"

# チームメンバー（このメンバーが誰も返信していない項目だけが通知対象）
# 各要素は「User ID」または「email」のどちらでもよい（混在可）。
#   - email は実行時に Slack 上で User ID へ自動解決される
#   - 解決できない / 複数該当の email は無視される（無人モードのため推測しない）
# 返信者の判定は最終的に必ず User ID で行うため、email でも判定精度は同じ。
team_members:
  - U0XXXXXXX                    # User ID で指定
  - taro.yamada@example.com      # email で指定（自動で User ID へ解決）
```

#### List 名の調べ方
Slack で対象の List を開き、画面上部のタイトルをそのまま `list_name` に設定する（完全一致で検索されるため、表記揺れに注意）。同名の List が複数あると解決に失敗するため、一意な名前にしておく。

#### チャンネル ID の調べ方（`notification_channel` 用）
Slack デスクトップアプリでチャンネル名を右クリック → 「リンクをコピー」→ URL 末尾の `C0XXXXXXXXX` がチャンネル ID。

#### User ID の調べ方
Slack デスクトップアプリでユーザーの三点メニュー → 「メンバー ID をコピー」→ `U0XXXXXXX` 形式。

> **email でも指定できます。** User ID を調べるのが面倒な場合は、`team_members` に会社の email（例: `taro.yamada@example.com`）をそのまま書けば、実行時に自動で User ID へ解決されます。可読性が高く、List の「担当者」列（email）とも揃うのでおすすめです。

### 2. スケジュールモードを選ぶ

| モード | 用途 | 例 |
|-------|------|-----|
| `daily.time` + `weekdays_only: true` | 毎営業日の固定時刻 | 平日 13:00 |
| `daily.time` + `weekdays_only: false` | 毎日固定時刻 | 毎日 09:00 |
| `interval.minutes: 30` | N 分ごとに繰り返し（短間隔・テスト向け） | 30 分ごと |
| `interval.hours: 1` | N 時間ごとに繰り返し | 毎時 |
| `interval` + `weekdays_only: true` | 平日のみ N 時間/分ごと | 平日のみ毎時 |
| `interval` + `between` | 一日の時間帯内で N 時間/分ごと | 09:00-18:00 で毎時 |

> `interval` で `minutes` と `hours` を両方書いた場合は **`minutes` が優先**されます。本番運用は通常 `daily` または `hours` を使い、`minutes` は動作テスト時の短間隔向けです。

使わない方は **行頭に `#`** を付けてコメントアウトしてください。両方有効だとデプロイ時にエラーになります。

---

## デプロイ（Task Scheduler に登録）

PowerShell を開き、次を実行します。

```powershell
cd C:\Users\<USER>\.claude\skills\slack-unanswered-reminder\scripts
.\deploy-task.ps1
```

成功すれば次のように出力されます。

```
Schedule: every 1 hour(s), starting 2026-05-28 16:06:10

[OK] Task registered: Claude-Slack-Unanswered-Reminder
     Schedule  : every 1 hour(s), starting 2026-05-28 16:06:10
     Runs as   : wzhang083 (interactive)
```

`config.yaml` のスケジュールを変更したあとは、**同じコマンドをもう一度実行**するだけで上書き更新されます（冪等）。

### デプロイ時に作られるタスクの仕様

| 項目 | 値 |
|------|-----|
| タスク名 | `Claude-Slack-Unanswered-Reminder` |
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
Start-ScheduledTask -TaskName Claude-Slack-Unanswered-Reminder
```

実行は完全に隠しウィンドウで走るため、画面には何も表示されません。完了は `logs/` で確認します（3〜5 分程度かかります）。

### 次回実行予定の確認

```powershell
Get-ScheduledTask -TaskName Claude-Slack-Unanswered-Reminder | Get-ScheduledTaskInfo
```

### ログを見る

| ファイル | 中身 |
|---------|------|
| `logs\last_run.log` | `start` / `done` / `failed` の記録 |
| `logs\last_error.log` | エラーの内容（成功時は作成されない） |
| `logs\last_output.log` | claude.exe の出力全文（送信メッセージリンク等もここに残る） |

```powershell
Get-Content .\logs\last_run.log
Get-Content .\logs\last_output.log -Encoding utf8
```

---

## スケジュール変更

1. `config.yaml` の `schedule` セクションを編集（使う方の `#` を外し、使わない方をコメントアウト）
2. `scripts\deploy-task.ps1` を再実行

スクリプト本体は変更不要です。タスクは上書き登録されます。

---

## 削除（タスク解除）

```powershell
cd C:\Users\<USER>\.claude\skills\slack-unanswered-reminder\scripts
.\uninstall-task.ps1
```

タスクが削除されるだけで、skill ファイル本体や `logs/` は残ります。完全に消したい場合は skill ディレクトリごと削除してください。

---

## トラブルシューティング

### Slack MCP の権限拒否で何も実行されないが done になる（横展開で頻出）
- **症状**: `last_run.log` は `done`、`LastTaskResult` は `0` なのに、通知が一切来ない。`last_output.log` に「権限未付与」「実行権限が付与されておらず」「権限ブロックにより未実行」などの記述がある
- **原因**: 無人実行（`claude --print`）で使われる Slack MCP の名前空間が、`run-reminder.ps1` の `--allowedTools` に含まれていない。許可外のツールは権限プロンプトになり、無人モードでは自動的に拒否される
- **確認**: `claude mcp list` を実行し、`✔ Connected` の Slack サーバ名を確認する
  - `plugin:slack:slack` → ツール名は `mcp__plugin_slack_slack__*`
  - `claude.ai Slack` → ツール名は `mcp__claude_ai_Slack__*`
- **対処**: `scripts\run-reminder.ps1` の `$allowedTools` に、その名前空間の Slack ツール一式（`slack_search_public` / `slack_read_file` / `slack_read_thread` / `slack_read_channel` / `slack_send_message` / `slack_read_user_profile` / `slack_search_users`）が含まれているか確認し、無ければ追記する。**本リポジトリは `mcp__plugin_slack_slack__*` と `mcp__claude_ai_Slack__*` の両方を既定で許可済み**
- **補足**: この skill には「no-op 検知」が入っており、上記キーワードを出力に検出すると、exit 0 でも `last_run.log` を `failed (no-op suspected)` と記録し `last_error.log` に残します。`done` のはずが `failed (no-op suspected)` になっていたらこのケースです

### 「実行されたはずなのに通知が来ない」
1. `logs\last_run.log` の最終行を確認
   - `done` で終わっていれば、未返信が 0 件で通知が省略されただけ
   - `failed (no-op suspected)` なら、上記「Slack MCP の権限拒否」を参照
   - `failed (exit ...)` なら `last_error.log` と `last_output.log` を確認
2. `logs\last_output.log` を開いて claude.exe の最終応答を確認
3. Slack MCP の認証切れの場合、claude.ai でリンクしなおす

### Slack MCP の認証が切れた
- 症状: `last_error.log` に「Slack MCP authentication required」相当のエントリが連日追加される
- 対処: ブラウザで https://claude.ai/customize/connectors を開き、Slack を再認証

### PC がログオフ / 休止中だった
- 本タスクは「ユーザーがログオンしているときのみ実行」なので、ログオフ中は走りません
- スリープから復帰した場合は、`StartWhenAvailable` 設定により次回起動可能なタイミングで補完実行されます

### `claude command not found` エラー
- `Get-Command claude` で確認
- PATH に含まれていなければ、`scripts\run-reminder.ps1` の `$candidates` リストに claude.exe のフルパスを追記

### `.ps1` ファイルを編集したら動かなくなった
- 編集ツールが UTF-8 BOM を削った可能性あり。下記コマンドで BOM を付け直してください:
  ```powershell
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  Get-ChildItem .\scripts -Filter *.ps1 | ForEach-Object {
      $c = [System.IO.File]::ReadAllText($_.FullName)
      [System.IO.File]::WriteAllText($_.FullName, $c, $utf8Bom)
  }
  ```

### Task Scheduler の Event Log を直接見たい
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 30 |
    Where-Object { $_.Message -match 'Claude-Slack' } |
    Select-Object TimeCreated, Id, Message | Format-List
```

### タスクが「予期せぬ exit code」で失敗する
- `LastTaskResult` が `0` 以外なら、`logs\last_output.log` に claude.exe の生エラーが残っているはずです
- `2147942401` (= `0x80070001`) は典型的に **PowerShell が `.ps1` をパースできなかった** 兆候（BOM が外れているケースが多い）

---

## 設計メモ

- **無人実行モード**: SKILL.md 内で「Agent はユーザーに質問しない」「OAuth 再認証フローには入らない」「SKILL.md レビューや改善提案はしない」を明示している
- **権限**: `run-reminder.ps1` で `--allowedTools` に必要な Slack MCP ツールと Read/Write/Edit/Bash を列挙し、権限プロンプトを回避
- **MCP 名前空間の二重許可**: 対話セッションとヘッドレス（`claude --print`）で Slack MCP の名前空間が異なるため、`--allowedTools` に `mcp__plugin_slack_slack__*` と `mcp__claude_ai_Slack__*` の両方を列挙し、どちらが使われても止まらないようにしている
- **メンバー指定の柔軟性**: `team_members` は User ID と email を混在可。email は実行時に `slack_search_users` で User ID へ解決（完全一致 1 件のみ採用、0 件・複数件は無視）。**返信者の判定は必ず User ID で行う**（表示名では照合しない）
- **no-op 検知**: exit 0 でも出力に権限拒否・認証切れの兆候があれば `failed (no-op suspected)` として `exit 2` で記録し、「失敗を成功と誤認する」のを防ぐ
- **エンコーディング**: `.ps1` は UTF-8 BOM 付き、`launcher.vbs` は ANSI、ログ書き込みは `[Console]::OutputEncoding = UTF8` を強制
- **黒窓抑止**: Task Scheduler の Action を `wscript.exe launcher.vbs` にすることで、`powershell.exe` 起動時のコンソール一瞬表示を防止
