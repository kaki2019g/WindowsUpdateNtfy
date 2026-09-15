[CmdletBinding()]
param(
    [string]$Message,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:RepositoryPath = [IO.Path]::GetFullPath($PSScriptRoot).Replace("\", "/").TrimEnd("/")
$script:GitSafetyOption = "safe.directory=$($script:RepositoryPath)"

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArguments)

    & git -c $script:GitSafetyOption @GitArguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArguments -join ' ') failed (exit code $LASTEXITCODE)."
    }
}

function Get-ChangeCategory {
    param([string]$Path)

    $normalized = $Path.Replace("\", "/")
    $extension = [IO.Path]::GetExtension($normalized).ToLowerInvariant()

    if ($normalized -match "(^|/)tests?/") { return "tests" }
    if ($extension -in @(".mq4", ".mqh")) { return "MT4 code" }
    if ($extension -eq ".py") { return "Python tools" }
    if ($extension -in @(".md", ".txt")) { return "documentation" }
    if ($extension -in @(".ini", ".tpl", ".json", ".yml", ".yaml")) { return "configuration" }
    return "project files"
}

function New-CommitMessage {
    $added = @(Invoke-Git -GitArguments @("diff", "--cached", "--name-only", "--diff-filter=A"))
    $modified = @(Invoke-Git -GitArguments @("diff", "--cached", "--name-only", "--diff-filter=MRT"))
    $deleted = @(Invoke-Git -GitArguments @("diff", "--cached", "--name-only", "--diff-filter=D"))
    $allPaths = @($added + $modified + $deleted | Where-Object { $_ } | Select-Object -Unique)

    if ($allPaths.Count -eq 0) {
        throw "No staged changes were found."
    }

    if ($added.Count -gt 0 -and $modified.Count -eq 0 -and $deleted.Count -eq 0) {
        $verb = "Add"
    }
    elseif ($deleted.Count -gt 0 -and $added.Count -eq 0 -and $modified.Count -eq 0) {
        $verb = "Remove"
    }
    else {
        $verb = "Update"
    }

    if ($allPaths.Count -eq 1) {
        $subject = [IO.Path]::GetFileName($allPaths[0])
    }
    else {
        $categories = @($allPaths | ForEach-Object { Get-ChangeCategory $_ } | Select-Object -Unique)
        if ($categories.Count -eq 1) {
            $subject = $categories[0]
        }
        elseif ($categories.Count -eq 2) {
            $subject = "$($categories[0]) and $($categories[1])"
        }
        else {
            $subject = "project files"
        }
    }

    return "$verb $subject ($($allPaths.Count) files)"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found in PATH."
}

Set-Location -LiteralPath $PSScriptRoot

$insideWorkTree = (& git -c $script:GitSafetyOption rev-parse --is-inside-work-tree 2>$null)
if ($LASTEXITCODE -ne 0 -or $insideWorkTree -ne "true") {
    throw "Place this script in the root of a Git repository."
}

$repoRoot = (Invoke-Git -GitArguments @("rev-parse", "--show-toplevel") | Select-Object -First 1)
$normalizedRepoRoot = [IO.Path]::GetFullPath($repoRoot).Replace("\", "/").TrimEnd("/")
if (-not [string]::Equals($normalizedRepoRoot, $script:RepositoryPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "This script must be placed directly in the repository root: $normalizedRepoRoot"
}

$branch = (Invoke-Git -GitArguments @("branch", "--show-current") | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw "Detached HEAD is not supported. Check out a branch first."
}

$null = Invoke-Git -GitArguments @("remote", "get-url", "origin")
$changes = @(Invoke-Git -GitArguments @("status", "--porcelain"))
if ($changes.Count -eq 0) {
    Write-Host "No changes to commit."
    exit 0
}

Write-Host "Staging current changes..."
Invoke-Git -GitArguments @("add", "-A")

if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = New-CommitMessage
}

Write-Host "Commit message: $Message" -ForegroundColor Cyan
Invoke-Git -GitArguments @("diff", "--cached", "--stat")

if ($DryRun) {
    Write-Host "Dry run complete. Nothing was committed or pushed; changes remain staged." -ForegroundColor Yellow
    exit 0
}

Invoke-Git -GitArguments @("commit", "-m", $Message)

$upstream = (Invoke-Git -GitArguments @(
    "for-each-ref",
    "--format=%(upstream:short)",
    "refs/heads/$branch"
) | Select-Object -First 1)
if (-not [string]::IsNullOrWhiteSpace($upstream)) {
    Invoke-Git -GitArguments @("push")
}
else {
    Invoke-Git -GitArguments @("push", "-u", "origin", $branch)
}

Write-Host "Committed and pushed '$branch' successfully." -ForegroundColor Green
