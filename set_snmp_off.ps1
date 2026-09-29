# set_snmp_off.ps1
# Disables SNMP status polling on whichever port the printer is CURRENTLY using,
# and removes dead ports so nothing can drift back to them.
#
# Unlike the retired fix_printer_port.ps1, this one:
#   - writes 'SNMP Enabled' (the real value name - note the space), not 'SNMP'
#   - targets the live port rather than creating a new one
#   - refuses to restart the spooler unless the queue is genuinely empty
#
# Must run elevated.

param(
    [Parameter(Mandatory)][string]$PrinterName,   # exactly as Get-Printer shows it
    [string[]]$RemovePorts = @()                  # unused ports to delete, e.g. an old WSD-... port
)

$ErrorActionPreference = 'Stop'

$LogPath     = Join-Path $PSScriptRoot 'fix_log.txt'
$PortsRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports'

function Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Output $line
    Add-Content -Path $LogPath -Value $line -Encoding utf8
}

Log "=== set_snmp_off.ps1 start ==="

# 1. Refuse to proceed with anything in the queue. This is the guard that
#    fix_printer_port.ps1 lacked, and its absence destroyed a 45-page job.
#    NOTE: spool\PRINTERS requires elevation to enumerate. Unelevated it throws
#    access-denied, which -ErrorAction SilentlyContinue turns into a count of 0 -
#    a false "all clear". This script runs elevated, so the count is real.
#    Only .SPL (data) and .SHD (descriptor) represent jobs. Stale .TMP files
#    accumulate for months and must not block the restart.
$jobs  = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue)
$all   = @(Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue)
$spool = @($all | Where-Object { $_.Extension -match '^\.(SPL|SHD)$' })
$junk  = @($all | Where-Object { $_.Extension -notmatch '^\.(SPL|SHD)$' })
if ($junk.Count -gt 0) { Log "Ignoring $($junk.Count) stale non-job file(s) in spool dir: $(($junk | Select-Object -Expand Name) -join ', ')" }
if ($jobs.Count -gt 0 -or $spool.Count -gt 0) {
    Log "ABORT: queue not empty ($($jobs.Count) jobs, $($spool.Count) .SPL/.SHD files)."
    Log "Restarting the spooler now would destroy a rendering job. Wait and re-run."
    exit 1
}
Log "Queue empty (0 jobs, 0 .SPL/.SHD) - safe to restart spooler."

# 2. Target the port actually in use, not one we created.
$livePort = (Get-Printer -Name $PrinterName).PortName
Log "Live port: $livePort"

$key = Join-Path $PortsRoot $livePort
if (-not (Test-Path $key)) {
    Log "ABORT: '$livePort' is not a Standard TCP/IP port - nothing to configure."
    exit 1
}

$before = (Get-ItemProperty $key).'SNMP Enabled'
Set-ItemProperty -Path $key -Name 'SNMP Enabled' -Value 0 -Type DWord
Log "'SNMP Enabled' on $livePort : $before -> 0"

# 3. Drop dead ports so HP software (or a future us) cannot drift onto one.
foreach ($dead in $RemovePorts) {
    if ($dead -eq $livePort) { continue }
    try {
        if (Get-PrinterPort -Name $dead -ErrorAction SilentlyContinue) {
            Remove-PrinterPort -Name $dead
            Log "Removed unused port: $dead"
        }
    } catch {
        Log "Could not remove ${dead}: $($_.Exception.Message)"
    }
}

# 4. tcpmon caches port config at service start, so this is required for the
#    change to take effect. Safe - queue was verified empty in step 1.
Restart-Service -Name Spooler -Force
Start-Sleep -Seconds 3
Log "Spooler restarted."

# 5. Verify against the registry, not against assumptions.
$p     = Get-Printer -Name $PrinterName
$after = (Get-ItemProperty (Join-Path $PortsRoot $p.PortName)).'SNMP Enabled'
Log "RESULT: Status=$($p.PrinterStatus)  Port=$($p.PortName)  'SNMP Enabled'=$after  Jobs=$($p.JobCount)"
Log "Remaining TCP/IP ports: $((Get-ChildItem $PortsRoot | Select-Object -Expand PSChildName) -join ', ')"
Log "=== set_snmp_off.ps1 done ==="
