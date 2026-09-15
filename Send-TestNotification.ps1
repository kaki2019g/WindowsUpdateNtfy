[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'))
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'config.json がありません。config.sample.json をコピーして設定してください。' }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$server = if ($env:NTFY_SERVER_URL) { $env:NTFY_SERVER_URL } else { $cfg.ServerUrl }
$topic = if ($env:NTFY_TOPIC) { $env:NTFY_TOPIC } else { $cfg.Topic }
$token = if ($env:NTFY_TOKEN) { $env:NTFY_TOKEN } else { $cfg.Token }
if ([string]::IsNullOrWhiteSpace($topic) -or $topic -like '*ここに*') { throw 'ntfy の Topic を設定してください。' }
$titleBytes = [Text.Encoding]::UTF8.GetBytes('Windows Update 監視テスト')
$encodedTitle = '=?UTF-8?B?' + [Convert]::ToBase64String($titleBytes) + '?='
$headers = @{ Title=$encodedTitle; Tags='computer,white_check_mark'; Priority='default' }
if (-not [string]::IsNullOrWhiteSpace($token)) { $headers.Authorization = "Bearer $token" }
$uri = ([string]$server).TrimEnd('/') + '/' + [uri]::EscapeDataString([string]$topic)
$body = "PC名: $env:COMPUTERNAME`n送信日時: $(Get-Date -Format 'yyyy年M月d日 HH:mm:ss')`nWindows Update 監視のテスト通知です。"
Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'text/plain; charset=utf-8' -TimeoutSec 20 | Out-Null
Write-Host 'ntfy へテスト通知を送信しました。'
