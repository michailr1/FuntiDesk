[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\.."))
}

function Get-Source([string]$RelativePath) {
    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required source file is missing: $path"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Name) {
    if (-not $Text.Contains($Needle)) {
        throw "FUNTIDESK_BINDING_VALIDATION_FAILED: $Name"
    }
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$Name) {
    if ($Text.Contains($Needle)) {
        throw "FUNTIDESK_BINDING_VALIDATION_FAILED: $Name"
    }
}

$config = Get-Source 'client\libs\hbb_common\src\config.rs'
$common = Get-Source 'client\src\common.rs'
$client = Get-Source 'client\src\client.rs'
$mediator = Get-Source 'client\src\rendezvous_mediator.rs'
$settings = Get-Source 'client\flutter\lib\desktop\pages\desktop_setting_page.dart'

Assert-Contains $config 'pub const RENDEZVOUS_SERVERS: &[&str] = &["desk.funti.cc"];' 'production rendezvous is not desk.funti.cc'
Assert-Contains $config 'pub const RS_PUB_KEY: &str = "2R3kWM1HR3BMoz3EB6KDmv5SjOKrDEVdrZXRcFWaDg4=";' 'production server public key is absent'
Assert-NotContains $config 'rs-ny.rustdesk.com' 'public rendezvous default remains in effective config'
Assert-Contains $config 'pub fn is_locked_server_option(k: &str) -> bool' 'locked server-option policy is absent'
foreach ($option in @('"custom-rendezvous-server"', '"rendezvous-servers"', '"relay-server"', '"api-server"', '"key"', '"other-server-key"')) {
    Assert-Contains $config $option "locked option missing: $option"
}
Assert-Contains $config 'format!("{}:{RENDEZVOUS_PORT}", RENDEZVOUS_SERVERS[0])' 'rendezvous accessor is not compile-time bound'
Assert-Contains $config 'res.retain(|k, _| !Self::is_locked_server_option(k));' 'locked values remain visible through get_options'
Assert-Contains $config 'v.retain(|k, _| !Self::is_locked_server_option(k));' 'bulk settings can retain locked values'

Assert-Contains $common 'pub async fn get_key(_sync: bool) -> String' 'runtime key accessor can accept mutable input'
Assert-Contains $common 'config::RS_PUB_KEY.to_owned()' 'runtime key does not use compiled production key'
Assert-Contains $common 'pub fn read_custom_client(_config: &str)' 'custom-client reader remains active'
Assert-Contains $common 'Ignoring disabled upstream custom-client configuration' 'custom-client no-op marker absent'
Assert-Contains $common 'static STUNS_V4: [&str; 1] = ["desk.funti.cc:21116"];' 'IPv4 NAT helper has a foreign endpoint'
Assert-Contains $common 'static STUNS_V6: [&str; 1] = ["desk.funti.cc:21116"];' 'IPv6 NAT helper has a foreign endpoint'
foreach ($foreignHost in @('stun.l.google.com', 'stun.cloudflare.com', 'stun.nextcloud.com')) {
    Assert-NotContains $common $foreignHost "foreign infrastructure endpoint remains: $foreignHost"
}
Assert-Contains $client 'bail!("Handshake failed: server key mismatch")' 'key mismatch is not fail-closed'
Assert-Contains $client 'Ignoring foreign server suffix in peer ID' 'id@foreign-server route is not blocked'
Assert-NotContains $mediator 'Config::get_option("relay-server")' 'relay runtime override remains active'
Assert-Contains $settings 'const hideServer = true;' 'desktop ID/relay settings remain exposed'

Write-Output 'FUNTIDESK_BINDING_VALIDATION_OK=true'
