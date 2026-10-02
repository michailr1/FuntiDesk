param(
    [Parameter(Mandatory=$true)]
    [string]$ExePath,
    [string]$OutDir = "$PWD\security-acceptance"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $ExePath)) { throw "EXE not found: $ExePath" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $OutDir "funtidesk-security-$stamp.txt"

function Write-Line([string]$s) {
    $s | Tee-Object -FilePath $report -Append
}

Write-Line "FUNTIDESK_SECURITY_ACCEPTANCE=true"
Write-Line "TIMESTAMP=$(Get-Date -Format o)"
Write-Line "HOST=$env:COMPUTERNAME"
Write-Line "EXE=$((Resolve-Path $ExePath).Path)"
Write-Line "EXE_SHA256=$((Get-FileHash $ExePath -Algorithm SHA256).Hash)"

$cfgRoots = @(
    (Join-Path $env:APPDATA 'RustDesk'),
    (Join-Path $env:APPDATA 'FuntiDesk')
) | Where-Object { Test-Path $_ }

foreach ($root in $cfgRoots) {
    Write-Line "CONFIG_ROOT=$root"
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(toml|json|conf|ini)$' } |
        Sort-Object FullName |
        ForEach-Object {
            $h=(Get-FileHash $_.FullName -Algorithm SHA256).Hash
            Write-Line "CONFIG_FILE=$($_.FullName)|SHA256=$h"
        }
}

Write-Line "---- ACTIVE CONNECTIONS BEFORE ----"
Get-NetTCPConnection -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq 'Established' } |
    Sort-Object RemoteAddress,RemotePort |
    ForEach-Object {
        Write-Line ("TCP={0}:{1}->{2}:{3}" -f $_.LocalAddress,$_.LocalPort,$_.RemoteAddress,$_.RemotePort)
    }

Write-Line "---- DNS CACHE BEFORE ----"
Get-DnsClientCache -ErrorAction SilentlyContinue |
    Sort-Object Entry |
    ForEach-Object { Write-Line ("DNS={0}|{1}" -f $_.Entry,$_.Data) }

Write-Line "---- POLICY EXPECTATIONS ----"
Write-Line "EXPECT_RENDEZVOUS=desk.funti.cc:21116"
Write-Line "EXPECT_RELAY=desk.funti.cc:21117"
Write-Line "EXPECT_NO_UPSTREAM_RUSTDESK_ENDPOINTS=true"
Write-Line "EXPECT_DIRECT_SERVER_DISABLED=true"
Write-Line "EXPECT_LAN_DISCOVERY_DISABLED=true"
Write-Line "EXPECT_REMOTE_CONFIG_DISABLED=true"
Write-Line "EXPECT_CUSTOM_TXT_IGNORED=true"
Write-Line "EXPECT_EXE_NAME_INFRA_OVERRIDE_IGNORED=true"

Write-Line "REPORT=$report"
Write-Host ""
Write-Host "SECURITY_ACCEPTANCE_CAPTURE_READY=true"
Write-Host "REPORT=$report"
Write-Host ""
Write-Host "Use this report before/after each manual scenario and attach both reports with the client log."
