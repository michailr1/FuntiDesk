[CmdletBinding()]
param(
    [string]$ToolsRoot = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $ToolsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\.tools")).Path
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

& (Join-Path $PSScriptRoot 'validate-funtidesk-binding.ps1') -RepoRoot $RepoRoot

# MIK-15 intentionally reuses the accepted MIK-19 build pipeline unchanged.
# Any build failure is propagated by the called script.
& (Join-Path $PSScriptRoot 'build-baseline.ps1') -ToolsRoot $ToolsRoot

Write-Output 'FUNTIDESK_BUILD_OK=true'
