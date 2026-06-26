# Kintone チケットリマインダー - 実行スクリプト
# Task Scheduler から（launcher.vbs 経由で）呼び出される。Claude Code CLI 経由で skill を実行する。
# 失敗時は last_error.log にエントリを追記する。

$ErrorActionPreference = 'Stop'
# claude.exe からの UTF-8 出力を正しく受け取るため、Console エンコーディングを UTF-8 に統一
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

# このスクリプトは scripts/ にいる。skill ルートは親、logs は ルート/logs/
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir  = Split-Path -Parent $scriptDir
$logDir    = Join-Path $skillDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logPath   = Join-Path $logDir 'last_error.log'
$runLog    = Join-Path $logDir 'last_run.log'

function Write-RunLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts - $Message" | Out-File -FilePath $runLog -Append -Encoding utf8
}

function Write-ErrorLog {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts - $Message" | Out-File -FilePath $logPath -Append -Encoding utf8
}

try {
    Write-RunLog 'start'

    # 環境変数チェック: Kintone 認証情報（MCP server が使用）。2 方式のどちらかが揃っていればOK。
    #   - APIトークン方式 : KINTONE_API_TOKEN
    #   - ID/パスワード方式: KINTONE_USERNAME + KINTONE_PASSWORD
    $hasToken    = [bool]$env:KINTONE_API_TOKEN
    $hasUserPass = ([bool]$env:KINTONE_USERNAME -and [bool]$env:KINTONE_PASSWORD)
    if (-not $hasToken -and -not $hasUserPass) {
        Write-ErrorLog 'No kintone credentials: set KINTONE_API_TOKEN, or KINTONE_USERNAME + KINTONE_PASSWORD'
        Write-RunLog 'failed (no kintone credentials)'
        exit 1
    }
    # APIトークン方式は接続先 URL も OS 環境変数 KINTONE_BASE_URL が必要。
    # ID/パスワード方式は接続先が .mcp.json 等に埋め込まれるため OS 環境変数は必須ではない
    # （チケット URL の base は config.yaml の kintone.domain で補える）。
    if ($hasToken -and -not $env:KINTONE_BASE_URL) {
        Write-ErrorLog 'KINTONE_API_TOKEN is set but KINTONE_BASE_URL is missing (token auth needs both)'
        Write-RunLog 'failed (no kintone base url)'
        exit 1
    }

    # claude.exe を探す
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        $candidates = @(
            "$env:APPDATA\npm\claude.cmd",
            "$env:APPDATA\npm\claude.ps1",
            "$env:LOCALAPPDATA\Programs\claude\claude.exe"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $claudeCmd = @{ Source = $c }; break }
        }
    }
    if (-not $claudeCmd) {
        Write-ErrorLog 'claude command not found in PATH or known locations'
        Write-RunLog 'failed (claude not found)'
        exit 1
    }

    Set-Location $skillDir

    # skill 実行を依頼するプロンプト
    # 重要: Agent が SKILL.md や config の整合性レビューに陥らず、主処理だけ確実に走るよう明示する
    $prompt = @'
kintone-unfinished-reminder skill の主処理を最後まで実行してください。

実行ステップ（順守）:
1. 作業ディレクトリの config.yaml を読み込む（kintone / slack / assignees / trackers / statuses）
2. SKILL.md の「実行ワークフロー」に従い、各トラッカーについて kintone から未対応チケットを取得（対象は config の trackers / statuses / assignees）
3. トラッカー別→担当者別に分類する
4. notification_channel（config の slack.channel_id）に親投稿（全員メンション＋件数サマリ）を送り、message_ts を控える
5. 各トラッカーの詳細を message_ts への thread 返信として送る（0 件のトラッカーは送らない）

絶対禁止事項:
- ユーザーへの質問（AskUserQuestion）
- OAuth 再認証フロー
- SKILL.md / config.yaml の整合性レビュー・改善提案・不一致報告
- 主処理を中断して報告のみ返す
- 部分的な実行で済ませる

SKILL.md の表現に多少の曖昧さがあっても、主処理（チケット取得と通知送信）を最後まで完遂してください。
レビューやコメントは一切不要。実行結果のみ簡潔に報告してください。
'@

    # 無人実行のため、本 skill が使う具体的なツールを許可リストで明示する（最小権限）。
    # 範囲は SKILL.md の手順内で必要なものに限定。
    $allowedTools = @(
        # Kintone MCP（レコード取得）
        'mcp__kintone__kintone-get-records'
        'mcp__kintone__kintone-get-app'
        # Slack MCP: 対話セッション側の名前空間
        'mcp__plugin_slack_slack__slack_send_message'
        'mcp__plugin_slack_slack__slack_search_users'
        # Slack MCP: ヘッドレス（claude --print）側の名前空間
        'mcp__claude_ai_Slack__slack_send_message'
        'mcp__claude_ai_Slack__slack_search_users'
        'Read'
        'Write'
        'Edit'
        'Bash'
    ) -join ','

    # 非対話モードで実行（プロンプトをパイプ経由、許可ツールを明示）
    $output = $prompt | & $claudeCmd.Source --print --permission-mode acceptEdits --allowedTools $allowedTools 2>&1
    $exitCode = $LASTEXITCODE

    # claude の output を全文記録（成功時もデバッグ用に保持）
    $outputLog = Join-Path $logDir 'last_output.log'
    "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (exit $exitCode) ===" | Out-File -FilePath $outputLog -Encoding utf8
    $output | Out-String | Out-File -FilePath $outputLog -Append -Encoding utf8

    if ($exitCode -ne 0) {
        Write-ErrorLog "claude exited with code $exitCode. See last_output.log for details."
        Write-RunLog "failed (exit $exitCode)"
        exit $exitCode
    }

    # exit 0 でも実質「何もできていない」場合がある（MCP 権限拒否・認証切れなど）。
    # claude が主処理を 1 ステップも実行できなかった兆候が出力にあれば、成功とみなさない。
    # 実例: Slack/Kintone MCP の名前空間不一致で全呼び出しが「権限未付与」となり、通知ゼロのまま正常終了した。
    $outputText = $output | Out-String
    $failureMarkers = @(
        '権限ブロック'
        '権限未付与'
        '権限が付与されて'
        '実行権限が'
        '未実行'
        '拒否されました'
        '認証切れ'
        '認証が切れ'
        '再認証'
        'OAuth'
    )
    $hits = @($failureMarkers | Where-Object { $outputText.Contains($_) })
    if ($hits.Count -gt 0) {
        Write-ErrorLog ("exit 0 but possible no-op (主処理未実行の疑い). markers: " + ($hits -join ', ') + ". See last_output.log.")
        Write-RunLog "failed (no-op suspected)"
        exit 2
    }

    Write-RunLog 'done'
}
catch {
    Write-ErrorLog "unhandled exception: $($_.Exception.Message)"
    Write-RunLog "failed (exception)"
    exit 1
}
