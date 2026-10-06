param(
    [ValidateSet('Incremental', 'Clean')]
    [string]$Mode = 'Incremental',
    [string]$ToolsRoot = "$PSScriptRoot\..\..\.tools",
    [string]$ArtifactsRoot = "$PSScriptRoot\..\..\artifacts\windows-worker",
    [switch]$NoSnapshot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$ClientRoot = Join-Path $RepoRoot 'client'
$FlutterBridge = Join-Path $ToolsRoot 'flutter-3.22.3'
$FlutterBuild = Join-Path $ToolsRoot 'flutter-3.24.5'
$VcpkgRoot = Join-Path $ToolsRoot 'vcpkg'
$ReleaseDir = Join-Path $ClientRoot 'flutter\build\windows\x64\runner\Release'
$LogDir = Join-Path $RepoRoot 'build-logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("windows-worker-{0}-{1}.log" -f $Mode.ToLowerInvariant(), (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Get-TrackedStatus {
    return @(git -C $RepoRoot status --short --untracked-files=no)
}

function Enable-VsEnvironment {
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found' }

    $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    if (-not $vsPath) { throw 'Visual Studio C++ Build Tools not found' }

    $vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found: $vsDevCmd" }

    cmd /s /c "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && set" | ForEach-Object {
        $parts = $_.Split('=', 2)
        if ($parts.Count -eq 2) {
            Set-Item -Path ('Env:' + $parts[0]) -Value $parts[1]
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw 'MSVC cl.exe unavailable after VsDevCmd activation'
    }
}

function Assert-WorkerPrerequisites {
    foreach ($path in @(
        (Join-Path $FlutterBridge 'bin\flutter.bat'),
        (Join-Path $FlutterBuild 'bin\flutter.bat'),
        (Join-Path $VcpkgRoot 'vcpkg.exe'),
        (Join-Path $env:USERPROFILE '.cargo\bin\flutter_rust_bridge_codegen.exe')
    )) {
        if (-not (Test-Path $path)) {
            throw "Pinned worker prerequisite missing: $path. Run scripts/windows/bootstrap.ps1/build-baseline.ps1 first."
        }
    }

    $engineDir = Join-Path $FlutterBuild 'bin\cache\artifacts\engine\windows-x64-release'
    if (-not (Test-Path $engineDir)) {
        throw "Pinned custom Flutter engine cache missing: $engineDir. Run a Clean worker build first."
    }
}

function Update-FlutterBridge {
    Write-Host '== Regenerate pinned Flutter/Rust bridge =='
    $pubspec = Join-Path $ClientRoot 'flutter\pubspec.yaml'
    $pubspecLock = Join-Path $ClientRoot 'flutter\pubspec.lock'
    $pubspecBak = "$pubspec.funtidesk-worker.bak"
    $lockBak = "$pubspecLock.funtidesk-worker.bak"
    $codegen = Join-Path $env:USERPROFILE '.cargo\bin\flutter_rust_bridge_codegen.exe'

    Copy-Item $pubspec $pubspecBak -Force
    if (Test-Path $pubspecLock) { Copy-Item $pubspecLock $lockBak -Force }
    try {
        (Get-Content $pubspec -Raw).Replace('extended_text: 14.0.0','extended_text: 13.0.0') | Set-Content $pubspec -NoNewline
        $oldPath = $env:PATH
        try {
            $env:PATH = "$FlutterBridge\bin;$oldPath"
            Push-Location (Join-Path $ClientRoot 'flutter')
            try {
                & "$FlutterBridge\bin\flutter.bat" pub get
                if ($LASTEXITCODE -ne 0) { throw "flutter pub get for bridge failed with exit code $LASTEXITCODE" }
            }
            finally {
                Pop-Location
            }

            Push-Location $ClientRoot
            try {
                & $codegen --rust-input .\src\flutter_ffi.rs --dart-output .\flutter\lib\generated_bridge.dart --c-output .\flutter\macos\Runner\bridge_generated.h
                if ($LASTEXITCODE -ne 0) { throw "flutter_rust_bridge_codegen failed with exit code $LASTEXITCODE" }
                Copy-Item .\flutter\macos\Runner\bridge_generated.h .\flutter\ios\Runner\bridge_generated.h -Force
            }
            finally {
                Pop-Location
            }
        }
        finally {
            $env:PATH = $oldPath
        }
    }
    finally {
        Move-Item $pubspecBak $pubspec -Force
        if (Test-Path $lockBak) { Move-Item $lockBak $pubspecLock -Force }
    }
}

function Write-RuntimeManifest {
    if (-not (Test-Path $ReleaseDir)) { throw "Release directory not found: $ReleaseDir" }
    $manifest = Join-Path $ReleaseDir 'SHA256SUMS.txt'
    Get-ChildItem $ReleaseDir -File -Recurse |
        Where-Object { $_.FullName -ne $manifest } |
        Sort-Object FullName |
        ForEach-Object {
            $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $relative = $_.FullName.Substring($ReleaseDir.Length + 1).Replace('\','/')
            "$hash  $relative"
        } | Set-Content -Encoding ascii $manifest
    return $manifest
}

$beforeStatus = Get-TrackedStatus
$head = (git -C $RepoRoot rev-parse HEAD).Trim()
$branch = (git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()

Start-Transcript -Path $LogFile -Force
try {
    Write-Host "FUNTIDESK_WINDOWS_WORKER=true"
    Write-Host "MODE=$Mode"
    Write-Host "REPO=$RepoRoot"
    Write-Host "BRANCH=$branch"
    Write-Host "HEAD=$head"

    if ($Mode -eq 'Clean') {
        Write-Host '== Local clean worker build =='
        Remove-Item (Join-Path $ClientRoot 'flutter\build') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $ClientRoot 'target') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $ClientRoot 'flutter\.dart_tool') -Recurse -Force -ErrorAction SilentlyContinue
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-baseline.ps1') -ToolsRoot $ToolsRoot
        if ($LASTEXITCODE -ne 0) { throw "build-baseline.ps1 failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Host '== Incremental worker build =='
        Assert-WorkerPrerequisites
        Update-FlutterBridge
        Enable-VsEnvironment
        $env:RUSTUP_TOOLCHAIN = '1.75.0-x86_64-pc-windows-msvc'
        $env:VCPKG_ROOT = $VcpkgRoot
        $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
        $env:PATH = "C:\Program Files\LLVM\bin;$env:USERPROFILE\.cargo\bin;$($FlutterBuild)\bin;$env:PATH"

        Push-Location $ClientRoot
        try {
            python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
            if ($LASTEXITCODE -ne 0) { throw "build.py failed with exit code $LASTEXITCODE" }
        }
        finally {
            Pop-Location
        }
    }

    $exe = Join-Path $ReleaseDir 'FuntiDesk.exe'
    if (-not (Test-Path $exe)) {
        $found = @(Get-ChildItem $ReleaseDir -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        throw "Expected FuntiDesk.exe not found. EXEs present: $($found -join ', ')"
    }

    $manifest = Write-RuntimeManifest
    $exeHash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()

    $afterStatus = Get-TrackedStatus
    $statusChanged = Compare-Object $beforeStatus $afterStatus
    if ($statusChanged) {
        Write-Host 'Tracked source status changed during build:'
        $statusChanged | Format-Table | Out-String | Write-Host
        throw 'Build modified tracked source state'
    }

    $snapshot = $null
    if (-not $NoSnapshot) {
        New-Item -ItemType Directory -Force -Path $ArtifactsRoot | Out-Null
        $snapshot = Join-Path $ArtifactsRoot ("funtidesk-windows-x64-{0}" -f $head.Substring(0, 12))
        Remove-Item $snapshot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        Copy-Item (Join-Path $ReleaseDir '*') $snapshot -Recurse -Force
        Copy-Item $LogFile (Join-Path $snapshot 'build-worker.log') -Force
        @(
            "PRODUCT=FuntiDesk",
            "MODE=$Mode",
            "BRANCH=$branch",
            "GIT_SHA=$head",
            "BUILT_AT_UTC=$([DateTime]::UtcNow.ToString('o'))",
            "EXE=FuntiDesk.exe",
            "EXE_SHA256=$exeHash"
        ) | Set-Content -Encoding ascii (Join-Path $snapshot 'BUILD_PROVENANCE.txt')
    }

    Write-Host 'WINDOWS_WORKER_BUILD_OK=true'
    Write-Host "ARTIFACT=$exe"
    Write-Host "SHA256=$exeHash"
    Write-Host "MANIFEST=$manifest"
    Write-Host "LOG=$LogFile"
    if ($snapshot) { Write-Host "SNAPSHOT=$snapshot" }
}
finally {
    Stop-Transcript | Out-Null
}
