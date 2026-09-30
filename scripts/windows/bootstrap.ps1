param(
    [string]$ToolsRoot = "$PSScriptRoot\..\..\.tools"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# FUNTIDESK: immutable external dependency identities for reproducible Windows builds.
$LlvmAssetUrl = 'https://api.github.com/repos/llvm/llvm-project/releases/assets/87177143'
$LlvmSha256 = '22e2f2c38be4c44db7a1e9da5e67de2a453c5b4be9cf91e139592a63877ac0a2'
$FlutterPins = @{
    '3.22.3' = 'b0850beeb25f6d5b10426284f506557f66181b36'
    '3.24.5' = 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668'
}

function Assert-Sha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA256 mismatch for $Path. expected=$Expected actual=$actual"
    }
}

function Ensure-WingetPackage([string]$Id, [string]$Override = '') {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget не найден. Нужен App Installer из Microsoft Store либо ручная установка prerequisites.'
    }
    $args = @('install','--id',$Id,'--exact','--accept-source-agreements','--accept-package-agreements','--silent')
    if ($Override) { $args += @('--override',$Override) }
    & winget @args
    if ($LASTEXITCODE -ne 0) { throw "winget install failed: $Id" }
}

New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

Write-Host '== Базовые инструменты =='
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Ensure-WingetPackage 'Git.Git' }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Ensure-WingetPackage 'Python.Python.3.12' }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { Ensure-WingetPackage 'Kitware.CMake' }
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) { Ensure-WingetPackage 'Rustlang.Rustup' }

$vswhere = "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe"
$needVs = $true
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) { $needVs = $false }
}
if ($needVs) {
    Ensure-WingetPackage 'Microsoft.VisualStudio.2022.BuildTools' '--wait --norestart --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
}

Write-Host '== Rust 1.75 =='
& rustup toolchain install 1.75.0-x86_64-pc-windows-msvc --profile minimal --component rustfmt
& rustup target add x86_64-pc-windows-msvc --toolchain 1.75.0-x86_64-pc-windows-msvc

Write-Host '== LLVM 15.0.6 =='
$llvmDir = 'C:\Program Files\LLVM'
$clangExe = Join-Path $llvmDir 'bin\clang.exe'
$needLlvm = $true
if (Test-Path $clangExe) {
    $ver = (& $clangExe --version | Select-Object -First 1)
    if ($ver -match '15\.0\.6') { $needLlvm = $false }
}
if ($needLlvm) {
    $llvmInstaller = Join-Path $env:TEMP 'LLVM-15.0.6-win64.exe'
    Remove-Item $llvmInstaller -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $LlvmAssetUrl -Headers @{ Accept = 'application/octet-stream'; 'User-Agent' = 'FuntiDesk-build' } -OutFile $llvmInstaller
    Assert-Sha256 $llvmInstaller $LlvmSha256
    Start-Process -FilePath $llvmInstaller -ArgumentList '/S' -Wait
}

Write-Host '== Flutter =='
function Ensure-Flutter([string]$Version) {
    $expectedCommit = $FlutterPins[$Version]
    if (-not $expectedCommit) { throw "No pinned Flutter commit for $Version" }

    $dir = Join-Path $ToolsRoot "flutter-$Version"
    if (-not (Test-Path (Join-Path $dir 'bin\flutter.bat'))) {
        git clone --depth 1 --branch $Version https://github.com/flutter/flutter.git $dir
        if ($LASTEXITCODE -ne 0) { throw "Flutter clone failed: $Version" }
    }

    $actualCommit = (& git -C $dir rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) {
        throw "Flutter $Version commit mismatch. expected=$expectedCommit actual=$actualCommit"
    }

    & (Join-Path $dir 'bin\flutter.bat') config --enable-windows-desktop
    & (Join-Path $dir 'bin\flutter.bat') precache --windows
    return $dir
}
$flutterBridge = Ensure-Flutter '3.22.3'
$flutterBuild = Ensure-Flutter '3.24.5'

Write-Host '== vcpkg =='
$vcpkgDir = Join-Path $ToolsRoot 'vcpkg'
if (-not (Test-Path (Join-Path $vcpkgDir '.git'))) {
    git clone https://github.com/microsoft/vcpkg.git $vcpkgDir
}
pushd $vcpkgDir
git fetch --all --tags --prune
git checkout --detach 120deac3062162151622ca4860575a33844ba10b
& .\bootstrap-vcpkg.bat -disableMetrics
popd

Write-Host ''
Write-Host 'BOOTSTRAP_OK=true'
Write-Host "TOOLS_ROOT=$ToolsRoot"
Write-Host "FLUTTER_BRIDGE=$flutterBridge"
Write-Host "FLUTTER_BUILD=$flutterBuild"
Write-Host "VCPKG_ROOT=$vcpkgDir"
Write-Host 'Перезапусти PowerShell перед сборкой, чтобы PATH обновился после установщиков.'
