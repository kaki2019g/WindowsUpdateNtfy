[CmdletBinding(SupportsShouldProcess)]
param([string]$TaskName = 'WindowsUpdateNtfyMonitor')
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'タスク解除には管理者として PowerShell を実行してください。' }
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess($TaskName, 'タスクスケジューラから解除')) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "タスク '$TaskName' を解除しました。ログ、状態、設定ファイルは残しています。" }
} else { Write-Host "タスク '$TaskName' は登録されていません。" }
