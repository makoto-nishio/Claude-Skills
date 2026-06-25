# Slack 未返信投稿リマインダー - タスク削除スクリプト

$ErrorActionPreference = 'Stop'
$taskName = 'Claude-Slack-Unfinished-Reminder'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[OK] Task removed: $taskName"
} else {
    Write-Host "[INFO] Task not found (already removed?): $taskName"
}
