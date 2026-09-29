# printer_status.ps1  (HP printers - uses HP's LEDM web service)
# Real printer health, asked of the printer instead of of Windows.
#
# With 'SNMP Enabled' = 0 the Windows queue always reports Normal - it cannot
# see paper-out, jams, or open doors. This asks the device directly over its
# LEDM/EWS web service, which is richer than SNMP and cannot block a print job.
#
# Runs fine unelevated, except the spool-file count (noted in the output).

param(
    [Parameter(Mandatory)][string]$PrinterName,   # exactly as Get-Printer shows it
    [string]$PrinterIP                            # default: read from the printer's TCP/IP port
)

if (-not $PrinterIP) {
    $pp = Get-PrinterPort -Name (Get-Printer -Name $PrinterName -ErrorAction Stop).PortName -ErrorAction SilentlyContinue
    $PrinterIP = $pp.PrinterHostAddress
    if (-not $PrinterIP) { Write-Host "Could not read an IP from the printer's port. Pass -PrinterIP." -ForegroundColor Red; return }
}

function Get-Xml($path) {
    try { [xml](Invoke-WebRequest "http://$PrinterIP$path" -UseBasicParsing -TimeoutSec 10).Content }
    catch { $null }
}

Write-Host ""
Write-Host "  $PrinterName" -ForegroundColor Cyan
Write-Host "  $PrinterIP" -ForegroundColor DarkGray
Write-Host ""

# --- Reachability -----------------------------------------------------------
$raw = Test-NetConnection $PrinterIP -Port 9100 -InformationLevel Quiet -WarningAction SilentlyContinue
$web = Test-NetConnection $PrinterIP -Port 80   -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host "  NETWORK" -ForegroundColor White
Write-Host ("    port 9100 (printing) : {0}" -f $(if($raw){'reachable'}else{'UNREACHABLE'})) `
    -ForegroundColor $(if($raw){'Green'}else{'Red'})
Write-Host ("    port 80   (web ui)   : {0}" -f $(if($web){'reachable'}else{'UNREACHABLE'})) `
    -ForegroundColor $(if($web){'Green'}else{'Red'})

if (-not $raw) {
    Write-Host ""
    Write-Host "    Printer is not answering. Check power and Wi-Fi." -ForegroundColor Red
    Write-Host "    If it moved IP, the TCP/IP port is pinned to $PrinterIP and must be updated." -ForegroundColor Red
    Write-Host ""
    return
}

# --- Device state (what Windows can no longer see) --------------------------
$sx = Get-Xml '/DevMgmt/ProductStatusDyn.xml'
Write-Host ""
Write-Host "  DEVICE" -ForegroundColor White
if ($sx) {
    $state = $sx.ProductStatusDyn.Status.StatusCategory
    # A status node can repeat; take the first meaningful one.
    if ($state -is [array]) { $state = $state[0] }
    $blocking = @('trayEmptyOrOpen','jamInPrinter','doorOpen','cartridgeMissing','outputBinFull')
    $color = if ($state -eq 'ready' -or $state -eq 'processing') { 'Green' }
             elseif ($blocking -contains $state) { 'Red' } else { 'Yellow' }
    Write-Host ("    status : {0}" -f $state) -ForegroundColor $color

    $alerts = $sx.SelectNodes('//*[local-name()="ProductStatusAlertID"]') |
              ForEach-Object { $_.'#text' } |
              Where-Object { $_ -ne 'genuineHP' } | Sort-Object -Unique
    if ($alerts) { Write-Host ("    alerts : {0}" -f ($alerts -join ', ')) -ForegroundColor Yellow }

    switch ($state) {
        'trayEmptyOrOpen'  { Write-Host "    -> LOAD PAPER. Held jobs release on their own, no reprint." -ForegroundColor Red }
        'jamInPrinter'     { Write-Host "    -> Clear the jam." -ForegroundColor Red }
        'doorOpen'         { Write-Host "    -> Close the door/cover." -ForegroundColor Red }
        'cartridgeMissing' { Write-Host "    -> Reseat a cartridge." -ForegroundColor Red }
    }
} else {
    Write-Host "    status : (web service did not answer)" -ForegroundColor Yellow
}

# --- Supplies ---------------------------------------------------------------
$cx = Get-Xml '/DevMgmt/ConsumableConfigDyn.xml'
if ($cx) {
    Write-Host ""
    Write-Host "  SUPPLIES" -ForegroundColor White
    $aftermarket = $false
    foreach ($c in $cx.ConsumableConfigDyn.ConsumableInfo) {
        $measured = -not [string]::IsNullOrWhiteSpace($c.ConsumableUniqueID)
        if (-not $measured) { $aftermarket = $true }
        $pct = $c.ConsumablePercentageLevelRemaining
        Write-Host ("    {0,-2}  {1,3}%  {2}  {3}" -f `
            $c.ConsumableLabelCode, $pct, $c.ConsumableLifeState.ConsumableState,
            $(if($measured){''}else{'(estimated - chip not readable)'})) `
            -ForegroundColor $(if($measured -and [int]$pct -lt 10){'Red'}elseif($measured){'Gray'}else{'DarkGray'})
    }
    if ($aftermarket) {
        Write-Host "    Non-genuine cartridges: percentages are extrapolated, not measured." -ForegroundColor DarkGray
        Write-Host "    Judge toner by the printed page, not these numbers." -ForegroundColor DarkGray
    }
}

# --- Windows side -----------------------------------------------------------
Write-Host ""
Write-Host "  WINDOWS" -ForegroundColor White
$p = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
if ($p) {
    $snmp = try { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\$($p.PortName)" -ErrorAction Stop).'SNMP Enabled' } catch { 'n/a' }
    Write-Host ("    queue  : {0}   jobs: {1}" -f $p.PrinterStatus, $p.JobCount)
    Write-Host ("    port   : {0}" -f $p.PortName)
    Write-Host ("    SNMP   : {0}" -f $(if($snmp -eq 0){'disabled (queue will not flap offline; Windows cannot see device faults)'}else{"ENABLED ($snmp) - may flap offline"})) `
        -ForegroundColor $(if($snmp -eq 0){'Green'}else{'Yellow'})

    if ($p.PortName -notlike 'IP*') {
        Write-Host "    -> Not on a TCP/IP port. WSD causes phantom offline. Re-run set_snmp_off.ps1 setup." -ForegroundColor Red
    }

    $jobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
    foreach ($j in $jobs) {
        Write-Host ("    job {0}: '{1}' {2}  {3}/{4} pages" -f $j.Id, $j.DocumentName, $j.JobStatus, $j.PagesPrinted, $j.TotalPages) -ForegroundColor Yellow
        if ($j.Size -eq 0 -and $j.PagesPrinted -eq 0) {
            Write-Host "      -> already sent to the printer; it is holding it. Fix the DEVICE, not Windows." -ForegroundColor Yellow
        }
    }
    if (-not $jobs) { Write-Host "    no queued jobs" -ForegroundColor Gray }
}

# --- Last print result ------------------------------------------------------
Write-Host ""
Write-Host "  LAST PRINT EVENTS" -ForegroundColor White
$ev = Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Operational' -MaxEvents 60 -ErrorAction SilentlyContinue |
      Where-Object { $_.Id -in 307,824 } | Select-Object -First 4
if ($ev) {
    foreach ($e in $ev) {
        if ($e.Id -eq 307) {
            $pages = if ($e.Message -match 'Pages printed:\s*(\d+)') { $Matches[1] } else { '?' }
            $doc   = if ($e.Message -match 'Document (\d+), (.*?) owned by') { $Matches[2] } else { 'job' }
            Write-Host ("    OK   {0}  {1} - {2} pages printed" -f $e.TimeCreated.ToString('MM/dd HH:mm'), $doc, $pages) -ForegroundColor Green
        } else {
            Write-Host ("    FAIL {0}  job destroyed (event 824 - spooler restarted mid-render?)" -f $e.TimeCreated.ToString('MM/dd HH:mm')) -ForegroundColor Red
        }
    }
} else { Write-Host "    (none recent)" -ForegroundColor Gray }

Write-Host ""
Write-Host "  Note: spool-file counts require elevation; unelevated they falsely read 0." -ForegroundColor DarkGray
Write-Host "  Web UI: http://$PrinterIP    Energy: http://$PrinterIP/hp/device/set_config_energy.html?tab=System&menu=EnergySettings" -ForegroundColor DarkGray
Write-Host ""
