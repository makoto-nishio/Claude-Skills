# Slack 未返信投稿リマインダー - Task Scheduler デプロイスクリプト
# config.yaml の schedule セクション（daily または interval）を読み、
# Windows Task Scheduler に登録する。既存タスクがあれば上書き更新。

$ErrorActionPreference = 'Stop'
# このスクリプトは scripts/ にいる。config.yaml は skill ルート、その他のスクリプトは同じ scripts/
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillDir    = Split-Path -Parent $scriptDir
$configPath  = Join-Path $skillDir   'config.yaml'
$runScript   = Join-Path $scriptDir  'run-reminder.ps1'
$launcherVbs = Join-Path $scriptDir  'launcher.vbs'
$taskName    = 'Claude-Slack-Unfinished-Reminder'

if (-not (Test-Path $configPath))  { Write-Error "config.yaml not found: $configPath"; exit 1 }
if (-not (Test-Path $runScript))   { Write-Error "run-reminder.ps1 not found: $runScript"; exit 1 }
if (-not (Test-Path $launcherVbs)) { Write-Error "launcher.vbs not found: $launcherVbs"; exit 1 }

# --- schedule セクションをパース（コメント行は無視） ---
# 構造を行単位で歩いて、daily / interval のうち有効化されている方を読む。
$lines = Get-Content $configPath
$inSchedule = $false
$currentSubsection = $null   # 'daily' | 'interval' | $null
$dailyEnabled = $false
$intervalEnabled = $false
$dailyParams = @{}
$intervalParams = @{}

foreach ($raw in $lines) {
    # コメント / 空行は完全無視
    $trim = $raw.TrimStart()
    if ($trim.StartsWith('#') -or [string]::IsNullOrWhiteSpace($trim)) { continue }

    # トップレベルキー（インデント無し）
    if ($raw -match '^[a-zA-Z_]') {
        if ($raw -match '^schedule:\s*$') {
            $inSchedule = $true
            $currentSubsection = $null
        } else {
            $inSchedule = $false
        }
        continue
    }
    if (-not $inSchedule) { continue }

    # 2 スペースインデント: daily: / interval:
    if ($raw -match '^\s{2}(daily|interval):\s*$') {
        $currentSubsection = $Matches[1]
        if ($currentSubsection -eq 'daily')    { $dailyEnabled = $true }
        if ($currentSubsection -eq 'interval') { $intervalEnabled = $true }
        continue
    }

    # 4 スペースインデント: サブキー（time / weekdays_only / hours / between など）
    if ($raw -match '^\s{4}(\w+):\s*"?([^"#]*?)"?\s*(#.*)?$') {
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        if ($currentSubsection -eq 'daily')    { $dailyParams[$key] = $val }
        if ($currentSubsection -eq 'interval') { $intervalParams[$key] = $val }
        continue
    }

    # 6 スペースインデント: ネストキー（interval.between.start / interval.between.end）
    if ($raw -match '^\s{6}(\w+):\s*"?([^"#]*?)"?\s*(#.*)?$') {
        $key = $Matches[1]
        $val = $Matches[2].Trim()
        # 簡易対応: interval.between のみ扱う
        if ($currentSubsection -eq 'interval') {
            $intervalParams["between.$key"] = $val
        }
    }
}

# --- バリデーション ---
if ($dailyEnabled -and $intervalEnabled) {
    Write-Error "schedule に 'daily' と 'interval' の両方が有効になっています。片方のみコメント解除してください。"
    exit 1
}
if (-not $dailyEnabled -and -not $intervalEnabled) {
    Write-Error "schedule に 'daily' または 'interval' のいずれかを有効化してください。"
    exit 1
}

# --- Trigger 構築 ---
if ($dailyEnabled) {
    $time = $dailyParams['time']
    if (-not $time -or $time -notmatch '^\d{1,2}:\d{2}$') {
        Write-Error "schedule.daily.time は HH:MM 形式で指定してください（現在の値: '$time'）"; exit 1
    }
    $weekdaysOnly = ($dailyParams['weekdays_only'] -eq 'true')

    if ($weekdaysOnly) {
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $time
    } else {
        $trigger = New-ScheduledTaskTrigger -Daily -At $time
    }
    $scheduleDesc = "daily $time" + $(if ($weekdaysOnly) { ' (weekdays only)' } else { '' })
}
else {
    # interval は minutes か hours のどちらかで指定する（minutes 優先）。Task Scheduler 上の最小は 1 分。
    $minutes = 0
    $hours = 0
    if ($intervalParams.ContainsKey('minutes') -and $intervalParams['minutes'] -ne '') {
        if (-not [int]::TryParse($intervalParams['minutes'], [ref]$minutes) -or $minutes -lt 1) {
            Write-Error "schedule.interval.minutes は 1 以上の整数で指定してください（現在の値: '$($intervalParams['minutes'])'）"; exit 1
        }
        $interval = New-TimeSpan -Minutes $minutes
        $intervalLabel = "$minutes minute(s)"
    } else {
        if (-not [int]::TryParse($intervalParams['hours'], [ref]$hours) -or $hours -lt 1) {
            Write-Error "schedule.interval には minutes または hours（1 以上の整数）を指定してください（hours の現在の値: '$($intervalParams['hours'])'）"; exit 1
        }
        $interval = New-TimeSpan -Hours $hours
        $intervalLabel = "$hours hour(s)"
    }
    $weekdaysOnly = ($intervalParams['weekdays_only'] -eq 'true')

    $betweenStart = $intervalParams['between.start']
    $betweenEnd   = $intervalParams['between.end']
    $hasBetween   = $betweenStart -and $betweenEnd
    if (($betweenStart -or $betweenEnd) -and -not $hasBetween) {
        Write-Error "schedule.interval.between は start と end の両方を指定してください。"; exit 1
    }
    if ($hasBetween) {
        if ($betweenStart -notmatch '^\d{1,2}:\d{2}$' -or $betweenEnd -notmatch '^\d{1,2}:\d{2}$') {
            Write-Error "schedule.interval.between.start / end は HH:MM 形式で指定してください。"; exit 1
        }
    }

    if ($hasBetween) {
        # 時間帯指定あり: 開始は start、duration は end-start
        $startAt = [datetime]::Today.Add([timespan]$betweenStart)
        $endAt   = [datetime]::Today.Add([timespan]$betweenEnd)
        if ($endAt -le $startAt) {
            Write-Error "schedule.interval.between.end は start より後の時刻にしてください。"; exit 1
        }
        $windowDuration = $endAt - $startAt

        if ($weekdaysOnly) {
            $repTemplate = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval $interval -RepetitionDuration $windowDuration
            $trigger     = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $startAt
            $trigger.Repetition = $repTemplate.Repetition
            $scheduleDesc = "every $intervalLabel, weekdays $betweenStart-$betweenEnd"
        } else {
            $trigger = New-ScheduledTaskTrigger -Daily -At $startAt
            $repTemplate = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval $interval -RepetitionDuration $windowDuration
            $trigger.Repetition = $repTemplate.Repetition
            $scheduleDesc = "every $intervalLabel, daily $betweenStart-$betweenEnd"
        }
    }
    else {
        # 時間帯指定なし: 1 分後から開始、24h（weekdays_only=true）または永久（false）に循環
        $startAt = (Get-Date).AddMinutes(1)
        if ($weekdaysOnly) {
            $repTemplate = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval $interval -RepetitionDuration (New-TimeSpan -Hours 24)
            $trigger     = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At $startAt
            $trigger.Repetition = $repTemplate.Repetition
            $scheduleDesc = "every $intervalLabel, weekdays only, starting $($startAt.ToString('yyyy-MM-dd HH:mm:ss'))"
        } else {
            $duration = New-TimeSpan -Days 9999
            $trigger  = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval $interval -RepetitionDuration $duration
            $scheduleDesc = "every $intervalLabel, starting $($startAt.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
    }
}

Write-Host "Schedule: $scheduleDesc"

# --- Action / Settings / Principal ---
# wscript.exe + launcher.vbs 経由で起動する。
# wscript はコンソールを作らないため、powershell.exe 起動時の黒窓フラッシュを完全に防げる。
# launcher.vbs が PowerShell の終了を待ち、exit code をそのまま wscript の戻り値として伝播する。
$action = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument "`"$launcherVbs`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# --- 既存タスクを削除してから登録（冪等） ---
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task: $taskName"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $taskName `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Description 'Slack #mall_support_corefunction の未返信投稿を自動チェックし、コア機能チームへリマインダーを送信する。設定は config.yaml の schedule セクション（daily または interval）を参照。' | Out-Null

Write-Host ''
Write-Host "[OK] Task registered: $taskName"
Write-Host "     Schedule  : $scheduleDesc"
Write-Host "     Runs as   : $env:USERNAME (interactive)"
Write-Host ''
Write-Host '次回実行予定を確認するには:'
Write-Host "  Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo"
Write-Host ''
Write-Host '手動で今すぐテスト実行するには:'
Write-Host "  Start-ScheduledTask -TaskName $taskName"
