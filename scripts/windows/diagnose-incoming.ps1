#Requires -RunAsAdministrator
# Диагностика входящих подключений FuntiDesk. Только собирает сведения.
# Единственное временное действие — запись пакетов pktmon на портах 21116/21117
# на 120 секунд; запись останавливается и фильтры убираются автоматически.

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = "C:\tmp\fd-diag-$stamp"
New-Item -ItemType Directory -Force $out | Out-Null
function Save($name, $block) { try { & $block 2>&1 | Out-String -Width 300 | Set-Content -Encoding UTF8 (Join-Path $out $name) } catch { "ERROR: $_" | Set-Content (Join-Path $out $name) } }

Write-Host '1/4 Сеть, маршруты, брандмауэр...'
Save 'net-adapters.txt' { Get-NetAdapter | Sort-Object Status | Format-Table -AutoSize Name, InterfaceDescription, Status, LinkSpeed }
Save 'ip.txt' { Get-NetIPAddress -AddressFamily IPv4 | Format-Table -AutoSize InterfaceAlias, IPAddress, PrefixLength }
Save 'routes-default.txt' { Get-NetRoute -DestinationPrefix '0.0.0.0/0','0.0.0.0/1','128.0.0.0/1' -ErrorAction SilentlyContinue | Format-Table -AutoSize InterfaceAlias, DestinationPrefix, NextHop, RouteMetric }
Save 'route-to-server.txt' { Find-NetRoute -RemoteIPAddress 173.249.195.36 | Format-List InterfaceAlias, IPAddress, NextHop }
Save 'firewall-profiles.txt' { Get-NetFirewallProfile | Format-Table -AutoSize Name, Enabled, DefaultInboundAction, DefaultOutboundAction }
Save 'firewall-funtidesk.txt' {
    Get-NetFirewallApplicationFilter | Where-Object { $_.Program -match 'funti|rustdesk' } | ForEach-Object {
        $r = $_ | Get-NetFirewallRule
        [pscustomobject]@{ Program = $_.Program; Name = $r.DisplayName; Enabled = $r.Enabled; Direction = $r.Direction; Action = $r.Action; Profile = $r.Profile }
    } | Format-Table -AutoSize
}
Save 'vpn-proxy-processes.txt' { Get-Process | Where-Object { $_.ProcessName -match 'vpn|anyconnect|csc|cisco|hiddify|v2ray|xray|sing|clash|nekoray|amnezia|warp|wireguard|outline|zscaler|forti|globalprotect|pangp|kaspersky|avp|eset|ekrn|defender|sophos|symantec|mcafee|funti' } | Format-Table -AutoSize ProcessName, Id, Path }
Save 'vpn-proxy-services.txt' { Get-Service | Where-Object { $_.DisplayName -match 'vpn|anyconnect|cisco|hiddify|v2ray|xray|sing-box|clash|amnezia|warp|wireguard|zscaler|forti|globalprotect|kaspersky|eset|sophos|symantec|mcafee' } | Format-Table -AutoSize Name, DisplayName, Status }
Save 'proxy-settings.txt' { netsh winhttp show proxy; Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable, ProxyServer, AutoConfigURL }
Save 'funtidesk-sockets.txt' {
    $ids = (Get-Process FuntiDesk -ErrorAction SilentlyContinue).Id
    'UDP:'; Get-NetUDPEndpoint | Where-Object { $ids -contains $_.OwningProcess } | Format-Table -AutoSize LocalAddress, LocalPort, OwningProcess
    'TCP:'; Get-NetTCPConnection | Where-Object { $ids -contains $_.OwningProcess } | Format-Table -AutoSize LocalAddress, LocalPort, RemoteAddress, RemotePort, State
}

Write-Host '2/4 Запись пакетов на 120 секунд. Напишите Claude: «пишу пакеты» — он отправит запрос на подключение.'
pktmon stop 2>$null | Out-Null
pktmon filter remove | Out-Null
pktmon filter add FD-UDP -p 21116 | Out-Null
pktmon filter add FD-RELAY -p 21117 | Out-Null
$etl = Join-Path $out 'pktmon.etl'
pktmon start --capture --pkt-size 128 --file-name $etl | Out-Null
for ($i = 120; $i -gt 0; $i -= 10) { Write-Host "   осталось $i с..."; Start-Sleep 10 }
pktmon stop | Out-Null
pktmon filter remove | Out-Null
pktmon etl2txt $etl --out (Join-Path $out 'pktmon.txt') | Out-Null
pktmon etl2txt $etl --out (Join-Path $out 'pktmon-drops.txt') --stats-only 2>$null | Out-Null

Write-Host '3/4 Журнал FuntiDesk...'
$log = Join-Path $env:APPDATA 'FuntiDesk\log'
if (Test-Path $log) { Copy-Item $log (Join-Path $out 'funtidesk-log') -Recurse }

Write-Host '4/4 Архив...'
$zip = "C:\tmp\fd-diag-$stamp.zip"
Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
Write-Host ''
Write-Host "Готово: $zip"
Write-Host 'Перешлите этот архив на компьютер minipc (например, в C:\tmp) через «Только передать файлы».'
