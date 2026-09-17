param(
    [string]$ToolsRoot = "$PSScriptRoot\..\..\.tools"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    Invoke-WebRequest 'https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.6/LLVM-15.0.6-win64.exe' -OutFile $llvmInstaller
    Start-Process -FilePath $llvmInstaller -ArgumentList '/S' -Wait
}

Write-Host '== Flutter =='
function Ensure-Flutter([string]$Version) {
    $dir = Join-Path $ToolsRoot "flutter-$Version"
    if (-not (Test-Path (Join-Path $dir 'bin\flutter.bat'))) {
        git clone --depth 1 --branch $Version https://github.com/flutter/flutter.git $dir
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
