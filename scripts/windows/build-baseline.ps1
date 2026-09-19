param(
    [string]$ToolsRoot = "$PSScriptRoot\..\..\.tools"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$ClientRoot = Join-Path $RepoRoot 'client'
$FlutterBridge = Join-Path $ToolsRoot 'flutter-3.22.3'
$FlutterBuild = Join-Path $ToolsRoot 'flutter-3.24.5'
$VcpkgRoot = Join-Path $ToolsRoot 'vcpkg'
$LogDir = Join-Path $RepoRoot 'build-logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("windows-baseline-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogFile -Force

try {
    Write-Host "Repo: $RepoRoot"
    Write-Host "Client: $ClientRoot"

    if (-not (Test-Path "$ClientRoot\Cargo.toml")) { throw 'client/Cargo.toml не найден' }
    if (-not (Test-Path "$FlutterBridge\bin\flutter.bat")) { throw 'Flutter 3.22.3 не найден. Сначала bootstrap.ps1' }
    if (-not (Test-Path "$FlutterBuild\bin\flutter.bat")) { throw 'Flutter 3.24.5 не найден. Сначала bootstrap.ps1' }
    if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) { throw 'vcpkg не найден. Сначала bootstrap.ps1' }

    # Поднять MSVC environment без запуска Visual Studio IDE.
    $vswhere = "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'vswhere не найден' }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) { throw 'Visual C++ Build Tools workload не найден' }
    $vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    cmd /s /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($matches[1])" -Value $matches[2] }
    }

    $env:RUSTUP_TOOLCHAIN = '1.75.0-x86_64-pc-windows-msvc'
    $env:VCPKG_ROOT = $VcpkgRoot
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    $env:PATH = "C:\Program Files\LLVM\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

    Push-Location $ClientRoot

    Write-Host '== Фиксация исходного состояния =='
    git status --short
    git rev-parse HEAD
    rustc --version
    cargo --version
    & "$FlutterBuild\bin\flutter.bat" --version
    & 'C:\Program Files\LLVM\bin\clang.exe' --version | Select-Object -First 1
    & "$VcpkgRoot\vcpkg.exe" version

    Write-Host '== Генерация flutter-rust-bridge как upstream CI =='
    cargo install cargo-expand --version 1.0.95 --locked
    cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked

    $pubspec = Join-Path $ClientRoot 'flutter\pubspec.yaml'
    $pubspecLock = Join-Path $ClientRoot 'flutter\pubspec.lock'
    $pubspecBak = "$pubspec.funtidesk-baseline.bak"
    $lockBak = "$pubspecLock.funtidesk-baseline.bak"
    Copy-Item $pubspec $pubspecBak -Force
    if (Test-Path $pubspecLock) { Copy-Item $pubspecLock $lockBak -Force }
    try {
        (Get-Content $pubspec -Raw).Replace('extended_text: 14.0.0','extended_text: 13.0.0') | Set-Content $pubspec -NoNewline
        $env:PATH = "$FlutterBridge\bin;$env:PATH"
        Push-Location (Join-Path $ClientRoot 'flutter')
        flutter pub get
        Pop-Location
        & "$env:USERPROFILE\.cargo\bin\flutter_rust_bridge_codegen.exe" --rust-input .\src\flutter_ffi.rs --dart-output .\flutter\lib\generated_bridge.dart --c-output .\flutter\macos\Runner\bridge_generated.h
        Copy-Item .\flutter\macos\Runner\bridge_generated.h .\flutter\ios\Runner\bridge_generated.h -Force
    }
    finally {
        Move-Item $pubspecBak $pubspec -Force
        if (Test-Path $lockBak) { Move-Item $lockBak $pubspecLock -Force }
    }

    Write-Host '== Flutter 3.24.5 custom engine =='
    $env:PATH = "$FlutterBuild\bin;$env:PATH"
    flutter config --enable-windows-desktop
    flutter precache --windows

    $patch = Join-Path $ClientRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
    Push-Location $FlutterBuild
    git apply --check $patch 2>$null
    if ($LASTEXITCODE -eq 0) {
        git apply $patch
    } else {
        git apply --reverse --check $patch 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Flutter patch нельзя ни применить, ни определить как уже применённый' }
        Write-Host 'Flutter patch уже применён'
    }
    Pop-Location

    $engineZip = Join-Path $env:TEMP 'funtidesk-windows-x64-release.zip'
    $engineTmp = Join-Path $env:TEMP 'funtidesk-windows-x64-release'
    Remove-Item $engineTmp -Recurse -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' -OutFile $engineZip
    Expand-Archive $engineZip -DestinationPath $engineTmp -Force
    $engineDest = Join-Path $FlutterBuild 'bin\cache\artifacts\engine\windows-x64-release'
    New-Item -ItemType Directory -Force -Path $engineDest | Out-Null
    Copy-Item "$engineTmp\*" $engineDest -Recurse -Force

    Write-Host '== vcpkg dependencies =='
    & "$VcpkgRoot\vcpkg.exe" install --triplet x64-windows-static --x-install-root="$VcpkgRoot\installed"
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg install failed' }

    Write-Host '== Baseline build =='
    python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
    if ($LASTEXITCODE -ne 0) { throw 'build.py failed' }

    $releaseDir = Join-Path $ClientRoot 'flutter\build\windows\x64\runner\Release'
    if (-not (Test-Path $releaseDir)) { throw "Release dir не найден: $releaseDir" }
    $exe = Get-ChildItem $releaseDir -Filter '*.exe' | Select-Object -First 1
    if (-not $exe) { throw 'Windows exe не найден в Release dir' }

    $hash = Get-FileHash $exe.FullName -Algorithm SHA256
    Write-Host "BASELINE_BUILD_OK=true"
    Write-Host "ARTIFACT=$($exe.FullName)"
    Write-Host "SHA256=$($hash.Hash)"
    Write-Host "LOG=$LogFile"
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}
