# FUNTIDESK (ADR-018): sign a Windows release on the owner's computer and
# make it the latest one.
#
#   powershell -ExecutionPolicy Bypass -File sign-release.ps1 funtidesk-windows-<commit>
#
# Needs: OpenSSH client (built into Windows 10/11), the private key
# (default %USERPROFILE%\.ssh\funtidesk-release) and GitHub CLI `gh` signed in
# to the owner's account (https://cli.github.com, then `gh auth login`).
# Without `gh` the script stops after signing and says what to upload by hand.
#
# What it does: downloads SHA256SUMS.txt of the release, shows what is being
# signed, signs it (ssh-keygen asks for the key's password), checks the
# signature against the public key, uploads SHA256SUMS.txt.sig and starts the
# "Release promote" workflow, which checks everything again on GitHub.
# The private key never leaves this computer.

param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Key = (Join-Path $env:USERPROFILE '.ssh\funtidesk-release'),
    [string]$Repo = 'michailr1/FuntiDesk'
)

$ErrorActionPreference = 'Stop'
$ns = 'funtidesk-release'

if ($Tag -notmatch '^funtidesk-windows-[0-9a-f]{7,40}$') {
    throw "Not a Windows release tag: $Tag"
}
if (-not (Test-Path $Key)) { throw "No private key at $Key" }
if (-not (Test-Path "$Key.pub")) { throw "No public key at $Key.pub" }
$keygen = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
if (-not $keygen) {
    throw 'ssh-keygen not found: install the Windows feature "OpenSSH Client".'
}
$gh = (Get-Command gh.exe -ErrorAction SilentlyContinue).Source

$work = Join-Path $env:TEMP ("funtidesk-sign-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $work | Out-Null
try {
    $sums = Join-Path $work 'SHA256SUMS.txt'
    $sig = "$sums.sig"
    Write-Host "Downloading SHA256SUMS.txt of $Tag..."
    if ($gh) {
        & $gh release download $Tag --repo $Repo --pattern 'SHA256SUMS.txt' --dir $work
        if ($LASTEXITCODE -ne 0) { throw "gh could not download from $Tag" }
    } else {
        Invoke-WebRequest "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt" -OutFile $sums -UseBasicParsing
    }

    Write-Host ''
    Write-Host '=== You are signing ===' -ForegroundColor Yellow
    Get-Content $sums | ForEach-Object { Write-Host "  $_" }
    Write-Host '======================='
    Write-Host "Compare the hashes with the log of the build that made $Tag."
    if ((Read-Host 'Sign? (y/n)') -ne 'y') { throw 'Cancelled.' }

    & $keygen -Y sign -f $Key -n $ns $sums
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $sig)) { throw 'Signing failed.' }

    # The same check as the client, install.ps1 and "Release promote".
    $allowed = Join-Path $work 'allowed_signers'
    $pub = (Get-Content "$Key.pub" -First 1).Split(' ')
    Set-Content -Encoding ascii $allowed "$ns $($pub[0]) $($pub[1])"
    cmd /c "`"$keygen`" -Y verify -f `"$allowed`" -I $ns -n $ns -s `"$sig`" < `"$sums`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The new signature does not verify.' }
    Write-Host 'Signature made and checked.' -ForegroundColor Green

    if (-not $gh) {
        $keep = Join-Path (Get-Location) 'SHA256SUMS.txt.sig'
        Copy-Item $sig $keep -Force
        Write-Host ''
        Write-Host "GitHub CLI not found. Upload $keep to release $Tag in the browser,"
        Write-Host 'then run the workflow "Release promote" with this tag (Actions tab).'
        return
    }
    & $gh release upload $Tag $sig --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Upload of the signature failed.' }
    & $gh workflow run release-promote.yml --repo $Repo --ref main -f "tag=$Tag"
    if ($LASTEXITCODE -ne 0) { throw 'Could not start "Release promote".' }
    Write-Host ''
    Write-Host "Done: the signature is on $Tag, and 'Release promote' is checking it." -ForegroundColor Green
    Write-Host "Watch it: gh run list --repo $Repo --workflow release-promote.yml"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
