[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$NoNotify,
    [switch]$ForceNotify
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-Config {
    param([string]$Path)
    $cfg = @{}
    if (Test-Path -LiteralPath $Path) {
        $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    }
    if ($env:NTFY_SERVER_URL) { $cfg.ServerUrl = $env:NTFY_SERVER_URL }
    if ($env:NTFY_TOPIC) { $cfg.Topic = $env:NTFY_TOPIC }
    if ($env:NTFY_TOKEN) { $cfg.Token = $env:NTFY_TOKEN }
    if (-not $cfg.ContainsKey('ServerUrl')) { $cfg.ServerUrl = 'https://ntfy.sh' }
    if (-not $cfg.ContainsKey('Topic')) { $cfg.Topic = '' }
    if (-not $cfg.ContainsKey('Token')) { $cfg.Token = '' }
    if (-not $cfg.ContainsKey('LogDirectory')) { $cfg.LogDirectory = 'data\logs' }
    if (-not $cfg.ContainsKey('StateFile')) { $cfg.StateFile = 'data\state.json' }
    if (-not $cfg.ContainsKey('LogMaxBytes')) { $cfg.LogMaxBytes = 1048576 }
    if (-not $cfg.ContainsKey('LogGenerations')) { $cfg.LogGenerations = 5 }
    return $cfg
}

function Resolve-AppPath { param([string]$Path) if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $PSScriptRoot $Path } }

$script:Config = Get-Config $ConfigPath
$script:LogDir = Resolve-AppPath ([string]$script:Config.LogDirectory)
$script:LogFile = Join-Path $script:LogDir 'monitor.log'
$script:StateFile = Resolve-AppPath ([string]$script:Config.StateFile)

function Rotate-Log {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -ge [long]$script:Config.LogMaxBytes)) {
        $gens = [Math]::Max(1, [int]$script:Config.LogGenerations)
        for ($i = $gens - 1; $i -ge 1; $i--) {
            $old = "$($script:LogFile).$i"; $new = "$($script:LogFile).$($i + 1)"
            if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old -Destination $new -Force }
        }
        Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
    }
}
function Write-Log { param([string]$Level, [string]$Message) Rotate-Log; Add-Content -LiteralPath $script:LogFile -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ssK') [$Level] $Message" }
function Try-Read { param([scriptblock]$Action, [string]$Name) try { & $Action } catch { Write-Log 'WARN' "$Name の取得に失敗: $($_.Exception.Message)"; $null } }

function ConvertTo-Rfc2047Header {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return '=?UTF-8?B?' + [Convert]::ToBase64String($bytes) + '?='
}

function Get-RebootState {
    $reasons = [Collections.Generic.List[string]]::new()
    $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if ($wu) { $reasons.Add('Windows Update が再起動を要求') }
    $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if ($cbs) { $reasons.Add('コンポーネント処理が再起動を要求') }
    $pfr = Try-Read { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations } '保留中ファイル操作'
    if ($null -ne $pfr -and @($pfr).Count -gt 0) { $reasons.Add('保留中のファイル操作あり') }
    [pscustomobject]@{ Required = ($reasons.Count -gt 0); Reasons = @($reasons) }
}

function Convert-ToDateTimeOffsetOrNull {
    param($Value)
    if ($null -eq $Value) { return $null }
    try {
        if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
        if ($Value -is [long] -or $Value -is [int64]) { return [DateTimeOffset]::FromFileTime([long]$Value) }
        return [DateTimeOffset]::Parse([string]$Value)
    } catch { return $null }
}

function Get-ScheduledRestart {
    $candidates = [Collections.Generic.List[object]]::new()
    $ux = Try-Read { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction Stop } 'UX 設定'
    if ($ux) {
        foreach ($name in @('ScheduledRebootTime','ScheduledInstallTime','RestartNotificationsAllowed2')) {
            if ($ux.PSObject.Properties.Name -contains $name) {
                $dt = Convert-ToDateTimeOffsetOrNull $ux.$name
                if ($dt) { $candidates.Add([pscustomobject]@{ Time=$dt; Source="Registry:$name" }) }
            }
        }
    }
    Try-Read {
        $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
        $folder = $svc.GetFolder('\Microsoft\Windows\UpdateOrchestrator')
        foreach ($task in @($folder.GetTasks(1))) {
            if ($task.Enabled -and $task.NextRunTime -and ([datetime]$task.NextRunTime -gt (Get-Date))) {
                # Task names are identifiers, not localized display text. Prefer restart-related orchestrator tasks.
                if ($task.Name -match '(?i)reboot|restart|schedule|install') {
                    $candidates.Add([pscustomobject]@{ Time=[DateTimeOffset]([datetime]$task.NextRunTime); Source="Task:$($task.Name)" })
                }
            }
        }
    } 'UpdateOrchestrator タスク' | Out-Null
    return @($candidates | Sort-Object Time)
}

function Get-UpdateSummary {
    $result = [ordered]@{ PendingCount=$null; DownloadedCount=$null; Status='取得不能' }
    Try-Read {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher(); $searcher.Online = $false
        $found = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $result.PendingCount = $found.Updates.Count
        $downloaded = 0; foreach ($u in @($found.Updates)) { if ($u.IsDownloaded) { $downloaded++ } }
        $result.DownloadedCount = $downloaded
        $result.Status = if ($found.Updates.Count -eq 0) { '保留中の更新なし' } else { "未インストール $($found.Updates.Count) 件（ダウンロード済み $downloaded 件）" }
    } 'Windows Update COM API' | Out-Null
    [pscustomobject]$result
}

function Send-Ntfy {
    param([string]$Title, [string]$Message, [string]$Tags = 'computer,warning')
    if ($NoNotify) { Write-Log 'INFO' "通知抑止(NoNotify): $Title / $($Message -replace "`r?`n", ' | ')"; return $false }
    if ([string]::IsNullOrWhiteSpace([string]$script:Config.Topic)) { Write-Log 'WARN' 'ntfy Topic が未設定のため通知しません'; return $false }
    $uri = ([string]$script:Config.ServerUrl).TrimEnd('/') + '/' + [uri]::EscapeDataString([string]$script:Config.Topic)
    # Windows PowerShell 5.1 can corrupt non-ASCII HTTP header values.
    # ntfy accepts RFC 2047 encoded headers, so encode the Japanese title explicitly.
    $headers = @{ Title=(ConvertTo-Rfc2047Header $Title); Tags=$Tags; Priority='high' }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:Config.Token)) { $headers.Authorization = "Bearer $($script:Config.Token)" }
    try { Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($Message)) -ContentType 'text/plain; charset=utf-8' -TimeoutSec 20 | Out-Null; Write-Log 'INFO' 'ntfy 通知を送信しました'; return $true }
    catch { Write-Log 'ERROR' "ntfy 送信失敗（監視結果には影響しません）: $($_.Exception.Message)"; return $false }
}

$mutex = [Threading.Mutex]::new($false, 'Local\WindowsUpdateNtfyMonitor')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    Write-Log 'INFO' 'Windows Update 状態確認を開始'
    $reboot = Get-RebootState
    $scheduled = @(Get-ScheduledRestart)
    $next = if ($scheduled.Count -gt 0) { $scheduled[0] } else { $null }
    $updates = Get-UpdateSummary
    $detected = [DateTimeOffset]::Now
    $scheduleIso = if ($next) { $next.Time.ToString('o') } else { $null }
    $statusKey = "reboot=$($reboot.Required);reasons=$($reboot.Reasons -join ',');schedule=$scheduleIso;updates=$($updates.PendingCount);downloaded=$($updates.DownloadedCount)"
    $state = $null
    if (Test-Path -LiteralPath $script:StateFile) { try { $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Log 'WARN' "状態ファイルを読めません: $($_.Exception.Message)" } }
    $hasAction = $reboot.Required -or ($null -ne $next)
    $lastNotifiedKey = if ($state -and ($state.PSObject.Properties.Name -contains 'LastNotifiedStatusKey')) { $state.LastNotifiedStatusKey } elseif ($state -and ($state.PSObject.Properties.Name -contains 'StatusKey')) { $state.StatusKey } else { $null }
    $kind = $null
    if ($hasAction -and ($ForceNotify -or $lastNotifiedKey -ne $statusKey)) { $kind = 'change' }
    if ($hasAction -and $next -and -not $kind) {
        $hours = ($next.Time - $detected).TotalHours
        if ($hours -ge 0 -and $hours -le 1 -and -not $state.Reminded1h) { $kind='1h' }
        elseif ($hours -gt 1 -and $hours -le 24 -and -not $state.Reminded24h) { $kind='24h' }
    }
    if ($kind) {
        $when = if ($next) { $next.Time.LocalDateTime.ToString('yyyy年M月d日 HH:mm') + "（$($next.Source)）" } else { '予定日時は取得できませんでした' }
        $need = if ($reboot.Required) { '再起動が必要です' } else { '更新または自動再起動の予定を検出しました' }
        $message = "PC名: $env:COMPUTERNAME`n検出日時: $($detected.LocalDateTime.ToString('yyyy年M月d日 HH:mm'))`n状態: $need`n予定日時: $when`nWindows Update: $($updates.Status)"
        if ($reboot.Reasons.Count -gt 0) { $message += "`n根拠: $($reboot.Reasons -join '、')" }
        $title = if ($kind -eq '1h') { 'Windows Update: 1時間前リマインド' } elseif ($kind -eq '24h') { 'Windows Update: 24時間前リマインド' } else { 'Windows Update の予定・再起動要求' }
        $sent = Send-Ntfy $title $message
    }
    $sameSchedule = $state -and $state.Schedule -eq $scheduleIso
    $newState = [ordered]@{
        LastObservedStatusKey=$statusKey
        LastNotifiedStatusKey=if ($kind -and $sent) { $statusKey } else { $lastNotifiedKey }
        Schedule=$scheduleIso; LastChecked=$detected.ToString('o')
        LastNotificationKind=if ($kind -and $sent) { $kind } elseif ($state -and ($state.PSObject.Properties.Name -contains 'LastNotificationKind')) { $state.LastNotificationKind } else { $null }
        Reminded24h=if ($kind -eq '24h' -and $sent) { $true } elseif ($sameSchedule -and $state -and ($state.PSObject.Properties.Name -contains 'Reminded24h')) { [bool]$state.Reminded24h } else { $false }
        Reminded1h=if ($kind -eq '1h' -and $sent) { $true } elseif ($sameSchedule -and $state -and ($state.PSObject.Properties.Name -contains 'Reminded1h')) { [bool]$state.Reminded1h } else { $false }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $script:StateFile) -Force | Out-Null
    $newState | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
    Write-Log 'INFO' "確認完了: reboot=$($reboot.Required), schedule=$scheduleIso, update=$($updates.Status), notification=$kind"
    [pscustomobject]@{ RebootRequired=$reboot.Required; Reasons=$reboot.Reasons; ScheduledTime=$scheduleIso; ScheduleSource=if($next){$next.Source}else{$null}; UpdateStatus=$updates.Status; NotificationDecision=$kind; NotificationSuppressed=[bool]$NoNotify }
} catch { Write-Log 'ERROR' "予期しないエラー: $($_.Exception.Message)"; throw }
finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
