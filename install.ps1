# FuntiDesk installer — current user only, no administrator rights needed.
#
#   irm https://raw.githubusercontent.com/michailr1/FuntiDesk/main/install.ps1 | iex
#
# Downloads the latest Windows release to %LOCALAPPDATA%\Programs\FuntiDesk,
# checks its SHA-256, adds a Start menu shortcut and starts it. Files
# downloaded by PowerShell carry no "downloaded from the Internet" mark, so
# SmartScreen does not stop the first launch. Running it again updates
# FuntiDesk in place; the profile (ID, settings) is kept.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$asset = 'FuntiDesk-windows-x64.zip'
$base = if ($env:FUNTIDESK_RELEASE) {
    "https://github.com/michailr1/FuntiDesk/releases/download/$($env:FUNTIDESK_RELEASE)"
} else {
    'https://github.com/michailr1/FuntiDesk/releases/latest/download'
}
$dir = Join-Path $env:LOCALAPPDATA 'Programs\FuntiDesk'
$exe = Join-Path $dir 'FuntiDesk.exe'
$work = Join-Path $env:TEMP ("funtidesk-install-" + [guid]::NewGuid())
$zip = Join-Path $work $asset
$sums = Join-Path $work 'SHA256SUMS.txt'
$stage = Join-Path $work 'files'

New-Item -ItemType Directory -Force $work, $stage | Out-Null
try {
    Write-Host 'Скачиваю FuntiDesk...'
    Invoke-WebRequest "$base/$asset" -OutFile $zip -UseBasicParsing
    Invoke-WebRequest "$base/SHA256SUMS.txt" -OutFile $sums -UseBasicParsing

    $expected = (Get-Content $sums | Where-Object { $_ -match "\s$([regex]::Escape($asset))$" } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
    if (-not $expected -or $actual -ne $expected.ToUpperInvariant()) {
        throw "Контрольная сумма не совпала: ожидалась $expected, получена $actual. Установка отменена."
    }

    Expand-Archive $zip -DestinationPath $stage -Force
    if (-not (Test-Path (Join-Path $stage 'FuntiDesk.exe'))) {
        throw 'В архиве нет FuntiDesk.exe. Установка отменена.'
    }

    $running = Get-Process FuntiDesk -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir\*" }
    if ($running) {
        Write-Host 'Закрываю запущенный FuntiDesk для обновления...'
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 800
    }
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $dir) | Out-Null
    Move-Item $stage $dir

    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'FuntiDesk.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $exe
    $link.WorkingDirectory = $dir
    $link.Description = 'FuntiDesk — удалённый доступ для семьи'
    $link.Save()

    Write-Host "Готово: $exe"
    Write-Host 'Ярлык добавлен в меню «Пуск».'
    Start-Process $exe
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
