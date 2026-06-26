# Kintone チケットリマインダー - タスク削除スクリプト

$ErrorActionPreference = 'Stop'
$taskName = 'Claude-Kintone-Reminder'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[OK] Task removed: $taskName"
} else {
    Write-Host "[INFO] Task not found (already removed?): $taskName"
}
