' Hidden launcher for run-reminder.ps1
' Task Scheduler から呼び出される。wscript.exe は console を作らないため、
' powershell.exe 起動時の黒窓フラッシュを防げる。
'
' Run のパラメータ:
'   0    = SW_HIDE (window completely hidden)
'   True = wait until PowerShell finishes, propagate exit code

Option Explicit

Dim fso, shell, scriptDir, cmd, exitCode

Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\run-reminder.ps1"""

exitCode = shell.Run(cmd, 0, True)
WScript.Quit(exitCode)
