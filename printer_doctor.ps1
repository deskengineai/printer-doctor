# printer_doctor.ps1
# Version-one printer diagnosis and guarded recovery for Windows, any brand.
#
#   .\printer_doctor.ps1                         # diagnose (read-only, unelevated OK)
#   .\printer_doctor.ps1 -PrinterName '<name>'   # one queue
#   .\printer_doctor.ps1 -Preview                # diagnose + show the fix plan, change nothing
#   .\printer_doctor.ps1 -Commit                 # show the plan, one approval, apply it all, before/after
#   .\printer_doctor.ps1 -Select                 # show the plan, pick which changes to apply
#   .\printer_doctor.ps1 -Rollback               # undo the changes recorded in the latest backup
#   .\printer_doctor.ps1 -Fix                    # step-by-step menu of single actions
#   .\printer_doctor.ps1 -Commit -Snmp Off       # also allow turning off Windows SNMP polling
#   .\printer_doctor.ps1 -Report                 # also write an escalation report
#   .\printer_doctor.ps1 -Report-Public          # redacted report, safe to post publicly
#   .\printer_doctor.ps1 -ExpectedNetwork HomeWiFi   # flag when the PC is on another network
#
# Diagnosis never changes the PC. Every recovery action asks first, backs up the
# printer's settings before changing anything, and refuses to restart the
# spooler while a job is rendering (that is what destroyed a 45-page job - see
# ERRORS.md E2).
#
# Lessons from ERRORS.md baked in:
#   E1  WSD port / SNMP polling = "offline while reachable"
#   E2  never restart the spooler mid-render; confirm prints from event 307
#   E4  the Print Queue window goes stale after a spooler restart
#   E5  with SNMP off Windows cannot see paper-out/jam - ask the device (IPP)
#   E10 port settings live on the port; vendor software repoints printers
#   E11 unelevated spool-dir reads silently return 0 - report "unknown" instead

[CmdletBinding()]
param(
    [string]$PrinterName,
    [switch]$Fix,
    [switch]$Preview,
    [Alias('AutoFix')][switch]$Commit,
    [switch]$Select,
    [switch]$Rollback,
    [Alias('Snmp')][ValidateSet('Keep', 'Off')][string]$SnmpPolicy = 'Keep',
    [switch]$Report,
    [Alias('Report-Public')][switch]$ReportPublic,
    [string]$ExpectedNetwork,
    [int]$EventDays = 7,
    [string]$OutDir = $PSScriptRoot
)

. (Join-Path $PSScriptRoot 'PrinterLib.ps1')   # IPP / SNMP / EWS probes
Set-StrictMode -Off
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
$PortsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports'
$Virtual  = '^(nul:|PORTPROMPT:|FILE:|XPS|SHRFAX:|OneNote|Microsoft Print)'

# ===========================================================================
# Findings model
# ===========================================================================
# Checks  : every raw observation, for the technical report
# Causes  : ranked conclusions, for the plain-English diagnosis
$script:Checks = New-Object System.Collections.ArrayList
$script:Causes = New-Object System.Collections.ArrayList

function Add-Check($Area, $Result, $Detail) {
    [void]$script:Checks.Add([pscustomobject]@{ Area = $Area; Result = $Result; Detail = $Detail })
}

# Rank: 1 Likely cause, 2 Possible cause, 3 Needs manual review
function Add-Cause($Rank, $Plain, $Tech, $Next, [string[]]$Actions = @()) {
    $label = @{ 1 = 'Likely cause'; 2 = 'Possible cause'; 3 = 'Needs manual review' }[$Rank]
    [void]$script:Causes.Add([pscustomobject]@{
        Rank = $Rank; Confidence = $label; Plain = $Plain; Tech = $Tech; Next = $Next; Actions = $Actions })
}

function ConvertTo-WqlString([string]$s) { ($s -replace '\\', '\\') -replace "'", "\'" }

function Test-Tcp($HostName, $Port) { Test-PrinterPort -IPAddress $HostName -Port $Port -TimeoutMs 1500 }

function Test-InSubnet([string]$Ip, [string]$Net, [int]$Prefix) {
    try {
        $a = [BitConverter]::ToUInt32([byte[]]([Net.IPAddress]::Parse($Ip).GetAddressBytes()[3..0]), 0)
        $b = [BitConverter]::ToUInt32([byte[]]([Net.IPAddress]::Parse($Net).GetAddressBytes()[3..0]), 0)
        $mask = if ($Prefix -eq 0) { 0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $Prefix)) }
        return (($a -band $mask) -eq ($b -band $mask))
    } catch { return $false }
}

# ===========================================================================
# Pick the printer
# ===========================================================================
$all = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -notmatch $Virtual -and $_.Name -notmatch $Virtual })
if ($PrinterName) {
    $printer = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    if (-not $printer) { Write-Host "No printer named '$PrinterName'. Installed: $((Get-Printer).Name -join '; ')" -ForegroundColor Red; exit 1 }
} elseif ($all.Count -eq 0) {
    Write-Host 'No physical printers are installed on this PC.' -ForegroundColor Red; exit 1
} elseif ($all.Count -eq 1) {
    $printer = $all[0]
} else {
    for ($i = 0; $i -lt $all.Count; $i++) { Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $all[$i].Name, $all[$i].PrinterStatus) }
    $pick = Read-Host 'Which printer? (number)'
    $printer = $all[[int]$pick - 1]
}
$PrinterName = $printer.Name

Write-Host ''
Write-Host "  Diagnosing: $(if ($ReportPublic) { '<printer>  (public mode - screen and report are redacted)' } else { $PrinterName })" -ForegroundColor Cyan
Write-Host ("  {0}   elevated: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $IsAdmin) -ForegroundColor DarkGray
Write-Host ''

# ===========================================================================
# 1. Print Spooler
# ===========================================================================
function Get-SpoolerState {
    $svc = Get-Service Spooler -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Status = $(if ($svc) { "$($svc.Status)" } else { 'missing' }); StartType = $(if ($svc) { "$($svc.StartType)" } else { '' }) }
}
$spooler = Get-SpoolerState
if ($spooler.Status -eq 'Running') {
    Add-Check 'Spooler' 'OK' "Running (start type $($spooler.StartType))"
} else {
    Add-Check 'Spooler' 'FAIL' "Status $($spooler.Status), start type $($spooler.StartType)"
    Add-Cause 1 'The Windows print service (Print Spooler) is not running, so nothing can print.' `
        "Spooler service status = $($spooler.Status)" 'Start the Print Spooler service.' @('RestartSpooler')
}

# ===========================================================================
# 2. Queue: jobs, offline/paused flags
# ===========================================================================
$jobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
$spoolFiles = $null
if ($IsAdmin) {
    # E11: only .SPL/.SHD are jobs; stale .TMP files are noise.
    try {
        $spoolFiles = @(Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -File -Force -ErrorAction Stop |
                        Where-Object { $_.Extension -match '^\.(SPL|SHD)$' }).Count
    } catch { $spoolFiles = $null }   # unreadable -> 'unknown', not a false 0
}
$now = Get-Date
$stuck = @($jobs | Where-Object {
    "$($_.JobStatus)" -match 'Error|Offline|Blocked|Deleting|PaperOut|UserIntervention' -or
    ($_.SubmittedTime -and ($now - $_.SubmittedTime).TotalMinutes -gt 10)
})
$rendering = @($jobs | Where-Object { "$($_.JobStatus)" -match 'Printing|Spooling' -and $_.Size -gt 0 })

Add-Check 'Queue' $(if ($jobs.Count) { 'WARN' } else { 'OK' }) ("{0} job(s) in queue; spool .SPL/.SHD files: {1}" -f $jobs.Count, $(if ($null -eq $spoolFiles) { 'unknown (needs elevation)' } else { $spoolFiles }))
foreach ($j in $jobs) {
    $age = if ($j.SubmittedTime) { [int]($now - $j.SubmittedTime).TotalMinutes } else { '?' }
    Add-Check 'Queue' 'INFO' ("Job {0} '{1}' status='{2}' size={3} pages {4}/{5} age={6} min" -f $j.Id, $j.DocumentName, $j.JobStatus, $j.Size, $j.PagesPrinted, $j.TotalPages, $age)
}

$cim = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName)) -ErrorAction SilentlyContinue
$workOffline = [bool]($cim -and $cim.WorkOffline)
$paused      = ("$($printer.PrinterStatus)" -match 'Paused')
Add-Check 'Queue' $(if ("$($printer.PrinterStatus)" -eq 'Normal') { 'OK' } else { 'WARN' }) ("PrinterStatus={0}  WorkOffline={1}  Paused={2}" -f $printer.PrinterStatus, $workOffline, $paused)

# ===========================================================================
# 3. Port type
# ===========================================================================
$port = Get-PrinterPort -Name $printer.PortName -ErrorAction SilentlyContinue
$pi = [pscustomobject]@{ Name = $printer.PortName; Type = 'Other'; Host = $null; PortNumber = $null; Protocol = $null; Snmp = $null; Community = 'public'; Note = $null }

if ($printer.Type -eq 'Connection' -or $PrinterName -like '\\*') {
    $pi.Type = 'Shared printer'
    $pi.Host = if ($printer.ComputerName) { $printer.ComputerName } elseif ($PrinterName -match '^\\\\([^\\]+)') { $Matches[1] } else { $null }
} elseif ($printer.PortName -like 'WSD-*' -or ($port -and $port.PortMonitor -like 'WSD*')) {
    $pi.Type = 'WSD'
    # WSD hides the address; the PnP-X device records where it was discovered.
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like 'SWD\DAFWSDPROVIDER\URN:UUID:*' -and $_.InstanceId -notlike '*/*' -and $_.FriendlyName -eq $PrinterName } | Select-Object -First 1
    if ($dev) {
        $ipProp = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName '{656A3BB3-ECC0-43FD-8477-4AE0404A96CD} 12297' -ErrorAction SilentlyContinue
        if ($ipProp -and $ipProp.Data) { $pi.Host = @($ipProp.Data)[0] }
    }
} elseif ($port -and $port.PortMonitor -match 'TCPMON') {
    $pi.Type = 'Standard TCP/IP'
    $pi.Host = $port.PrinterHostAddress
    $reg = Get-ItemProperty (Join-Path $PortsKey $printer.PortName) -ErrorAction SilentlyContinue
    if ($reg) {
        $pi.PortNumber = $reg.PortNumber
        $pi.Protocol   = @{ 1 = 'RAW'; 2 = 'LPR' }[[int]$reg.Protocol]
        $pi.Snmp       = $reg.'SNMP Enabled'       # the space is part of the real name
        if ($reg.'SNMP Community') { $pi.Community = $reg.'SNMP Community' }
        if (-not $pi.Host) { $pi.Host = if ($reg.HostName) { $reg.HostName } else { $reg.IPAddress } }
    }
} elseif ($printer.PortName -match '^https?://' -or ($port -and $port.Description -match 'Internet|IPP')) {
    $pi.Type = 'IPP'
    if ($printer.PortName -match '^https?://([^:/]+)(?::(\d+))?') { $pi.Host = $Matches[1]; $pi.PortNumber = $(if ($Matches[2]) { [int]$Matches[2] } else { 631 }) }
} elseif ($printer.PortName -match '^(USB|DOT4|LPT)') {
    $pi.Type = 'USB/local cable'
}
if (-not $pi.Host -and $printer.PortName -match '(\d{1,3}(?:\.\d{1,3}){3})') { $pi.Host = $Matches[1] }

Add-Check 'Port' 'INFO' ("{0}  type={1}  host={2}  port={3}  protocol={4}  SNMP Enabled={5}" -f $pi.Name, $pi.Type, $pi.Host, $pi.PortNumber, $pi.Protocol, $pi.Snmp)

# ===========================================================================
# 4. Network: DNS, ping, print ports, route, VPN, profile
# ===========================================================================
$net = [pscustomobject]@{ Ip = $null; Resolved = $null; Ping = $null; Ports = [ordered]@{}; Iface = $null; ViaVpn = $false; OnLink = $null; Mac = $null }

function Test-Network {
    $n = [pscustomobject]@{ Ip = $null; Resolved = $null; Ping = $null; Ports = [ordered]@{}; Iface = $null; ViaVpn = $false; OnLink = $null; Mac = $null }
    if (-not $pi.Host) { return $n }

    if ($pi.Host -match '^\d{1,3}(\.\d{1,3}){3}$') { $n.Ip = $pi.Host; $n.Resolved = $true }
    else {
        $r = Resolve-DnsName $pi.Host -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
        $n.Resolved = [bool]$r
        if ($r) { $n.Ip = $r.IPAddress }
    }
    if (-not $n.Ip) { return $n }

    $n.Ping = Test-Connection $n.Ip -Count 2 -Quiet -ErrorAction SilentlyContinue
    $want = switch ($pi.Type) {
        'Standard TCP/IP' { if ($pi.Protocol -eq 'LPR') { 515, 80 } else { @($(if ($pi.PortNumber) { $pi.PortNumber } else { 9100 }), 631, 80) } }
        'IPP'             { @($(if ($pi.PortNumber) { $pi.PortNumber } else { 631 }), 80) }
        'Shared printer'  { 445, 135 }
        default           { 9100, 631, 515, 80 }
    }
    foreach ($p in ($want | Select-Object -Unique)) { $n.Ports["$p"] = Test-Tcp $n.Ip $p }

    $route = Find-NetRoute -RemoteIPAddress $n.Ip -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($route) {
        $ad = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        $n.Iface  = "$($route.InterfaceAlias)$(if ($ad) { " ($($ad.InterfaceDescription))" })"
        $n.ViaVpn = ($n.Iface -match 'VPN|AnyConnect|Secure Client|GlobalProtect|Fortinet|Forti|Juniper|Pulse|Zscaler|WireGuard|Tailscale|ZeroTier|OpenVPN|TAP-|Wintun|PANGP|Cisco')
        $local = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        $n.OnLink = [bool](@($local | Where-Object { Test-InSubnet $n.Ip $_.IPAddress $_.PrefixLength }).Count)
    }
    $nb = Get-NetNeighbor -IPAddress $n.Ip -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } | Select-Object -First 1
    if ($nb) { $n.Mac = $nb.LinkLayerAddress }
    return $n
}

if ($pi.Type -ne 'USB/local cable') { $net = Test-Network }

if ($pi.Host) {
    Add-Check 'Network' $(if ($net.Resolved) { 'OK' } else { 'FAIL' }) ("Host '{0}' resolves: {1} -> {2}" -f $pi.Host, $net.Resolved, $net.Ip)
}
if ($net.Ip) {
    Add-Check 'Network' $(if ($net.Ping) { 'OK' } else { 'WARN' }) "Ping $($net.Ip): $(if ($net.Ping) { 'replies' } else { 'no reply (some printers block ping)' })"
    $portText = ($net.Ports.Keys | ForEach-Object { "$_=$(if ($net.Ports[$_]) { 'open' } else { 'closed' })" }) -join '  '
    $anyOpen = @($net.Ports.Values | Where-Object { $_ }).Count -gt 0
    Add-Check 'Network' $(if ($anyOpen) { 'OK' } else { 'FAIL' }) "TCP ports: $portText"
    Add-Check 'Network' $(if ($net.ViaVpn) { 'WARN' } else { 'INFO' }) ("Route to printer via: {0}   same subnet as PC: {1}   MAC: {2}" -f $net.Iface, $net.OnLink, $net.Mac)
}

# PC network identity
$profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
foreach ($pr in $profiles) {
    Add-Check 'PC network' $(if ($pr.NetworkCategory -eq 'Public') { 'WARN' } else { 'INFO' }) ("{0}: '{1}'  category={2}" -f $pr.InterfaceAlias, $pr.Name, $pr.NetworkCategory)
}
$ssid = $null
$wlan = (netsh wlan show interfaces 2>$null) -join "`n"
if ($wlan -match '(?m)^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim(); Add-Check 'PC network' 'INFO' "Wi-Fi SSID: $ssid" }
$vpnUp = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
    $_.Status -eq 'Up' -and ($_.InterfaceDescription + $_.Name) -match 'VPN|AnyConnect|Secure Client|GlobalProtect|Forti|Juniper|Pulse|Zscaler|WireGuard|Tailscale|ZeroTier|OpenVPN|TAP-|Wintun|PANGP' })
foreach ($v in $vpnUp) { Add-Check 'PC network' 'INFO' "VPN/overlay adapter up: $($v.Name) ($($v.InterfaceDescription))" }

$fw = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$(if ($_.Enabled) { 'on' } else { 'off' })" }) -join ' '
if ($fw) { Add-Check 'PC network' 'INFO' "Windows Firewall: $fw" }

# ===========================================================================
# 5. SNMP (only meaningful on Standard TCP/IP ports)
# ===========================================================================
$snmpAnswers = $null
if ($pi.Type -eq 'Standard TCP/IP' -and $net.Ip) {
    $snmpAnswers = [bool](Invoke-SnmpGet -IPAddress $net.Ip -Community $pi.Community -Oids @('1.3.6.1.2.1.1.1.0') -TimeoutMs 2000)
    Add-Check 'SNMP' $(if ($pi.Snmp -eq 1 -and -not $snmpAnswers) { 'WARN' } else { 'INFO' }) ("Windows SNMP status polling: {0}   printer answers SNMP ('{1}'): {2}" -f $(if ($pi.Snmp -eq 1) { 'ON' } else { 'off' }), $pi.Community, $snmpAnswers)
}

# ===========================================================================
# 6. Device status straight from the printer (IPP, then SNMP/EWS)
# ===========================================================================
$device = $null
if ($net.Ip -and $pi.Type -ne 'Shared printer' -and @($net.Ports.Values | Where-Object { $_ }).Count) {
    $device = Get-PrinterDeviceStatus -IPAddress $net.Ip -Community $pi.Community
    if ($device) {
        Add-Check 'Device' $(if ($device.Blocking) { 'FAIL' } else { 'OK' }) ("{0}: state={1}  reasons={2}  model={3}" -f $device.Source, $device.State, $(if ($device.Reasons) { $device.Reasons -join ',' } else { 'none' }), $device.Identity)
    } else {
        Add-Check 'Device' 'SKIP' 'Printer did not answer IPP, SNMP, or its web UI'
    }
}

# ===========================================================================
# 7. Driver
# ===========================================================================
$drv = Get-PrinterDriver -Name $printer.DriverName -ErrorAction SilentlyContinue
$drvMissing = @()
if (-not $drv) {
    Add-Check 'Driver' 'FAIL' "Driver '$($printer.DriverName)' is not installed"
} else {
    foreach ($f in @($drv.DriverPath, $drv.ConfigFile, $drv.DataFile) | Where-Object { $_ }) {
        if (-not (Test-Path $f)) { $drvMissing += $f }
    }
    $ver = if ($drv.DriverVersion) { $v = [uint64]$drv.DriverVersion; '{0}.{1}.{2}.{3}' -f ($v -shr 48), (($v -shr 32) -band 0xFFFF), (($v -shr 16) -band 0xFFFF), ($v -band 0xFFFF) } else { '?' }
    Add-Check 'Driver' $(if ($drvMissing) { 'FAIL' } else { 'OK' }) ("{0}  mfr={1}  v{2}  type={3}  missing files={4}" -f $drv.Name, $drv.Manufacturer, $ver, $(if ($drv.MajorVersion -eq 4) { 'V4' } else { 'V3' }), $(if ($drvMissing) { $drvMissing -join ', ' } else { 'none' }))
}
$generic = $printer.DriverName -match 'Generic|Text Only|Class Driver|IPP Class|Mopria|Point and Print compatibility|Universal Print Class'
$mfrWord = ($PrinterName -split '[\s\(\)]+' | Where-Object { $_ -match '^(HP|Hewlett|Brother|Canon|Epson|Xerox|Lexmark|Kyocera|Ricoh|Samsung|Dell|OKI|Sharp|Konica|Toshiba)' } | Select-Object -First 1)
$mfrMismatch = $drv -and $mfrWord -and $drv.Manufacturer -and ($drv.Manufacturer -notmatch [regex]::Escape($mfrWord.Substring(0, [math]::Min(3, $mfrWord.Length)))) -and -not $generic

# ===========================================================================
# 8. Event log
# ===========================================================================
$since = (Get-Date).AddDays(-$EventDays)
$known = @{
    307 = 'printed OK (the only proof a job printed)'
    372 = 'document failed to print'
    808 = 'spooler failed to load a plug-in module (driver/port monitor)'
    824 = 'job destroyed - filter pipeline killed (spooler restarted mid-render?)'
    842 = 'print processor result'
    812 = 'driver-store cleanup noise (harmless, ERRORS.md E7)'
    809 = 'driver-store cleanup noise (harmless, ERRORS.md E7)'
    810 = 'driver-store cleanup noise (harmless, ERRORS.md E7)'
    368 = 'driver package re-verified from driver store (harmless, ERRORS.md E7)'
    306 = 'printer settings changed (catches software repointing the port)'
    315 = 'failed to share printer'
    6161 = 'document failed to print'
    7031 = 'Print Spooler crashed and was restarted'
    7034 = 'Print Spooler terminated unexpectedly'
}
$events = @()
$opLog = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction SilentlyContinue
foreach ($log in 'Microsoft-Windows-PrintService/Admin', 'Microsoft-Windows-PrintService/Operational') {
    $events += @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $since } -MaxEvents 300 -ErrorAction SilentlyContinue |
                 Where-Object { $_.Level -le 3 -or $_.Id -in 306, 307, 824 })
}
$events += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Id = 7031, 7034, 6161 } -ErrorAction SilentlyContinue |
             Where-Object { $_.Id -eq 6161 -or $_.Message -match 'Spooler' })
$events = @($events | Sort-Object TimeCreated -Descending)
$noiseIds  = 812, 809, 810, 368
$errEvents = @($events | Where-Object { $_.Level -le 2 -and $_.Id -notin $noiseIds })
$noise     = @($events | Where-Object { $_.Id -in $noiseIds })
$codes = @($errEvents | ForEach-Object { if ($_.Message -match '0x[0-9A-Fa-f]+') { "$($_.Id):$($Matches[0])" } } | Sort-Object -Unique)
$killed = @($events | Where-Object { $_.Id -eq 824 })
$repoint = @($events | Where-Object { $_.Id -eq 306 -and $_.Message -match [regex]::Escape($PrinterName) })
$lastOk  = $events | Where-Object { $_.Id -eq 307 -and $_.Message -match [regex]::Escape($PrinterName) } | Select-Object -First 1

Add-Check 'Events' $(if ($errEvents) { 'WARN' } else { 'OK' }) ("Last {0} days: {1} error, {2} warning, {3} harmless driver-store noise; error codes (id:code): {4}" -f $EventDays, $errEvents.Count, @($events | Where-Object { $_.Level -eq 3 }).Count, $noise.Count, $(if ($codes) { $codes -join ', ' } else { 'none' }))
if ($opLog -and -not $opLog.IsEnabled) { Add-Check 'Events' 'WARN' 'PrintService/Operational log is DISABLED - no record of what printed. Enable: wevtutil sl Microsoft-Windows-PrintService/Operational /e:true' }
if ($lastOk) {
    $pg = if ($lastOk.Message -match 'Pages printed:\s*(\d+)') { $Matches[1] } else { '?' }
    Add-Check 'Events' 'OK' ("Last confirmed print: {0}, {1} pages (event 307)" -f $lastOk.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $pg)
}
foreach ($e in ($events | Where-Object { $_.Id -ne 307 -and $_.Id -notin $noiseIds } | Select-Object -First 8)) {
    $meaning = if ($known.ContainsKey($e.Id)) { $known[$e.Id] } else { (($e.Message -split "`n")[0]).Trim() }
    if ($meaning.Length -gt 140) { $meaning = $meaning.Substring(0, 137) + '...' }
    Add-Check 'Events' 'INFO' ("{0}  id {1}  {2}  {3}" -f $e.TimeCreated.ToString('MM-dd HH:mm'), $e.Id, $e.LevelDisplayName, $meaning)
}

# ===========================================================================
# 9. Static vs DHCP (best effort - Windows cannot see the printer's config)
# ===========================================================================
$StatePath = Join-Path $OutDir 'printer_doctor_state.json'
$prev = $null
if (Test-Path $StatePath) { try { $prev = (Get-Content $StatePath -Raw | ConvertFrom-Json).$PrinterName } catch { } }
$ipMoved = $false
if ($net.Mac -and $prev -and $prev.Mac -and $prev.Ip) {
    if ($prev.Mac -eq $net.Mac -and $prev.Ip -ne $net.Ip) { $ipMoved = $true }
    if ($prev.Ip -eq $net.Ip -and $prev.Mac -ne $net.Mac) { $ipMoved = $true }
}
$ipNote = if ($pi.Type -eq 'WSD') { 'WSD follows the device, but rediscovery fails often' }
          elseif ($ipMoved) { "CHANGED since last run (was $($prev.Ip) / $($prev.Mac))" }
          elseif ($pi.Host -and $pi.Host -notmatch '^\d') { 'port uses a hostname - survives IP changes if DNS is right' }
          else { 'pinned IP - cannot tell from the PC whether the printer uses DHCP; check its network page' }
Add-Check 'IP stability' $(if ($ipMoved) { 'FAIL' } else { 'INFO' }) $ipNote

# ===========================================================================
# Diagnosis rules - ordered by how often they are the answer
# ===========================================================================
$reachable = $net.Ip -and @($net.Ports.Values | Where-Object { $_ }).Count -gt 0
$statusOff = "$($printer.PrinterStatus)" -match 'Offline|Error|NotAvailable' -or $workOffline

if ($pi.Type -eq 'WSD') {
    $wd = if ($pi.Host -match '^192\.168\.223\.') { " It was discovered at $($pi.Host), which is the printer's Wi-Fi Direct address, not its normal network address." } else { '' }
    Add-Cause $(if ($statusOff) { 1 } else { 2 }) `
        "The printer is installed using WSD auto-discovery, which loses track of the printer after it sleeps, roams Wi-Fi, or gets a new address.$wd" `
        "Port $($pi.Name) (WSD). PnP-X discovery IP=$($pi.Host). Queue status=$($printer.PrinterStatus). WSD does not rediscover reliably (ERRORS.md E1)." `
        'Move the printer to a Standard TCP/IP port pointed at its real IP address.' @('ReAddTcpIp', 'OpenPortUI')
}
if ($pi.Host -and -not $net.Resolved) {
    Add-Cause 1 "Windows cannot look up the printer's name '$($pi.Host)'." `
        "Resolve-DnsName $($pi.Host) returned nothing." 'Point the port at the printer IP address instead of its name.' @('ReAddTcpIp', 'OpenPortUI')
}
if ($net.Ip -and -not $reachable) {
    if ($net.ViaVpn) {
        Add-Cause 1 'Traffic to the printer is going through a VPN, which cannot reach your local printer.' `
            "Find-NetRoute $($net.Ip) -> $($net.Iface). All print ports closed." 'Disconnect the VPN (or enable its "local LAN access" option), then re-test.' @('Retest')
    } elseif ($net.OnLink -eq $false) {
        Add-Cause 1 "The printer's address $($net.Ip) is not on the same network as this PC." `
            "No local IPv4 subnet contains $($net.Ip); route via $($net.Iface)." 'Connect the PC to the printer''s network, or find the printer''s new IP and update the port.' @('Retest', 'ReAddTcpIp')
    } elseif ($ipMoved) {
        Add-Cause 1 'The printer appears to have changed IP address.' "Last run: $($prev.Ip) / $($prev.Mac). Now: $($net.Ip) / $($net.Mac)." `
            'Update the port to the new IP, then reserve that IP on the router.' @('ReAddTcpIp')
    } else {
        Add-Cause 1 'The printer is not answering on the network. It may be off, asleep past its shutdown timer, off Wi-Fi, or on a new IP address.' `
            ("Ping={0}; TCP {1}" -f $net.Ping, (($net.Ports.Keys | ForEach-Object { "$_=$($net.Ports[$_])" }) -join ' ')) `
            'Check the printer is on and shows a network connection on its panel; print its network config page to confirm its IP.' @('Retest')
    }
}
if ($pi.Type -eq 'Standard TCP/IP' -and $pi.Snmp -eq 1) {
    if ($reachable -and -not $snmpAnswers) {
        Add-Cause $(if ($statusOff) { 1 } else { 2 }) `
            'Windows checks whether the printer is online using SNMP, and the printer is not answering those checks even though it accepts print jobs. Windows then marks it Offline by mistake.' `
            "Port $($pi.Name): 'SNMP Enabled'=1, community '$($pi.Community)'. SNMP GET sysDescr to $($net.Ip):161 got no reply while TCP $(($net.Ports.Keys | Where-Object { $net.Ports[$_] }) -join ',') open. Queue=$($printer.PrinterStatus)." `
            "Keep SNMP: turn on SNMP read access (community '$($pi.Community)') on the printer's web page. Or turn off Windows SNMP polling (-Snmp Off) - Windows then stops showing paper-out and jams." @('DisableSnmp')
    } elseif ($statusOff -and $reachable) {
        Add-Cause 2 'Windows SNMP status monitoring is on, and the queue shows offline while the printer is reachable.' `
            "SNMP answered now, but sleep can stop replies intermittently (E1). Queue=$($printer.PrinterStatus)." 'If this keeps recurring and you do not need SNMP alerts, turn off Windows SNMP polling (-Snmp Off).' @('DisableSnmp')
    }
}
if ($workOffline -or $paused) {
    Add-Cause 1 ("The print queue is set to {0} in Windows." -f $(if ($paused) { 'Paused' } else { '"Use Printer Offline"' })) `
        "Win32_Printer.WorkOffline=$workOffline; PrinterStatus=$($printer.PrinterStatus)" `
        $(if ($reachable) { 'Set the printer back online.' } else { 'Fix the network first; setting it online will not help while it is unreachable.' }) @('SetOnline')
}
if ($device -and $device.Blocking) {
    Add-Cause 1 ("The printer itself needs attention: {0}." -f ($device.Reasons -join ', ')) `
        "$($device.Source) state=$($device.State) reasons=$($device.Reasons -join ',')" `
        $(if ($device.Reasons -match 'media') { 'Load paper / clear the jam. A job already sent will print on its own - do NOT resend it.' } else { 'Fix the condition shown on the printer panel.' })
}
if ($stuck.Count) {
    Add-Cause $(if ($reachable) { 1 } else { 2 }) "$($stuck.Count) print job(s) are stuck in the queue." `
        (($stuck | ForEach-Object { "job $($_.Id) '$($_.DocumentName)' $($_.JobStatus) size=$($_.Size)" }) -join '; ') `
        $(if (@($stuck | Where-Object { $_.Size -eq 0 }).Count) { 'Jobs with size 0 are already at the printer - fix the device, do not clear them.' } else { 'Clear the stuck jobs, then resend.' }) @('ClearJobs')
}
if (-not $drv -or $drvMissing) {
    Add-Cause 1 'The printer driver is missing or damaged.' "Driver '$($printer.DriverName)' present=$([bool]$drv); missing files: $($drvMissing -join ', ')" `
        'Reinstall the manufacturer''s driver, then re-add the printer.' @('ReAddTcpIp')
} elseif ($generic) {
    Add-Cause 2 'The printer uses a generic Windows driver. It usually prints, but can produce wrong output or lose features.' `
        "Driver '$($printer.DriverName)' (mfr $($drv.Manufacturer))." 'Install the manufacturer''s driver if output is wrong.'
} elseif ($mfrMismatch) {
    Add-Cause 2 "The driver is from '$($drv.Manufacturer)' but the printer name suggests '$mfrWord'." "Driver $($printer.DriverName)" 'Confirm the right model driver is installed.'
}
if ($killed.Count) {
    Add-Cause 2 "$($killed.Count) job(s) in the last $EventDays days were destroyed mid-print and never came out." `
        $((($killed | Select-Object -First 3 | ForEach-Object { "$($_.TimeCreated.ToString('MM-dd HH:mm')) id 824" }) -join '; ') + " codes: $($codes -join ',')") `
        'Resend those documents. Avoid restarting the spooler while something is printing.'
}
if ($repoint.Count -and $pi.Type -eq 'Standard TCP/IP' -and $pi.Snmp -eq 1 -and $SnmpPolicy -eq 'Off') {
    Add-Cause 2 'Software changed this printer''s settings recently, and SNMP monitoring is back on.' `
        "Event 306 x$($repoint.Count), latest $($repoint[0].TimeCreated). Vendor driver packages recreate ports with SNMP on (E10)." 'Disable SNMP on the live port again.' @('DisableSnmp')
}
if ($ExpectedNetwork -and $ssid -and $ssid -ne $ExpectedNetwork) {
    Add-Cause 1 "This PC is on Wi-Fi '$ssid', not the expected '$ExpectedNetwork'." "netsh wlan SSID=$ssid" "Connect to '$ExpectedNetwork'."
}
$publicIf = $profiles | Where-Object { $_.NetworkCategory -eq 'Public' -and $net.Iface -and $net.Iface -like "$($_.InterfaceAlias)*" }
if ($publicIf -and $pi.Type -in 'WSD', 'Shared printer') {
    Add-Cause 2 "Windows treats '$($publicIf.Name)' as a Public network, which blocks printer discovery and sharing." `
        "NetConnectionProfile $($publicIf.InterfaceAlias) = Public; port type $($pi.Type) needs network discovery / File and Printer Sharing." `
        'If this is your home or office network, set it to Private in Settings > Network > Wi-Fi > (network) > Network profile type.'
}
if ($spooler.Status -eq 'Running' -and $events | Where-Object { $_.Id -in 7031, 7034 }) {
    Add-Cause 2 'The Print Spooler has crashed recently.' "Service Control Manager 7031/7034 in last $EventDays days" 'Often a faulty driver - update or reinstall the printer driver.'
}
if ($pi.Type -eq 'Standard TCP/IP' -and $pi.Host -match '^\d' -and -not $ipMoved -and $pi.Snmp -ne 1) {
    Add-Cause 3 'The printer port is pinned to a fixed IP. If the printer uses DHCP, a new address will break printing again.' `
        "Port host $($pi.Host). Cannot read the printer's DHCP state from Windows." 'Reserve this IP for the printer on your router (DHCP reservation).'
}
if (-not @($script:Causes | Where-Object { $_.Rank -le 2 }).Count) {
    Add-Cause 3 $(if ($pi.Type -eq 'Standard TCP/IP' -and $pi.Snmp -eq 0) { 'Windows sees no problem. With SNMP off, Windows cannot see paper-out, jams, or open covers - check the printer''s own screen.' } else { 'No fault found from this PC.' }) `
        "Queue=$($printer.PrinterStatus); reachable=$reachable; device=$(if ($device) { "$($device.State) $($device.Reasons -join ',')" } else { 'not queried' })" `
        'Print a test page. If it does not come out, generate the escalation report.' @('Report')
}

$Sorted = @($script:Causes | Sort-Object Rank)

# Public mode: everything identifying is replaced before the file is written.
# Document names, user/PC names, printer name, network names, VPN adapters and
# SNMP community become numbered placeholders (so lines still correlate);
# IPs keep only the first two octets, MACs only the vendor prefix, GUIDs go.
function New-Redactor {
    $lit = New-Object System.Collections.Generic.List[object]
    $add = {
        param($value, $placeholder)
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -lt 2) { return }
        if (@($lit | Where-Object { $_[0] -eq $value }).Count) { return }
        $lit.Add(@($value, $placeholder))
    }

    # Document names - from the queue and from every event message.
    $docs = New-Object System.Collections.Generic.List[string]
    foreach ($j in $jobs) { if ($j.DocumentName) { $docs.Add($j.DocumentName) } }
    foreach ($e in $events) {
        foreach ($rx in 'Document \d+, (.+?) owned by', 'printing job (.+?), id \d+', 'document (.+?), owned by') {
            if ($e.Message -match $rx) { $docs.Add($Matches[1]) }
        }
    }
    $n = 0; foreach ($d in ($docs | Sort-Object -Unique)) { $n++; & $add $d "<document-$n>" }

    & $add $PrinterName '<printer>'
    if ($PrinterName -match '^(\S+)\s+\(') { & $add $Matches[1] '<printer-host>' }
    if ($pi.Host -and $pi.Host -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { & $add $pi.Host '<printer-host>' }
    if ($pi.Community -and $pi.Community -ne 'public') { & $add $pi.Community '<snmp-community>' }
    & $add $env:USERPROFILE 'C:\Users\<user>'
    & $add $env:COMPUTERNAME '<pc>'
    & $add $env:USERNAME '<user>'
    if ($env:USERDOMAIN -ne $env:COMPUTERNAME) { & $add $env:USERDOMAIN '<domain>' }
    & $add $ssid '<wifi>'
    & $add $ExpectedNetwork '<expected-wifi>'
    $n = 0; foreach ($pr in $profiles) { $n++; & $add $pr.Name "<network-$n>" }
    $n = 0; foreach ($v in $vpnUp) { $n++; & $add $v.InterfaceDescription "<vpn-adapter-$n>"; & $add $v.Name "<vpn-$n>" }
    foreach ($ad in @(Get-NetAdapter -ErrorAction SilentlyContinue)) { & $add $ad.InterfaceDescription '<adapter>' }

    $ordered = @($lit | Sort-Object { $_[0].Length } -Descending)
    $octet = '(?:25[0-5]|2[0-4]\d|1?\d?\d)'
    return {
        param([string]$t)
        foreach ($pair in $ordered) {
            $t = [regex]::Replace($t, '(?<![\w])' + [regex]::Escape($pair[0]) + '(?![\w])', $pair[1].Replace('$', '$$'), 'IgnoreCase')
        }
        # Hex/digit lookarounds, not \b: port names glue these to '_' (IP4_<uuid>_<ip>),
        # and a sentence can end right after an IP.
        $t = $t -replace '(?i)(?<![0-9a-f])[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}(?![0-9a-f])', '<guid>'
        $t = $t -replace '(?i)(?<![0-9a-f])([0-9a-f]{2})[:-]([0-9a-f]{2})[:-]([0-9a-f]{2})[:-][0-9a-f]{2}[:-][0-9a-f]{2}[:-][0-9a-f]{2}(?![0-9a-f])', '$1-$2-$3-xx-xx-xx'
        $t = $t -replace "(?<!\d)(?<!\d\.)($octet)\.($octet)\.$octet\.$octet(?!\d)(?!\.\d)", '$1.$2.x.x'
        # 3+ colons, '::' allowed; clock times (HH:mm:ss) have only 2.
        $t = $t -replace '(?i)(?<![\w:])[0-9a-f]{1,4}(?::[0-9a-f]{0,4}){3,7}(?![\w:])', '<ipv6>'
        $t = $t -replace '\\\\[^\\\s|]+', '\\<server>'
        $t = $t -replace '(?i)\b[\w.+-]+@[\w-]+(\.[\w-]+)+\b', '<email>'
        $t = $t -replace '(?i)\bowned by (?!<)\S+', 'owned by <user>'
        $t = $t -replace '(?i)C:\\Users\\(?!<user>)[^\\\s]+', 'C:\Users\<user>'
        return $t
    }.GetNewClosure()
}

# ===========================================================================
# Output: plain English, then technical
# ===========================================================================
# -Report-Public redacts the screen too - people paste terminal output as often as files.
$show = { param($t) $t }
if ($ReportPublic) { $show = New-Redactor }
$rc = @{ 1 = 'Red'; 2 = 'Yellow'; 3 = 'Cyan' }
Write-Host '  DIAGNOSIS' -ForegroundColor White
$n = 0
foreach ($c in $Sorted) {
    $n++
    Write-Host (& $show ("  {0}. [{1}] {2}" -f $n, $c.Confidence, $c.Plain)) -ForegroundColor $rc[$c.Rank]
    Write-Host (& $show ("     Next step: {0}" -f $c.Next))
}
Write-Host ''
Write-Host '  TECHNICAL REPORT' -ForegroundColor White
$colors = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray'; SKIP = 'DarkGray' }
foreach ($ch in $script:Checks) {
    Write-Host (& $show ("  {0,-4} {1,-12} {2}" -f $ch.Result, $ch.Area, $ch.Detail)) -ForegroundColor $colors[$ch.Result]
}
foreach ($c in $Sorted) { Write-Host (& $show ("  EVID {0,-12} {1}" -f "#$([array]::IndexOf($Sorted, $c) + 1)", $c.Tech)) -ForegroundColor DarkGray }
if (-not $IsAdmin) { Write-Host '  Note: not elevated - spool-file count unknown, recovery actions will need an elevated window.' -ForegroundColor DarkGray }
Write-Host ''

# Remember identity for next run's IP-change check.
if ($net.Ip -and $net.Mac) {
    try {
        $st = if (Test-Path $StatePath) { Get-Content $StatePath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $st | Add-Member -NotePropertyName $PrinterName -NotePropertyValue ([pscustomobject]@{ Ip = $net.Ip; Mac = $net.Mac; Seen = (Get-Date -Format s) }) -Force
        $st | ConvertTo-Json | Set-Content $StatePath -Encoding utf8
    } catch { }
}

# ===========================================================================
# Escalation report
# ===========================================================================
function Write-EscalationReport([switch]$Public) {
    $kind = if ($Public) { 'escalation_public' } else { 'escalation' }
    $path = Join-Path $OutDir ("{0}_{1}.md" -f $kind, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# Printer escalation report$(if ($Public) { ' (redacted for public posting)' })"); $L.Add('')
    $L.Add("| | |"); $L.Add("|---|---|")
    $L.Add("| Generated | $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME ($([Environment]::OSVersion.VersionString)) |")
    $L.Add("| Printer | $PrinterName |")
    $L.Add("| Queue status | $($printer.PrinterStatus), jobs $($jobs.Count), WorkOffline $workOffline |")
    $L.Add("| Port | $($pi.Name) |")
    $L.Add("| Port type | $($pi.Type) $(if ($pi.Protocol) { "($($pi.Protocol) $($pi.PortNumber))" }) |")
    $L.Add("| Printer IP | $($net.Ip) (host '$($pi.Host)', MAC $($net.Mac)) |")
    $L.Add("| Ping | $($net.Ping) |")
    $L.Add("| Print ports | $(($net.Ports.Keys | ForEach-Object { "$_=$($net.Ports[$_])" }) -join ', ') |")
    $L.Add("| SNMP on port / printer answers | $($pi.Snmp) / $snmpAnswers |")
    $L.Add("| Device (IPP/SNMP/EWS) | $(if ($device) { "$($device.Source) $($device.State) $($device.Reasons -join ',')" } else { 'no answer' }) |")
    $L.Add("| Driver | $($printer.DriverName) $(if ($drvMissing) { "- MISSING FILES" }) |")
    $L.Add("| Spooler | $((Get-SpoolerState).Status) |")
    $L.Add("| Route / VPN | $($net.Iface) / $($net.ViaVpn) |")
    $L.Add("| Recent error codes | $(if ($codes) { $codes -join ', ' } else { 'none' }) |")
    $L.Add(''); $L.Add('## Diagnosis'); $L.Add('')
    $i = 0; foreach ($c in $Sorted) { $i++; $L.Add("$i. **$($c.Confidence):** $($c.Plain)  "); $L.Add("   Evidence: ``$($c.Tech)``  "); $L.Add("   Next: $($c.Next)") }
    $L.Add(''); $L.Add('## All checks'); $L.Add(''); $L.Add('```')
    foreach ($ch in $script:Checks) { $L.Add(("{0,-4} {1,-12} {2}" -f $ch.Result, $ch.Area, $ch.Detail)) }
    $L.Add('```'); $L.Add(''); $L.Add("## Recent print events (last $EventDays days)"); $L.Add(''); $L.Add('```')
    foreach ($e in ($events | Select-Object -First 25)) {
        if ($Public) {
            # Raw event text carries document names and usernames - use the meaning instead.
            $meaning = if ($known.ContainsKey($e.Id)) { $known[$e.Id] } else { 'print service event' }
            if ($e.Id -eq 307 -and $e.Message -match 'Pages printed:\s*(\d+)') { $meaning += " - $($Matches[1]) pages" }
            if ($e.Message -match '0x[0-9A-Fa-f]+') { $meaning += " [$($Matches[0])]" }
        } else {
            $meaning = (($e.Message -split "`n")[0]).Trim()
        }
        $L.Add(("{0}  {1,5}  {2,-11} {3}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.Id, $e.LevelDisplayName, $meaning))
    }
    $L.Add('```')

    $out = @($L)
    if ($Public) {
        $redact = New-Redactor
        $out = @($out | ForEach-Object { & $redact $_ })
        $out += ''
        $out += '---'
        $out += '*Redacted: document names, user/PC/domain names, printer name, Wi-Fi and network names, VPN and adapter names, SNMP community, GUIDs, raw event text. IPs keep the first two octets; MACs keep the vendor prefix only. Kept for diagnosis: port type, driver, status, error codes, firewall and network-profile state.*'
    }
    try { $out | Set-Content $path -Encoding utf8 -ErrorAction Stop }
    catch { Write-Host "  Could not write the report: $($_.Exception.Message)" -ForegroundColor Red; return $null }
    Write-Host "  $(if ($Public) { 'Public (redacted) report' } else { 'Escalation report' }): $(if ($Public) { "$(Split-Path $path -Leaf)  ($(if ($OutDir -eq $PSScriptRoot) { 'next to the script' } else { 'in the -OutDir folder' }))" } else { $path })" -ForegroundColor Green
    if (-not $Public) { Write-Host '  Contains your PC name, username and document names - use -Report-Public before posting it anywhere public.' -ForegroundColor DarkGray }
    return $path
}

if ($Report) { [void](Write-EscalationReport) }
if ($ReportPublic) { [void](Write-EscalationReport -Public) }

# ===========================================================================
# Recovery - shared helpers. Every change asks first; in -Commit mode the
# one plan approval stands in for the per-step questions, except deleting jobs.
# ===========================================================================
$script:AutoMode = $false
$script:StepOk   = $false

# Strip a byte-order mark and whitespace - piped answers can carry both.
# The console decodes a UTF-8 BOM as U+FEFF, or as 3 junk chars: cp437 (OEM) or cp1252 (ANSI).
function Clear-Answer([string]$a) { return ("$a" -replace '^(\uFEFF|\u2229\u2557\u2510|\u00EF\u00BB\u00BF)', '').Trim() }

function Confirm-Action([string]$What, [switch]$Always) {
    if ($script:AutoMode -and -not $Always) { Write-Host "  [approved in plan] $What" -ForegroundColor DarkGray; return $true }
    $a = Read-Host "  $What  Type Y to proceed"
    return ((Clear-Answer $a) -match '^(y|yes)$')
}
function Require-Admin {
    if ($IsAdmin) { return $true }
    Write-Host '  This action needs an elevated PowerShell (Run as administrator). Nothing changed.' -ForegroundColor Yellow
    return $false
}

# The port the printer uses right now, and its SNMP setting, read fresh each call.
function Get-LivePort {
    $name = (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue).PortName
    $key  = Join-Path $PortsKey $name
    $tcp  = [bool]($name -and (Test-Path $key))
    return [pscustomobject]@{
        Name = $name; Key = $key; IsTcpIp = $tcp
        Snmp = $(if ($tcp) { (Get-ItemProperty $key -ErrorAction SilentlyContinue).'SNMP Enabled' } else { $null })
        Host = $(if ($tcp) { (Get-PrinterPort -Name $name -ErrorAction SilentlyContinue).PrinterHostAddress } else { $null })
    }
}

# An address safe to pin a TCP/IP port to: answers on 9100 and is not the Wi-Fi Direct link (E13).
function Get-CandidateIp {
    if ($net.Ip -and $net.Ip -notmatch '^192\.168\.223\.' -and (Test-Tcp $net.Ip 9100)) { return $net.Ip }
    return $null
}

# SNMP for a NEW port. Some people rely on SNMP (paper-out / jam alerts in Windows),
# so it is kept unless -Snmp Off - but never pointed at a printer that ignores it,
# because polling a silent printer is exactly what flips the queue Offline (E1).
$script:SnmpProbe = $null
function Get-NewPortSnmp {
    if ($SnmpPolicy -eq 'Off') { return [pscustomobject]@{ On = $false; Why = 'you chose -Snmp Off' } }
    $old = Get-LivePort
    if ($old.IsTcpIp) { return [pscustomobject]@{ On = ($old.Snmp -eq 1); Why = "same as the current port" } }
    if ($null -eq $script:SnmpProbe -and $net.Ip) {
        $script:SnmpProbe = [bool](Invoke-SnmpGet -IPAddress $net.Ip -Community $pi.Community -Oids @('1.3.6.1.2.1.1.1.0') -TimeoutMs 2000)
    }
    if ($script:SnmpProbe) { return [pscustomobject]@{ On = $true;  Why = 'the printer answers SNMP, so Windows can keep reporting paper-out and jams' } }
    return [pscustomobject]@{ On = $false; Why = "the printer does not answer SNMP ('$($pi.Community)'), and polling it would mark the queue Offline" }
}

$script:BackupDone = $false
$script:BackupDir  = $null
$script:Manifest   = $null

# rollback.json: what -Rollback needs to put things back. Written before the first
# change, then updated as the script creates ports or finishes actions.
function Save-Manifest {
    if ($script:BackupDir) { $script:Manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:BackupDir 'rollback.json') -Encoding utf8 }
}
function Add-ManifestItem([string]$Field, [string]$Value) {
    if (-not $script:Manifest) { return }
    $script:Manifest[$Field] = @($script:Manifest[$Field]) + $Value
    Save-Manifest
}

function Backup-PrinterSettings {
    if ($script:BackupDone) { return $true }
    $dir = Join-Path $OutDir ("backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $lp = Get-LivePort
    $wo = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName)) -ErrorAction SilentlyContinue
    $script:BackupDir = $dir
    $script:Manifest  = [ordered]@{
        Printer = $PrinterName; Taken = (Get-Date -Format s)
        PortName = $lp.Name; PortIsTcpIp = $lp.IsTcpIp; SnmpEnabled = $lp.Snmp
        WorkOffline = [bool]($wo -and $wo.WorkOffline)
        CreatedPorts = @(); Done = @()
    }
    Save-Manifest
    $p = Get-Printer -Name $PrinterName
    $p | Select-Object * | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dir 'printer.json') -Encoding utf8
    Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue | Select-Object * | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dir 'port.json') -Encoding utf8
    Get-PrintConfiguration -PrinterName $PrinterName -ErrorAction SilentlyContinue | Select-Object * | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dir 'print_config.json') -Encoding utf8
    $regPort = "HKLM\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\$($p.PortName)"
    if (Test-Path "Registry::$regPort") { & reg.exe export $regPort (Join-Path $dir 'port.reg') /y | Out-Null }
    & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Control\Print\Printers\$PrinterName" (Join-Path $dir 'printer.reg') /y 2>$null | Out-Null
    Write-Host "  Backed up printer settings to $dir" -ForegroundColor Green
    Write-Host "  Restore: reg import the .reg files, or Set-Printer -Name '$PrinterName' -PortName '$($p.PortName)'" -ForegroundColor DarkGray
    $script:BackupDone = $true
    return $true
}

# E2: the guard the retired fix_printer_port.ps1 lacked.
function Test-SafeToRestart {
    $allJobs = @(Get-Printer | ForEach-Object { Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue })
    $busy = @($allJobs | Where-Object { "$($_.JobStatus)" -match 'Printing|Spooling|Rendering' })
    if ($busy.Count) {
        Write-Host "  REFUSED: job(s) are printing/rendering right now:" -ForegroundColor Red
        $busy | ForEach-Object { Write-Host "    job $($_.Id) '$($_.DocumentName)' $($_.JobStatus)" -ForegroundColor Red }
        Write-Host '  Changing the port or restarting the spooler now could destroy them (0x800706BE). Wait for them to finish.' -ForegroundColor Red
        return $false
    }
    if ($allJobs.Count) {
        Write-Host "  $($allJobs.Count) queued (not rendering) job(s) exist. Queued jobs survive a restart." -ForegroundColor Yellow
    }
    return $true
}

function Invoke-SpoolerRestart {
    if (-not (Test-SafeToRestart)) { return $false }
    Restart-Service Spooler -Force
    Start-Sleep -Seconds 3
    Write-Host "  Spooler: $((Get-Service Spooler).Status)" -ForegroundColor Green
    Write-Host '  Close and reopen any Print Queue window - it will show stale jobs otherwise.' -ForegroundColor DarkGray
    return ((Get-Service Spooler).Status -eq 'Running')
}

# ===========================================================================
# The actions. Each sets $script:StepOk only when it finished, so -Commit
# can stop at the first step that did not.
# ===========================================================================
function Invoke-RecoveryAction([string]$Key) {
    $script:StepOk = $false
    try { Invoke-RecoveryActionCore $Key }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:StepOk = $false
    }
    if ($script:StepOk -and $Key -in 'RestartSpooler', 'ClearJobs', 'SetOnline', 'ReAddTcpIp', 'DisableSnmp') { Add-ManifestItem 'Done' $Key }
}

function Invoke-RecoveryActionCore([string]$Key) {
    switch ($Key) {
        'Backup' {
            if (Confirm-Action "Write a backup of '$PrinterName' settings to $($OutDir)?") { $script:StepOk = [bool](Backup-PrinterSettings) }
        }
        'RestartSpooler' {
            if (-not (Require-Admin)) { break }
            if (Confirm-Action 'Restart the Print Spooler service?') { $script:StepOk = [bool](Invoke-SpoolerRestart) }
        }
        'ClearJobs' {
            if (-not (Require-Admin)) { break }
            $j = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
            if (-not $j.Count) { Write-Host '  Queue is already empty.' -ForegroundColor Green; $script:StepOk = $true; break }
            $j | ForEach-Object { Write-Host ("    job {0} '{1}' {2} size={3}" -f $_.Id, $_.DocumentName, $_.JobStatus, $_.Size) }
            if (@($j | Where-Object { $_.Size -eq 0 }).Count) { Write-Host '  Size-0 jobs are already at the printer - clearing them cancels a print that may still come out.' -ForegroundColor Yellow }
            # Always asked, even in -Commit: deleted jobs are gone for good.
            if (-not (Confirm-Action "Delete these $($j.Count) job(s)? They will NOT print and must be resent." -Always)) { break }
            $j | ForEach-Object { Remove-PrintJob -InputObject $_ -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
            $left = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
            if ($left.Count -and (Confirm-Action "$($left.Count) job(s) would not delete. Stop the spooler and remove their .SPL/.SHD files?" -Always)) {
                Stop-Service Spooler -Force
                Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -File -Force | Where-Object { $_.Extension -match '^\.(SPL|SHD)$' } | Remove-Item -Force
                Start-Service Spooler
            }
            $remaining = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue).Count
            Write-Host "  Jobs remaining: $remaining" -ForegroundColor $(if ($remaining) { 'Yellow' } else { 'Green' })
            $script:StepOk = ($remaining -eq 0)
        }
        'SetOnline' {
            if (-not $reachable -and $pi.Type -ne 'USB/local cable') {
                Write-Host '  The printer is not reachable on the network, so setting it online will not fix printing.' -ForegroundColor Yellow
            }
            if (-not (Confirm-Action "Clear 'Use Printer Offline' and resume '$PrinterName'?")) { break }
            [void](Backup-PrinterSettings)
            $w = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName))
            if ($w.WorkOffline) { Set-CimInstance -InputObject $w -Property @{ WorkOffline = $false } -ErrorAction Stop }
            Invoke-CimMethod -InputObject $w -MethodName Resume -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2
            $w2 = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName))
            Write-Host "  Status now: $((Get-Printer -Name $PrinterName).PrinterStatus), Use Printer Offline: $($w2.WorkOffline)" -ForegroundColor Green
            $script:StepOk = $true
        }
        'Retest' {
            $r = Test-Network
            Write-Host ("  resolves={0} ip={1} ping={2} ports: {3}  route={4}" -f $r.Resolved, $r.Ip, $r.Ping, (($r.Ports.Keys | ForEach-Object { "$_=$($r.Ports[$_])" }) -join ' '), $r.Iface)
            $script:StepOk = $true
        }
        'ReAddTcpIp' {
            if (-not (Require-Admin)) { break }
            $default = Get-CandidateIp
            if ($script:AutoMode) { $ip = $default }
            else {
                $ip = Read-Host "  Printer IP address$(if ($default) { " [$default]" })"
                if (-not $ip) { $ip = $default }
            }
            if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-Host '  No usable IPv4 address. Nothing changed - get it from the printer''s network configuration page.' -ForegroundColor Yellow; break }
            if (-not (Test-Tcp $ip 9100)) { Write-Host "  $ip is not answering on 9100. Nothing changed - confirm the IP from the printer's network page." -ForegroundColor Yellow; break }
            $newPort = "IP_$ip"
            $s = Get-NewPortSnmp
            $exists = [bool](Get-PrinterPort -Name $newPort -ErrorAction SilentlyContinue)
            $what = if ($exists) { "existing port $newPort (its settings are left as they are)" } else { "new port $newPort (RAW 9100, SNMP $(if ($s.On) { 'on' } else { 'off' }) - $($s.Why))" }
            if (-not (Confirm-Action "Point '$PrinterName' at $($what)?")) { break }
            if (-not (Test-SafeToRestart)) { break }
            [void](Backup-PrinterSettings)
            $oldPort = (Get-LivePort).Name
            if (-not $exists) {
                if ($s.On) { Add-PrinterPort -Name $newPort -PrinterHostAddress $ip -PortNumber 9100 -SNMP 1 -SNMPCommunity $pi.Community -ErrorAction Stop }
                else       { Add-PrinterPort -Name $newPort -PrinterHostAddress $ip -PortNumber 9100 -ErrorAction Stop }
                Add-ManifestItem 'CreatedPorts' $newPort
            }
            Set-Printer -Name $PrinterName -PortName $newPort -ErrorAction Stop
            Write-Host "  '$PrinterName' now uses $newPort. Old port '$oldPort' kept for rollback." -ForegroundColor Green
            $pi.Name = $newPort; $pi.Type = 'Standard TCP/IP'; $pi.Host = $ip; $pi.PortNumber = 9100; $pi.Protocol = 'RAW'; $pi.Snmp = $(if ($s.On) { 1 } else { 0 })
            Write-Host '  Print a test page. Confirm success from event 307 (Pages printed: N), not from the queue emptying.' -ForegroundColor DarkGray
            Write-Host '  Reserve this IP on the router so it cannot change (DHCP reservation).' -ForegroundColor DarkGray
            $script:StepOk = $true
        }
        'OpenPortUI' {
            if (Confirm-Action "Open the Ports tab for '$PrinterName'? (Printer properties > Ports > Add Port > Standard TCP/IP Port)") {
                Start-Process rundll32.exe -ArgumentList "printui.dll,PrintUIEntry /p /t3 /n `"$PrinterName`""
                $script:StepOk = $true
            }
        }
        'DisableSnmp' {
            # Re-read now, not from startup: option 6 or vendor software may have moved the printer (E10).
            $live = Get-LivePort
            if (-not $live.IsTcpIp) { Write-Host "  '$PrinterName' is on port '$($live.Name)', which is not Standard TCP/IP. SNMP monitoring only applies to TCP/IP ports - move it first (option 6)." -ForegroundColor Yellow; break }
            if ($live.Snmp -ne 1) { Write-Host "  SNMP status monitoring is already off on '$($live.Name)' (the port in use right now). Nothing to do." -ForegroundColor Green; $script:StepOk = $true; break }
            $answersNow = if ($net.Ip) { [bool](Invoke-SnmpGet -IPAddress $net.Ip -Community $pi.Community -Oids @('1.3.6.1.2.1.1.1.0') -TimeoutMs 2000) } else { $null }
            Write-Host '  WHY this is suspected:' -ForegroundColor White
            Write-Host "    - Port '$($live.Name)' (in use now) has 'SNMP Enabled' = $($live.Snmp)"
            Write-Host "    - Printer accepts print connections: $(($net.Ports.Keys | Where-Object { $net.Ports[$_] }) -join ', ')"
            Write-Host "    - Printer answered an SNMP query just now: $answersNow"
            Write-Host "    - Windows queue status: $($printer.PrinterStatus)"
            Write-Host '    Windows marks the queue Offline whenever SNMP goes quiet (e.g. printer asleep), even though printing works.'
            Write-Host '  TRADE-OFF: with SNMP off, Windows will always show "Ready" - it can no longer report paper-out, jams, or open covers.' -ForegroundColor Yellow
            if ($answersNow) { Write-Host '  The printer IS answering SNMP right now. If you rely on SNMP alerts, you may prefer to keep it on.' -ForegroundColor Yellow }
            if (-not (Require-Admin)) { break }
            if (-not (Confirm-Action 'Disable SNMP status monitoring and restart the spooler to apply it?')) { break }
            if (-not (Test-SafeToRestart)) { break }
            [void](Backup-PrinterSettings)
            Set-ItemProperty -Path $live.Key -Name 'SNMP Enabled' -Value 0 -Type DWord -ErrorAction Stop
            $restarted = Invoke-SpoolerRestart   # tcpmon reads port config at start (E10)
            $after = Get-LivePort
            Write-Host "  'SNMP Enabled' on $($after.Name) is now $($after.Snmp)." -ForegroundColor Green
            Write-Host '  Vendor driver updates can re-create the port with SNMP on. Re-run this doctor after driver updates.' -ForegroundColor DarkGray
            $script:StepOk = ($after.Snmp -eq 0 -and $restarted)
        }
        'Report'       { $script:StepOk = [bool](Write-EscalationReport) }
        'ReportPublic' { $script:StepOk = [bool](Write-EscalationReport -Public) }
        'Rollback'     { $script:StepOk = [bool](Invoke-Rollback) }
    }
}

# ===========================================================================
# Fix plan - built from the diagnosis plus a fresh read of the queue and port.
#   change : the script does it (needs the plan approved)
#   you    : a person has to do it - the script cannot
# ===========================================================================
function New-FixPlan {
    $plan = New-Object System.Collections.ArrayList
    $add = {
        param($Action, $Kind, $Title, $Why, $Changes, $Admin)
        [void]$plan.Add([pscustomobject]@{ Action = $Action; Kind = $Kind; Title = $Title; Why = $Why; Changes = @($Changes); Admin = [bool]$Admin })
    }
    $handled = @()
    $live    = Get-LivePort
    $jobsNow = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
    $cimNow  = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName)) -ErrorAction SilentlyContinue
    $offNow  = [bool]($cimNow -and $cimNow.WorkOffline)
    $pauseNow = ("$((Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue).PrinterStatus)" -match 'Paused')
    $svc     = (Get-SpoolerState).Status

    if ($svc -ne 'Running') {
        & $add 'RestartSpooler' 'change' 'Start the Print Spooler' 'Nothing can print while it is stopped.' @("Print Spooler service: $svc -> Running") $true
        $handled += 'RestartSpooler'
    }

    # Port: WSD, a name that no longer resolves, or a printer that changed IP -> Standard TCP/IP.
    if (-not $live.IsTcpIp -and $pi.Type -eq 'WSD' -or ($pi.Host -and -not $net.Resolved) -or $ipMoved) {
        $ip = Get-CandidateIp
        if ($ip) {
            $s = Get-NewPortSnmp
            & $add 'ReAddTcpIp' 'change' 'Move the printer to a Standard TCP/IP port' `
                $(if ($pi.Type -eq 'WSD') { 'WSD loses track of the printer after sleep or a Wi-Fi change (E1).' } else { 'The current port no longer reaches the printer.' }) `
                @("Create port IP_$ip -> ${ip}:9100 (RAW)",
                  "SNMP status monitoring on the new port: $(if ($s.On) { 'ON' } else { 'OFF' }) - $($s.Why)",
                  "Printer port: '$($live.Name)' -> 'IP_$ip'",
                  "Old port '$($live.Name)' is kept, so you can switch back") $true
        } else {
            & $add '' 'you' "Find the printer's current IP address" 'The printer did not answer on a usable address, so the script cannot pick one safely.' `
                @('Print the network configuration page from the printer''s control panel',
                  'Then run -Fix, choose 6, and enter that address') $false
        }
        $handled += 'ReAddTcpIp', 'OpenPortUI'
    }

    # Stuck jobs. Size-0 jobs are already inside the printer - never clear those automatically.
    $stuckNow  = @($jobsNow | Where-Object { "$($_.JobStatus)" -match 'Error|Offline|Blocked|Deleting|PaperOut|UserIntervention' -or ($_.SubmittedTime -and ((Get-Date) - $_.SubmittedTime).TotalMinutes -gt 10) })
    $clearable = @($stuckNow | Where-Object { $_.Size -gt 0 })
    $atPrinter = @($stuckNow | Where-Object { $_.Size -eq 0 })
    if ($clearable.Count) {
        & $add 'ClearJobs' 'change' 'Clear stuck print jobs' 'They block the queue. You will be asked again before anything is deleted.' `
            @($clearable | ForEach-Object { "Delete job $($_.Id) '$($_.DocumentName)' ($($_.JobStatus)) - it will NOT print; resend it after" }) $true
    }
    if ($atPrinter.Count) {
        & $add '' 'you' 'Check the printer itself' 'These jobs were already sent to the printer, which is holding them.' `
            @('Look at the printer''s screen: paper, jam, open cover', 'Once fixed they print on their own - do not resend them') $false
    }
    $handled += 'ClearJobs'

    if ($offNow -or $pauseNow) {
        if ($reachable) {
            & $add 'SetOnline' 'change' 'Set the printer online' 'Windows is holding jobs back on purpose.' `
                @($(if ($offNow) { "'Use Printer Offline': on -> off" }), $(if ($pauseNow) { 'Queue: Paused -> resumed' }) | Where-Object { $_ }) $false
        } else {
            & $add '' 'you' 'Reconnect the printer first' 'Setting it online will not help while it is unreachable.' @('Fix the network problem listed below, then re-run') $false
        }
        $handled += 'SetOnline'
    }

    # SNMP false-offline: printer takes jobs but ignores SNMP while Windows polls it.
    if ($live.IsTcpIp -and $live.Snmp -eq 1 -and $reachable -and -not $snmpAnswers) {
        if ($SnmpPolicy -eq 'Off') {
            & $add 'DisableSnmp' 'change' 'Turn off Windows SNMP status monitoring' "Windows polls SNMP, the printer does not reply, so Windows marks it Offline (E1)." `
                @("Port '$($live.Name)': 'SNMP Enabled' 1 -> 0",
                  'Restart the Print Spooler to apply it (only if nothing is printing)',
                  'Trade-off: Windows stops reporting paper-out, jams and open covers') $true
        } else {
            & $add '' 'you' 'Make the printer answer SNMP (keeps SNMP on)' "Windows polls the printer with SNMP community '$($pi.Community)' and gets no reply, so it marks the queue Offline." `
                @("On the printer's web page (http://$($net.Ip)), turn on SNMPv1/v2 read-only access",
                  "Make sure its community name is '$($pi.Community)' - the name Windows uses",
                  'Or, if you do not need SNMP alerts, re-run with -Snmp Off to stop Windows polling instead') $false
        }
        $handled += 'DisableSnmp'
    }

    # Everything else the diagnosis found that a script cannot fix.
    foreach ($c in ($Sorted | Where-Object { $_.Rank -le 2 })) {
        if (@($c.Actions | Where-Object { $handled -contains $_ }).Count) { continue }
        if ($c.Plain -match 'SNMP' -and $handled -contains 'DisableSnmp') { continue }
        if (@($c.Actions | Where-Object { $_ -notin 'Retest', 'Report', 'ReportPublic' }).Count) { continue }   # has an action but no auto step - offered in the menu
        & $add '' 'you' $c.Plain $c.Confidence @($c.Next) $false
    }

    if (@($plan | Where-Object Kind -eq 'change').Count) {
        $plan.Insert(0, [pscustomobject]@{ Action = 'Backup'; Kind = 'change'; Title = 'Back up the printer''s settings'; Why = 'So every change below can be undone.'
            Changes = @("Save printer, port and registry settings to a backup_<date> folder in $(if ($OutDir -eq $PSScriptRoot) { 'the script folder' } else { $OutDir })"); Admin = $false })
    }
    return ,$plan
}

function Show-FixPlan($plan) {
    $changes = @($plan | Where-Object Kind -eq 'change')
    Write-Host ''
    Write-Host ("  FIX PLAN   SNMP: {0}" -f $(if ($SnmpPolicy -eq 'Off') { 'Off - Windows SNMP polling may be turned off' } else { 'Keep - Windows SNMP settings are not turned off (use -Snmp Off to allow it)' })) -ForegroundColor White
    if (-not $plan.Count) { Write-Host '  Nothing to fix - no problem was found that a change on this PC would solve.' -ForegroundColor Green; return }
    $i = 0
    foreach ($s in $plan) {
        $i++
        $tag   = if ($s.Kind -eq 'change') { $(if ($s.Admin) { 'change, admin' } else { 'change' }) } else { 'you' }
        $color = if ($s.Kind -eq 'change') { 'Yellow' } else { 'Cyan' }
        Write-Host (& $show ("  {0}. [{1}] {2}" -f $i, $tag, $s.Title)) -ForegroundColor $color
        if ($s.Why) { Write-Host (& $show "       Why: $($s.Why)") -ForegroundColor DarkGray }
        foreach ($c in $s.Changes) { Write-Host (& $show "       $(if ($s.Kind -eq 'change') { '+' } else { '-' }) $c") }
    }
    Write-Host ''
    if ($changes.Count) {
        Write-Host "  $($changes.Count) change(s) on this PC. Nothing outside this list will be changed." -ForegroundColor White
        if (@($changes | Where-Object Admin).Count -and -not $IsAdmin) { Write-Host '  Some steps need an elevated PowerShell (Run as administrator).' -ForegroundColor Yellow }
    } else {
        Write-Host '  No changes on this PC would help. The [you] steps above need a person.' -ForegroundColor White
    }
}

function Get-StateSnapshot {
    $p  = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
    $lp = Get-LivePort
    $w  = Get-CimInstance Win32_Printer -Filter ("Name='{0}'" -f (ConvertTo-WqlString $PrinterName)) -ErrorAction SilentlyContinue
    $h  = if ($lp.Host) { $lp.Host } else { $net.Ip }
    return [ordered]@{
        'Queue status'     = "$($p.PrinterStatus)"
        'Use offline flag' = "$([bool]($w -and $w.WorkOffline))"
        'Port'             = "$($lp.Name)"
        'SNMP monitoring'  = $(if ($lp.IsTcpIp) { if ($lp.Snmp -eq 1) { 'on' } else { 'off' } } else { 'n/a (not TCP/IP)' })
        'Jobs in queue'    = "$(@(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue).Count)"
        'Printer on 9100'  = $(if ($h) { "$(Test-Tcp $h 9100)" } else { 'unknown' })
        'Print Spooler'    = "$((Get-SpoolerState).Status)"
    }
}

function Show-BeforeAfter($before, $after) {
    Write-Host ('  {0,-18} {1,-28} {2}' -f '', 'before', 'after') -ForegroundColor DarkGray
    foreach ($k in $before.Keys) {
        $changed = $before[$k] -ne $after[$k]
        Write-Host (& $show ('  {0,-18} {1,-28} {2}' -f $k, $before[$k], $after[$k])) -ForegroundColor $(if ($changed) { 'Green' } else { 'Gray' })
    }
}

# Pick plan steps by the numbers Show-FixPlan printed. Backup is always kept.
function Select-PlanSteps($plan) {
    $changeNums = @(for ($i = 0; $i -lt $plan.Count; $i++) { if ($plan[$i].Kind -eq 'change' -and $plan[$i].Action -ne 'Backup') { $i + 1 } })
    if (-not $changeNums.Count) { return $null }
    $ans = Clear-Answer (Read-Host "  Which changes? Step numbers separated by commas ($($changeNums -join ', ')), Enter to cancel")
    if ([string]::IsNullOrWhiteSpace($ans)) { return $null }
    $picked = @($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Where-Object { $changeNums -contains $_ } | Select-Object -Unique)
    $ignored = @($ans -split '[,\s]+' | Where-Object { $_ -and -not ($_ -match '^\d+$' -and $changeNums -contains [int]$_) })
    if ($ignored.Count) { Write-Host "  Ignored (not a change step): $($ignored -join ', ')" -ForegroundColor Yellow }
    if (-not $picked.Count) { return $null }
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $plan.Count; $i++) {
        if ($plan[$i].Action -eq 'Backup' -or $picked -contains ($i + 1) -or $plan[$i].Kind -eq 'you') { [void]$keep.Add($plan[$i]) }
    }
    return ,$keep
}

function Invoke-FixPlan($plan) {
    $changes = @($plan | Where-Object Kind -eq 'change')
    if (-not $changes.Count) { Write-Host '  Nothing to apply automatically.' -ForegroundColor Green; return }
    if (@($changes | Where-Object Admin).Count -and -not $IsAdmin) {
        Write-Host '  This plan needs an elevated PowerShell (Run as administrator). Nothing changed.' -ForegroundColor Yellow; return
    }
    if (@($changes | Where-Object { $_.Action -in 'ReAddTcpIp', 'DisableSnmp', 'RestartSpooler' }).Count -and -not (Test-SafeToRestart)) {
        Write-Host '  Nothing changed.' -ForegroundColor Yellow; return
    }
    if (-not (Confirm-Action "Apply the $($changes.Count) change(s) above, in order?")) { Write-Host '  Nothing changed.' -ForegroundColor Gray; return }

    $before = Get-StateSnapshot
    $script:AutoMode = $true
    $n = 0; $done = 0
    try {
        foreach ($s in $changes) {
            $n++
            Write-Host ''
            Write-Host ("  STEP {0}/{1}: {2}" -f $n, $changes.Count, $s.Title) -ForegroundColor White
            Invoke-RecoveryAction $s.Action
            if (-not $script:StepOk) {
                Write-Host "  Stopped at step $n. The steps after it were NOT run." -ForegroundColor Red
                break
            }
            $done++
        }
    } finally { $script:AutoMode = $false }

    $after = Get-StateSnapshot
    Write-Host ''
    Write-Host "  RESULT: $done of $($changes.Count) change(s) applied" -ForegroundColor $(if ($done -eq $changes.Count) { 'Green' } else { 'Yellow' })
    Show-BeforeAfter $before $after

    # "In case it breaks": a failed step, or a printer that answered before and not after.
    $broke = ($before['Printer on 9100'] -eq 'True' -and $after['Printer on 9100'] -ne 'True')
    if ($broke) { Write-Host '  WARNING: the printer answered on port 9100 before these changes and does not now.' -ForegroundColor Red }
    if (($done -lt $changes.Count -or $broke) -and $script:BackupDir) {
        # Show what undoing this run would do; Invoke-Rollback asks once before touching anything.
        Write-Host '  You can undo the changes this run made:' -ForegroundColor Yellow
        if (-not (Invoke-Rollback)) { Write-Host '  Not rolled back. Do it later with: .\printer_doctor.ps1 -Rollback' -ForegroundColor DarkGray }
    }
    $manual = @($plan | Where-Object Kind -eq 'you')
    if ($manual.Count) {
        Write-Host ''
        Write-Host '  Still to do by hand:' -ForegroundColor Cyan
        $manual | ForEach-Object { Write-Host (& $show "    - $($_.Title)") -ForegroundColor Cyan }
    }
    Write-Host '  Print a test page. Only event 307 ("Pages printed: N") proves it printed.' -ForegroundColor DarkGray
}

# ===========================================================================
# Rollback - put back what the latest backup recorded for this printer.
# Restores: the printer's port, that port's SNMP setting, and deletes ports this
# script created. Cannot restore: deleted print jobs.
# ===========================================================================
function Get-LatestBackup {
    $dirs = @(Get-ChildItem $OutDir -Directory -Filter 'backup_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($d in $dirs) {
        $f = Join-Path $d.FullName 'rollback.json'
        if (-not (Test-Path $f)) { continue }
        try { $m = Get-Content $f -Raw | ConvertFrom-Json } catch { continue }
        if ($m.Printer -eq $PrinterName) { return [pscustomobject]@{ Dir = $d.FullName; M = $m } }
    }
    return $null
}

function Invoke-Rollback {
    $b = Get-LatestBackup
    if (-not $b) { Write-Host "  No backup with rollback information for this printer in $(if ($OutDir -eq $PSScriptRoot) { 'the script folder' } else { $OutDir }). Nothing to roll back." -ForegroundColor Yellow; return $false }
    $m  = $b.M
    $lp = Get-LivePort
    $origKey = Join-Path $PortsKey $m.PortName
    $snmpNow = if ($m.PortIsTcpIp -and (Test-Path $origKey)) { (Get-ItemProperty $origKey -ErrorAction SilentlyContinue).'SNMP Enabled' } else { $null }

    $moveBack  = ($lp.Name -ne $m.PortName)
    $origThere = [bool](Get-PrinterPort -Name $m.PortName -ErrorAction SilentlyContinue)
    $snmpBack  = ($m.PortIsTcpIp -and $null -ne $m.SnmpEnabled -and $null -ne $snmpNow -and [int]$snmpNow -ne [int]$m.SnmpEnabled)
    $drop      = @(@($m.CreatedPorts) | Where-Object { $_ -and $_ -ne $m.PortName -and (Get-PrinterPort -Name $_ -ErrorAction SilentlyContinue) })

    Write-Host ''
    Write-Host (& $show "  ROLLBACK to $(Split-Path $b.Dir -Leaf)  (taken $($m.Taken))") -ForegroundColor White
    $steps = @()
    if ($moveBack) {
        if ($origThere) { $steps += "Printer port: '$($lp.Name)' -> '$($m.PortName)'" }
        else { Write-Host (& $show "  Cannot move back: the original port '$($m.PortName)' no longer exists. Use -Fix option 6 to create a port instead.") -ForegroundColor Red }
    }
    if ($snmpBack) { $steps += "Port '$($m.PortName)': 'SNMP Enabled' $snmpNow -> $($m.SnmpEnabled) (restarts the Print Spooler to apply)" }
    foreach ($cp in $drop) { $steps += "Delete port '$cp' (created by this script)" }
    foreach ($st in $steps) { Write-Host (& $show "    + $st") }
    if (@($m.Done) -contains 'ClearJobs') { Write-Host '    Not restorable: print jobs deleted in that run - resend them.' -ForegroundColor DarkGray }
    Write-Host '    Left as is: the "Use Printer Offline" flag stays off.' -ForegroundColor DarkGray
    if (-not $steps.Count) { Write-Host '  Settings already match the backup. Nothing to roll back.' -ForegroundColor Green; return $true }

    if (-not (Require-Admin)) { return $false }
    if (-not (Test-SafeToRestart)) { return $false }
    if (-not (Confirm-Action "Roll back these $($steps.Count) change(s)?" -Always)) { Write-Host '  Nothing changed.' -ForegroundColor Gray; return $false }

    $before = Get-StateSnapshot
    $ok = $true
    try {
        if ($moveBack -and $origThere) { Set-Printer -Name $PrinterName -PortName $m.PortName -ErrorAction Stop; Write-Host "  Printer moved back to '$($m.PortName)'." -ForegroundColor Green }
        if ($snmpBack) {
            Set-ItemProperty -Path $origKey -Name 'SNMP Enabled' -Value ([int]$m.SnmpEnabled) -Type DWord -ErrorAction Stop
            if (-not (Invoke-SpoolerRestart)) { $ok = $false }
        }
        foreach ($cp in $drop) {
            if (@(Get-Printer | Where-Object PortName -eq $cp).Count) { Write-Host "  Kept '$cp' - another printer uses it." -ForegroundColor Yellow; continue }
            try { Remove-PrinterPort -Name $cp -ErrorAction Stop; Write-Host "  Deleted port '$cp'." -ForegroundColor Green }
            catch { Write-Host "  Could not delete '$cp' yet ($($_.Exception.Message)). It is unused and harmless; re-run -Rollback later to remove it." -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "  Rollback step failed: $($_.Exception.Message)" -ForegroundColor Red
        $ok = $false
    }
    Write-Host ''
    Write-Host "  ROLLBACK $(if ($ok) { 'finished' } else { 'incomplete' })" -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    Show-BeforeAfter $before (Get-StateSnapshot)
    return $ok
}

# ===========================================================================
# Modes
# ===========================================================================
if ($Rollback) { [void](Invoke-Rollback); Write-Host ''; if (-not $Fix) { return } }
if ($Preview -or $Commit -or $Select) {
    $plan = New-FixPlan
    Show-FixPlan $plan
    if ($Commit) { Invoke-FixPlan $plan }
    elseif ($Select) {
        $sub = Select-PlanSteps $plan
        if ($sub) { Invoke-FixPlan $sub } elseif (@($plan | Where-Object Kind -eq 'change').Count) { Write-Host '  Nothing selected - nothing changed.' -ForegroundColor Gray }
    }
    elseif (@($plan | Where-Object Kind -eq 'change').Count) {
        Write-Host '  Preview only - nothing was changed. Apply it all: -Commit   Pick changes: -Select   One at a time: -Fix' -ForegroundColor DarkGray
    }
    Write-Host ''
    if (-not $Fix) { return }
}
if (-not $Fix) {
    Write-Host "  Diagnosis only - nothing was changed. Next: -Preview to see the fix plan, -Commit to apply it, -Select to pick changes, -Fix for single actions, -Rollback to undo$(if (-not ($Report -or $ReportPublic)) { '; -Report / -Report-Public for an escalation file' })." -ForegroundColor DarkGray
    Write-Host ''
    return
}

$ActionCatalog = [ordered]@{
    Backup         = 'Back up this printer''s settings'
    RestartSpooler = 'Restart the Print Spooler service (guarded)'
    ClearJobs      = 'Clear stuck print jobs'
    SetOnline      = 'Set the printer online / resume the queue'
    Retest         = 'Re-test DNS and network reachability'
    ReAddTcpIp     = 'Move the printer to a Standard TCP/IP port'
    OpenPortUI     = 'Open the Windows port-configuration screen'
    DisableSnmp    = 'Disable Windows SNMP status monitoring on this port'
    Report         = 'Generate an escalation report (private - full detail)'
    ReportPublic   = 'Generate a redacted report, safe to post publicly'
}

$suggested = @($Sorted | ForEach-Object { $_.Actions } | Where-Object { $_ } | Select-Object -Unique)
if ($SnmpPolicy -ne 'Off') { $suggested = @($suggested | Where-Object { $_ -ne 'DisableSnmp' }) }

while ($true) {
    Write-Host '  RECOVERY ACTIONS - step by step' -ForegroundColor White
    Write-Host '  [P] Preview the fix plan (changes nothing)' -ForegroundColor Cyan
    Write-Host '  [C] Commit the whole plan (one approval)' -ForegroundColor Cyan
    Write-Host '  [S] Select which plan changes to apply' -ForegroundColor Cyan
    Write-Host '  [R] Roll back to the latest backup' -ForegroundColor Cyan
    $keys = @($ActionCatalog.Keys)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $tag = if ($suggested -contains $keys[$i]) { '  <- suggested' } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $ActionCatalog[$keys[$i]], $tag) -ForegroundColor $(if ($tag) { 'Yellow' } else { 'Gray' })
    }
    $choice = Clear-Answer (Read-Host '  Choose (Enter to quit)')
    if ([string]::IsNullOrWhiteSpace($choice)) { break }
    Write-Host ''
    if ($choice -match '^[Pp]$') { Show-FixPlan (New-FixPlan); Write-Host ''; continue }
    if ($choice -match '^[CcAa]$') { $plan = New-FixPlan; Show-FixPlan $plan; Invoke-FixPlan $plan; Write-Host ''; continue }
    if ($choice -match '^[Ss]$') { $plan = New-FixPlan; Show-FixPlan $plan; $sub = Select-PlanSteps $plan; if ($sub) { Invoke-FixPlan $sub }; Write-Host ''; continue }
    if ($choice -match '^[Rr]$') { [void](Invoke-Rollback); Write-Host ''; continue }
    $idx = 0
    if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $keys.Count) { continue }
    Invoke-RecoveryAction $keys[$idx - 1]
    Write-Host ''
}
