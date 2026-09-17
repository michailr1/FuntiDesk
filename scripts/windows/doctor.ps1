$ErrorActionPreference = 'Stop'

function Test-Command($Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "[OK] $Name -> $($cmd.Source)"
        return $true
    }
    Write-Host "[MISS] $Name"
    return $false
}

Write-Host "FuntiDesk Windows baseline doctor"
Write-Host "OS: $([System.Environment]::OSVersion.VersionString)"
Write-Host "Arch: $env:PROCESSOR_ARCHITECTURE"
Write-Host ""

$ok = $true
$ok = (Test-Command git) -and $ok
$ok = (Test-Command python) -and $ok
$ok = (Test-Command cmake) -and $ok
$ok = (Test-Command rustup) -and $ok
$ok = (Test-Command rustc) -and $ok
$ok = (Test-Command cargo) -and $ok
$ok = (Test-Command clang) -and $ok
$ok = (Test-Command flutter) -and $ok

$vswhere = "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) {
        Write-Host "[OK] Visual C++ Build Tools -> $vs"
    } else {
        Write-Host "[MISS] Visual C++ Build Tools workload"
        $ok = $false
    }
} else {
    Write-Host "[MISS] vswhere / Visual Studio Build Tools"
    $ok = $false
}

Write-Host ""
if (Get-Command rustc -ErrorAction SilentlyContinue) { rustc --version }
if (Get-Command flutter -ErrorAction SilentlyContinue) { flutter --version }
if (Get-Command clang -ErrorAction SilentlyContinue) { clang --version | Select-Object -First 1 }
if (Get-Command cmake -ErrorAction SilentlyContinue) { cmake --version | Select-Object -First 1 }
if (Get-Command python -ErrorAction SilentlyContinue) { python --version }
if (Get-Command git -ErrorAction SilentlyContinue) { git --version }

Write-Host ""
if ($ok) {
    Write-Host "DOCTOR_OK=true"
    exit 0
}
Write-Host "DOCTOR_OK=false"
exit 2
