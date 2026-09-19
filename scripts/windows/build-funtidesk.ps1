[CmdletBinding()]
param(
    [string]$ToolsRoot = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $ToolsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\.tools")).Path
}

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$LogDir = Join-Path $RepoRoot 'artifacts\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("windows-funtidesk-binding-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogFile -Force

try {
    & (Join-Path $PSScriptRoot 'validate-funtidesk-binding.ps1') -RepoRoot $RepoRoot

    # The accepted MIK-19 script supplies the pinned bridge/build Flutter SDKs,
    # MSVC environment, LLVM, Rust 1.75 and the pinned vcpkg manifest install.
    & (Join-Path $PSScriptRoot 'build-baseline.ps1') -ToolsRoot $ToolsRoot
    if ($LASTEXITCODE -ne 0) { throw 'Pinned Windows production build failed' }
}
finally {
    Stop-Transcript | Out-Null
}

Write-Host "FUNTIDESK_BUILD_LOG=$LogFile"
