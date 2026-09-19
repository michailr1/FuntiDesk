[CmdletBinding()]
param(
    [string]$ToolsRoot = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $ToolsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\.tools")).Path
}

function Invoke-Native([scriptblock]$Command, [string]$Description) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$ClientRoot = Join-Path $RepoRoot 'client'
$FlutterBridge = Join-Path $ToolsRoot 'flutter-3.22.3'
$FlutterBuild = Join-Path $ToolsRoot 'flutter-3.24.5'
$VcpkgRoot = Join-Path $ToolsRoot 'vcpkg'
$LogDir = Join-Path $RepoRoot 'artifacts\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("windows-baseline-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $LogFile -Force

try {
    if (-not (Test-Path (Join-Path $ClientRoot 'Cargo.toml'))) { throw 'client/Cargo.toml is missing' }
    if (-not (Test-Path (Join-Path $FlutterBridge 'bin\flutter.bat'))) { throw 'Flutter 3.22.3 is missing; run bootstrap.ps1 first' }
    if (-not (Test-Path (Join-Path $FlutterBuild 'bin\flutter.bat'))) { throw 'Flutter 3.24.5 is missing; run bootstrap.ps1 first' }
    if (-not (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) { throw 'vcpkg is missing; run bootstrap.ps1 first' }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'vswhere.exe is missing' }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) { throw 'Visual C++ Build Tools workload is missing' }
    $vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    cmd.exe /s /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($matches[1])" -Value $matches[2] }
    }

    $env:RUSTUP_TOOLCHAIN = '1.75.0-x86_64-pc-windows-msvc'
    $env:VCPKG_ROOT = $VcpkgRoot
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    $env:PATH = "C:\Program Files\LLVM\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

    Push-Location $ClientRoot
    try {
        Write-Host '== Toolchain =='
        Invoke-Native { rustc --version } 'rustc version check'
        Invoke-Native { cargo --version } 'cargo version check'
        Invoke-Native { & (Join-Path $FlutterBuild 'bin\flutter.bat') --version } 'Flutter build version check'
        Invoke-Native { & 'C:\Program Files\LLVM\bin\clang.exe' --version } 'clang version check'
        Invoke-Native { & (Join-Path $VcpkgRoot 'vcpkg.exe') version } 'vcpkg version check'

        Write-Host '== Flutter Rust bridge =='
        Invoke-Native { cargo install cargo-expand --version 1.0.95 --locked } 'cargo-expand install'
        Invoke-Native { cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked } 'flutter_rust_bridge_codegen install'

        $pubspec = Join-Path $ClientRoot 'flutter\pubspec.yaml'
        $pubspecLock = Join-Path $ClientRoot 'flutter\pubspec.lock'
        $pubspecBak = "$pubspec.funtidesk-baseline.bak"
        $lockBak = "$pubspecLock.funtidesk-baseline.bak"
        Copy-Item $pubspec $pubspecBak -Force
        if (Test-Path $pubspecLock) { Copy-Item $pubspecLock $lockBak -Force }
        try {
            (Get-Content $pubspec -Raw).Replace('extended_text: 14.0.0', 'extended_text: 13.0.0') | Set-Content $pubspec -NoNewline
            $env:PATH = "$(Join-Path $FlutterBridge 'bin');$env:PATH"
            Push-Location (Join-Path $ClientRoot 'flutter')
            try { Invoke-Native { flutter pub get } 'Flutter bridge pub get' } finally { Pop-Location }
            Invoke-Native { & "$env:USERPROFILE\.cargo\bin\flutter_rust_bridge_codegen.exe" --rust-input .\src\flutter_ffi.rs --dart-output .\flutter\lib\generated_bridge.dart --c-output .\flutter\macos\Runner\bridge_generated.h } 'Flutter bridge generation'
            Copy-Item .\flutter\macos\Runner\bridge_generated.h .\flutter\ios\Runner\bridge_generated.h -Force
        }
        finally {
            Move-Item $pubspecBak $pubspec -Force
            if (Test-Path $lockBak) { Move-Item $lockBak $pubspecLock -Force }
        }

        Write-Host '== Flutter custom engine =='
        $env:PATH = "$(Join-Path $FlutterBuild 'bin');$env:PATH"
        Invoke-Native { flutter config --enable-windows-desktop } 'Flutter Windows enablement'
        Invoke-Native { flutter precache --windows } 'Flutter Windows precache'
        $patch = Join-Path $ClientRoot '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
        Push-Location $FlutterBuild
        try {
            # `git apply --check` deliberately exits non-zero when the patch is
            # already applied. Native stderr must not become a PowerShell error.
            $previousErrorAction = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                git apply --check $patch 2>$null
                $patchApplicable = $LASTEXITCODE -eq 0
                if (-not $patchApplicable) {
                    git apply --reverse --check $patch 2>$null
                    $patchAlreadyApplied = $LASTEXITCODE -eq 0
                }
            }
            finally {
                $ErrorActionPreference = $previousErrorAction
            }
            if ($patchApplicable) {
                Invoke-Native { git apply $patch } 'Flutter patch'
            }
            elseif (-not $patchAlreadyApplied) {
                throw 'Flutter patch is neither applicable nor already applied'
            }
            else {
                Write-Host 'Flutter patch already applied'
            }
        } finally { Pop-Location }

        $engineZip = Join-Path $env:TEMP 'funtidesk-windows-x64-release.zip'
        $engineTmp = Join-Path $env:TEMP 'funtidesk-windows-x64-release'
        Remove-Item $engineTmp -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' -OutFile $engineZip
        Expand-Archive $engineZip -DestinationPath $engineTmp -Force
        $engineDest = Join-Path $FlutterBuild 'bin\cache\artifacts\engine\windows-x64-release'
        New-Item -ItemType Directory -Force -Path $engineDest | Out-Null
        Copy-Item "$(Join-Path $engineTmp '*')" $engineDest -Recurse -Force

        Write-Host '== Pinned vcpkg manifest =='
        Invoke-Native { & (Join-Path $VcpkgRoot 'vcpkg.exe') install --triplet x64-windows-static --x-install-root="$VcpkgRoot\installed" } 'vcpkg install'

        Write-Host '== Upstream-equivalent Windows Flutter build =='
        Invoke-Native { python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram } 'build.py'

        $releaseDir = Join-Path $ClientRoot 'flutter\build\windows\x64\runner\Release'
        if (-not (Test-Path $releaseDir)) { throw "Release directory is missing: $releaseDir" }
        $exe = Get-ChildItem $releaseDir -Filter '*.exe' | Select-Object -First 1
        if ($null -eq $exe) { throw 'Release executable is missing' }
        $hash = Get-FileHash $exe.FullName -Algorithm SHA256
        Write-Host 'BASELINE_BUILD_OK=true'
        Write-Host "ARTIFACT=$($exe.FullName)"
        Write-Host "SHA256=$($hash.Hash)"
        Write-Host "LOG=$LogFile"
    }
    finally { Pop-Location }
}
finally {
    Stop-Transcript | Out-Null
}
