[CmdletBinding()]
param([string]$TaskName = 'WindowsUpdateNtfyMonitor')
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'PC起動時トリガーの登録には管理者として PowerShell を実行してください。' }
$monitor = Join-Path $PSScriptRoot 'Check-WindowsUpdateSchedule.ps1'
if (-not (Test-Path -LiteralPath $monitor)) { throw "監視スクリプトがありません: $monitor" }
$config = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path -LiteralPath $config)) { throw 'config.sample.json を config.json にコピーして設定してから実行してください。' }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monitor`" -ConfigPath `"$config`""
$action = New-ScheduledTaskAction -Execute $psExe -Argument $arguments -WorkingDirectory $PSScriptRoot
$hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 1)
$startup = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($hourly,$startup) -Settings $settings -Principal $taskPrincipal -Description 'Windows Update の再起動要求・予定を監視し ntfy へ通知します。' -Force | Out-Null
Write-Host "タスク '$TaskName' を登録しました。1時間ごと、およびPC起動時に非表示で実行されます。"
