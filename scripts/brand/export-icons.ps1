param(
    [string]$Source = "$PSScriptRoot\..\..\design\brand\funtidesk-mark.svg",
    # Упрощённая производная для 16–24 px, см. docs/UI_WINDOWS_DESIGN.md, раздел 5.
    [string]$SmallSource = "$PSScriptRoot\..\..\design\brand\funtidesk-mark-small.svg",
    [string]$EdgePath
)

# Экспорт иконок клиента из канонического знака FuntiDesk.
# Растеризация — headless Microsoft Edge (есть в любой Windows 10/11),
# ICO собирается из PNG-кадров без внешних утилит.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
$Source = (Resolve-Path $Source).Path
$SmallSource = (Resolve-Path $SmallSource).Path

if (-not $EdgePath) {
    $EdgePath = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $EdgePath) { throw 'Microsoft Edge не найден, передайте -EdgePath' }

$Work = Join-Path ([IO.Path]::GetTempPath()) ("funtidesk-icons-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Work | Out-Null

function Export-Png([int]$Size) {
    $svg = if ($Size -le 24) { $SmallSource } else { $Source }
    $html = Join-Path $Work "mark-$Size.html"
    $png = Join-Path $Work "mark-$Size.png"
    $svgUrl = ([Uri]$svg).AbsoluteUri
    Set-Content -Path $html -Encoding utf8 -Value (
        "<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent}" +
        "img{display:block;width:${Size}px;height:${Size}px}</style></head>" +
        "<body><img src=`"$svgUrl`"></body></html>")
    $edgeProfile = Join-Path $Work "edge-profile-$Size"
    $edgeArgs = @(
        '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
        "--user-data-dir=$edgeProfile",
        '--default-background-color=00000000', '--force-device-scale-factor=1',
        "--window-size=$Size,$Size", "--screenshot=$png", ([Uri]$html).AbsoluteUri)
    # Не -Wait: он ждёт и дочерние процессы Edge (crashpad), которые остаются жить.
    $p = Start-Process -FilePath $EdgePath -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw "Рендер $Size px: таймаут" }
    if ($p.ExitCode -ne 0 -or -not (Test-Path $png)) { throw "Рендер $Size px не удался" }

    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($png)
    try {
        if ($img.Width -ne $Size -or $img.Height -ne $Size) {
            throw "Рендер $Size px дал $($img.Width)x$($img.Height)"
        }
    }
    finally { $img.Dispose() }
    return $png
}

function Write-Ico([string]$Path, [int[]]$Sizes) {
    $frames = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($s in $Sizes) { $frames.Add([IO.File]::ReadAllBytes((Export-Png $s))) }
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($out)
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$Sizes.Count)
    $offset = 6 + 16 * $Sizes.Count
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $dim = if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([UInt16]1); $w.Write([UInt16]32)
        $w.Write([UInt32]$frames[$i].Length); $w.Write([UInt32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($f in $frames) { $w.Write($f) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    Write-Host "$Path <- $($Sizes -join '/')"
}

try {
    $client = Join-Path $RepoRoot 'client'
    $appSizes = 16, 24, 32, 48, 256

    Write-Ico (Join-Path $client 'res\icon.ico') $appSizes
    Write-Ico (Join-Path $client 'flutter\windows\runner\resources\app_icon.ico') $appSizes
    # Трей: один кадр, как в upstream; tray.rs декодирует его в RGBA сам.
    Write-Ico (Join-Path $client 'res\tray-icon.ico') @(32)

    Copy-Item (Export-Png 1024) (Join-Path $client 'res\icon.png') -Force
    Write-Host "$client\res\icon.png <- 1024"
    Copy-Item $Source (Join-Path $client 'flutter\assets\icon.svg') -Force
    Write-Host "$client\flutter\assets\icon.svg <- svg"
}
finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
