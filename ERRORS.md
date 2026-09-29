# Error log — HP Color LaserJet MFP M283cdw

Every error, wrong diagnosis, and false symptom from the 2026-09-15 session, with
cause and resolution. Ordered as encountered.

Printer: `NPIXXXXXX (HP Color LaserJet MFP M283cdw)` @ `192.168.1.50`
Host: `MY-PC`
Driver: `HP ColorLaserJet MFP M282-M285 PCL-6 (V4)`

---

## E1 — Queue "Offline", jobs "Unknown status"

| | |
|---|---|
| **Where** | Print Queue app, and `Get-Printer` -> `PrinterStatus: Offline` |
| **Real?** | Yes — genuine fault |
| **Cause** | Printer installed on **WSD port** `WSD-<port-guid>`, plus SNMP status polling |
| **Fix** | Standard TCP/IP port, RAW 9100, `SNMP Enabled = 0` |

WSD locates the device by multicast discovery. Sleep, Wi-Fi roam, DHCP renew, or
a router that drops multicast kills the discovery session, and Windows does not
re-discover on its own — the queue keeps the jobs but loses the device.

Compounding it: Windows polls SNMP to decide whether a queue is online. A
sleeping M283cdw stops answering SNMP, Windows reads the silence as "device
gone" and flips the queue Offline **even though port 9100 was reachable the
whole time**. That gap — pings fine, queue dead — is the signature.

**Disabling the printer's sleep timer does not fix this.** Sleep is a trigger,
not the cause.

---

## E2 — `0x800706BE` — print filter pipeline terminated

```
Event 824, 8:41:44
A fatal error occurred while printing job Microsoft Word - Document_A,
id 3 on the print queue NPIXXXXXX (HP Color LaserJet MFP M283cdw).
The print filter pipeline process was terminated.
Error information: 0x800706BE.
```

| | |
|---|---|
| **Real?** | Yes — **self-inflicted** |
| **Cause** | `Restart-Service Spooler -Force` fired while the V4 driver was mid-render on an 86 MB job |
| **Result** | Job destroyed. 45 pages never printed. |

`0x800706BE` = `RPC_S_CALL_FAILED`. Restarting the spooler kills
`printfilterpipelinesvc.exe` with it.

**Queued jobs survive a spooler restart. Rendering jobs do not.** The
distinction matters and is easy to get wrong.

Worse, the failure is silent in the obvious place: `JobCount` drops to 0, which
reads exactly like success. Only event 824 shows the truth. **Never confirm a
print from `JobCount` — confirm from event 307 (`Pages printed: N`).**

**Correct sequence:** pause the queue -> repoint the port -> restart spooler ->
resume. Or simply repoint the port and let the job retry with no restart at all.

---

## E3 — FALSE DIAGNOSIS: "black toner is empty, replace it"

| | |
|---|---|
| **Real?** | **No — wrong call** |
| **Claimed** | `K = 0%` means the black cartridge is dead, a 45-page mono doc will print blank |
| **Reality** | Cartridges are aftermarket. HP cannot measure them. The number is fiction. |

What the printer actually reports:

```
K: 0%   LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
C: 1%   LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
M: 20%  LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
Y: 20%  LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)

All four: SelectibilityNumber 206A, InstallDate 2025-02-12
Alerts: genuineHP x4 (acknowledgeConsumableState), cartridgeVeryLow, cartridgeLow
```

Five tells the percentages are extrapolated, not measured:

1. `ConsumableUniqueID` blank on all four — no readable chip
2. `MeasuredQuantityState` blank — nothing measured
3. `WarrantyStatus` blank — supply not recognized
4. M and Y at *identical* 20%, one shared InstallDate across all four — real
   gauges don't tie
5. `LifeState: ok` on the same cartridge reported at 0%

With no chip, firmware counts pages since the last cartridge-change event and
extrapolates. Meaningless with third-party supplies.

**Empirically disproven the same morning: 40 pages printed clean at "0%" black.**

**Rule: on aftermarket supplies, judge toner by the printed page. Ignore
percentages, `cartridgeVeryLow`, and `genuineHP` alerts. `LifeState` is the only
supply field still worth reading.**

---

## E4 — FALSE SYMPTOM: phantom job in the Print Queue window

Print Queue app showed `Job 3 / Document_A / Unknown status / 45 pages,
86.1 MB` while the spooler held zero jobs and zero spool files. One click of
refresh cleared it.

| | |
|---|---|
| **Real?** | **No — stale UI** |
| **Cause** | The app gets live updates over an RPC change notification from the Spooler. A spooler restart tears down that channel and the app never re-subscribes. |

It keeps painting its last snapshot indefinitely. "Unknown status" is what it
shows for a job record it still holds but can no longer get live status for.
Refresh forces a fresh `EnumJobs`.

The same spooler restart caused three separate problems: killed the render
pipeline (E2), destroyed the job (E2), and orphaned the window displaying it
(E4).

**Rule: after any spooler restart, close and reopen the Print Queue window.
Never diagnose from it. `Get-Printer` / `Get-PrintJob` read the spooler
directly and stayed accurate throughout.**

---

## E5 — `trayEmptyOrOpen` — the actual blocker for Document_B

```
PrinterStatus: trayEmptyOrOpen
Job 3: Document_B.pdf - "Printing, Retained", 0 of 20 pages, Size 0
Spool files: 0
```

| | |
|---|---|
| **Real?** | Yes |
| **Cause** | Paper tray empty |
| **Fix** | Load paper. Job released on its own. |

`Size 0` with spool count 0 means the job had **already streamed to the device**
and the printer was holding it. No reprint needed — loading paper released it.
Status went `trayEmptyOrOpen` -> `processing` -> event 307, `Pages printed: 20`.

Note Windows reported `PrinterStatus: Normal` throughout. **With SNMP disabled,
Windows cannot see printer-side conditions at all** — no paper-out, no cover
open, no jam. That is the deliberate trade for a stable queue. Check the
printer's own EWS for real device state:
`http://192.168.1.50/DevMgmt/ProductStatusDyn.xml`

---

## E6 — Printer port silently changed by HP software

At 08:43:48 (event 306) the printer was repointed from the manually created
`IP_192.168.1.50` to `IP4_<device-uuid>_192.168.1.50`,
created by the HP driver package.

| | |
|---|---|
| **Real?** | Yes, but benign for printing |
| **Impact** | Both are Standard TCP/IP, RAW, `192.168.1.50:9100` |
| **Problem** | The HP port has `SNMP Enabled = 1`, so SNMP polling is back on — the E1 cause has returned |

**Still open.** To apply with an empty queue, elevated:

```powershell
$p = 'IP4_<device-uuid>_192.168.1.50'
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\$p" -Name 'SNMP Enabled' -Value 0 -Type DWord
Restart-Service Spooler   # empty queue only
```

---

## E7 — Pre-existing spooler driver-store errors (not related)

From 2026-09-10, during a driver update. Cosmetic, no action taken:

```
Event 812  failed to delete C:\Windows\system32\spool\DRIVERS\x64\PCC\*.cab, error 0x2
Event 812  failed to delete ...\x64\3\Old\1\PrintConfig.dll, error 0x5
Event 809  failed to recursively delete ...\x64\3\Old, error 0x0
Event 810  failed to delete directory ...\x64\3\Old\1
Event 368  failed to verify driver package "Microsoft enhanced Point and Print
           compatibility driver", Win32 error 2
```

`0x2` = file not found, `0x5` = access denied, on a leftover `Old\1` folder the
spooler could not clean up. Windows regenerates from the driver store. Did not
contribute to E1–E6.

---

## Outcome

| Item | State |
|---|---|
| Queue Offline / Unknown status (E1) | Fixed — WSD -> TCP/IP RAW 9100 |
| Raw data path | Verified — 192-byte PCL test printed |
| Document_A, 45 pp (E2) | **Destroyed, never printed. Needs reprint.** |
| Toner "empty" (E3) | False alarm — cartridges fine |
| Phantom queue entry (E4) | False alarm — stale UI |
| Document_B.pdf (E5) | Printed, 20 pp, event 307 @ 8:50:23 |
| SNMP polling re-enabled (E6) | **Open** |
| Paper stock | Exhausted — restock |

## Diagnostic commands that were actually worth running

```powershell
# Ground truth on queue state - trust this over the Print Queue app
Get-Printer | Select Name,PrinterStatus,PortName,JobCount
Get-PrintJob -PrinterName '<name>'
Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS"

# The only proof a job actually printed - look for event 307 "Pages printed: N",
# and event 824 for silent kills
Get-WinEvent -LogName 'Microsoft-Windows-PrintService/Operational' -MaxEvents 40

# Port config - SNMP=0 is the anti-flapping setting
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\<port>"

# Real device state, which Windows cannot see with SNMP off
Invoke-WebRequest http://192.168.1.50/DevMgmt/ProductStatusDyn.xml -UseBasicParsing
Invoke-WebRequest http://192.168.1.50/DevMgmt/ConsumableConfigDyn.xml -UseBasicParsing

# Data path test that bypasses driver and spooler entirely
$t=New-Object Net.Sockets.TcpClient; $t.Connect('192.168.1.50',9100)
$s=$t.GetStream(); $b=[Text.Encoding]::ASCII.GetBytes("`e%-12345X@PJL`r`n@PJL ENTER LANGUAGE=PCL`r`n`eETEST`f`eE`e%-12345X")
$s.Write($b,0,$b.Length); $s.Flush(); $t.Close()
```

---

## E8 — FALSE ADVICE: "set Shut Down After to Never"

| | |
|---|---|
| **Real?** | **No — bad advice, twice over** |
| **Claimed** | Go to `Settings -> Power Handling` and set *Shut Down After* to *Never* |
| **Reality** | Wrong menu name, and no "Never" option exists on this model |

**Correct location:** `System` tab -> `Energy Settings`
`http://192.168.1.50/hp/device/set_config_energy.html?tab=System&menu=EnergySettings`

Actual controls and their real ranges, read from the page:

```
Sleep/Auto Off After Inactivity : 1 Minute / 5 / 15 / 30 Minutes / 1 Hour
                                  current = 1 Hour   <- already the MAXIMUM

Shut Down After Inactivity      : 2 Hours / 4 Hours / 8 Hours
                                  current = 8 Hours  <- already the MAXIMUM
                                  no "Never" option exists

Delay when ports are active     : [x] CHECKED
```

**Nothing needed changing. Every value was already at its maximum.**

`Delay when ports are active` is HP's Auto-Off/Auto-On technology. It suppresses
the shutdown timer while a network port is active, which is what "Never" was
being reached for. It was already enabled before troubleshooting started.

**Lesson: read the device's actual capability document before telling someone to
change a setting.** `ProductConfigCap.xml` lists every supported value for every
setting — `PowerSaveTimerSupport` and `ShutDownDelaySupport` would have shown
the real ranges and the absence of "Never" in one request:

```powershell
Invoke-WebRequest "http://<ip>/DevMgmt/ProductConfigCap.xml" -UseBasicParsing
```

To find any EWS settings page instead of guessing at URLs, scrape the nav:

```powershell
$r = Invoke-WebRequest "http://<ip>/" -UseBasicParsing
[regex]::Matches($r.Content,'(?i)"([^"]*tab=System[^"]*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

---

## E9 — FALSE PREMISE: Wake-on-LAN would help

| | |
|---|---|
| **Real?** | **No — wrong tool entirely** |
| **Asked** | Could WoL signaling wake the printer for print jobs? |

Three independent reasons it does not apply:

1. **Sleep is not off.** The M283cdw powers down the fuser and engine but keeps
   the network controller fully awake — IP held, Wi-Fi associated, listening on
   9100/80/631. Proven empirically: EWS answered over HTTP and a 192-byte raw
   PCL job printed with no wake step. A device answering HTTP does not need a
   magic packet. The delay felt when printing is fuser warm-up (~10-15s), which
   no network trick shortens.

2. **The printer is on Wi-Fi.** `Wired: Not Connected`, `Wireless: Connected`.
   WoL over wireless requires WoWLAN; the M283cdw does not implement it. When
   powered off the radio drops its association entirely — there is no link for a
   magic packet to arrive on.

3. **Windows has no wake-before-print.** The spooler has no mechanism to emit a
   magic packet ahead of a job. Not vendor-neutral, not present.

The only truly dark state is the 8-hour `ShutDownDelay` — and per E8, that is
already guarded by `Delay when ports are active`.

**Working equivalent if an explicit pre-wake is ever wanted:** a bare TCP connect
to 9100 starts the fuser warming. Largely redundant, since the print job opens
that same connection.

```powershell
$t = New-Object Net.Sockets.TcpClient; $t.Connect('<ip>', 9100); $t.Close()
```

---

## E10 — Port-level settings do not survive being repointed

Observed state after the Round 1 fix:

```
IP4_564e...192.168.1.50   SNMP Enabled = 1    <- LIVE PORT
IP_192.168.1.50           SNMP Enabled = 0    <- configured correctly, unused
```

The fix persisted perfectly. It just stopped being used.

**Port settings live on the port object, not the printer.** The printer holds a
pointer to a port name. HP's driver package created its own port and repointed
the printer (event 306, 08:43:48), orphaning the configured one.

Also note `tcpmon` caches port config at service start — a change needs a
spooler restart to take effect, even though the registry value is on disk
immediately.

**Correction to an earlier claim in this file:** the hand-written `SNMP` value
was junk (the real name is `SNMP Enabled`, with a space), but `Add-PrinterPort`
had already set `SNMP Enabled = 0` on its own. SNMP genuinely was off on that
port between 08:41 and 08:43.

**To make port settings durable:** apply to whichever port the printer currently
uses (never one you just created), delete unused ports so nothing can drift
back, and add a scheduled task that re-asserts the setting after driver updates.

---

## E11 — Unelevated spool-directory checks silently report zero

Every `SpoolFiles: 0` reported during this session was meaningless.

```powershell
(Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -File -ErrorAction SilentlyContinue).Count
```

`C:\Windows\System32\spool\PRINTERS` requires elevation to enumerate. Run
unelevated it throws access-denied, `-ErrorAction SilentlyContinue` swallows the
error, and the pipeline yields **0** — indistinguishable from a genuinely empty
directory. A false all-clear, produced by the exact check meant to prevent
destroying a job.

Caught when `set_snmp_off.ps1` ran elevated and found 3 files where the
unelevated check seconds earlier had reported 0.

**Second bug in the same guard:** it counted *any* file. Those 3 were stale
`.TMP` leftovers from 5/26 and 9/9, not jobs:

```
PPhprl7pv_udtfzroag4xlt0_rb.TMP  28453  5/26/2026
PPm45vtr925f6m7kap6500nadf.TMP   28453  5/26/2026
PPn0t8mxa9bjta5ou3kc8kvy8oc.TMP      0  9/9/2026
```

Only `.SPL` (job data) and `.SHD` (job descriptor) represent real jobs. Counting
`.TMP` made the guard refuse a safe operation.

**Correct check — elevated, extension-filtered:**

```powershell
@(Get-ChildItem "$env:SystemRoot\System32\spool\PRINTERS" -File -Force |
  Where-Object { $_.Extension -match '^\.(SPL|SHD)$' }).Count
```

`Get-PrintJob` needs no elevation and stayed accurate throughout — prefer it as
the primary signal, with the spool count as a cross-check.

**General lesson: `-ErrorAction SilentlyContinue` on a privileged read turns a
permission failure into a confident wrong answer.** Worse than an error.

---

## E12 — Toner percentages moved wildly, confirming E3

Same printer, same cartridges, 3.5 hours apart:

| | 08:45 | 12:22 |
|---|---|---|
| K | 0 % | **100 %** |
| C | 1 % | 0 % |
| M | 20 % | 10 % |
| Y | 20 % | 10 % |

Black reading 0% then 100% settles it. With no readable chip the firmware
extrapolates, and the extrapolation is not stable. 40 pages printed clean while
it claimed 0%.

Confirms E3. **On aftermarket supplies these numbers carry no information.**

---

## Final state — 2026-09-15 12:22

| Item | State |
|---|---|
| Queue Offline / Unknown status (E1) | Fixed — WSD -> TCP/IP RAW 9100 |
| `SNMP Enabled` on live port | **0** — applied and verified |
| Dead port `IP_192.168.1.50` | Removed |
| Dead WSD port | Removal refused (owned by WSD monitor); unreferenced, harmless |
| `Document_A`, 45 pp | **Printed 08:55, 45 pages** (event 307) |
| `Document_B.pdf`, 20 pp | Printed 08:50, 20 pages (event 307) |
| Printer power settings | Already at maximum; nothing to change (E8) |
| Wake-on-LAN | Not applicable (E9) |
| Toner | Unmeasurable; ignore percentages (E3, E12) |
| Windows device visibility | **Gone** — use `printer_status.ps1` |
| Paper stock | Exhausted — restock |

## Files

| File | Purpose |
|---|---|
| `printer_doctor.ps1` | **Start here when printing fails.** Version-one diagnose + guarded recovery, any printer. Read-only by default; `-Fix` for the recovery menu, `-Report` for an escalation file. Needs `PrinterLib.ps1` beside it. |
| `PrinterLib.ps1` | IPP / SNMP / EWS probe library (copied from the printer-diagnostics skill). |
| `printer_status.ps1` | **Daily driver.** Real device health from the printer's own web service — replaces what SNMP-off costs. Run unelevated. |
| `set_snmp_off.ps1` | Applies `SNMP Enabled = 0` to the live port, with a queue guard. Elevated. |
| `fix_printer_port.ps1` | **Retired, not included.** The original WSD -> TCP/IP conversion wrote the wrong SNMP value name (`SNMP`) and restarted the spooler with no queue guard. Use `printer_doctor.ps1 -Preview` / `-Commit` instead. |
| `ERRORS.md` | This file |
| `FIX_NOTES.md` | Session narrative |
| `fix_log.txt` | Timestamped run output |

---

## E13 — The WSD port was bound to the Wi-Fi Direct address

Found 2026-09-23 while building `printer_doctor.ps1`. The orphaned WSD device's
PnP-X record shows where Windows discovered the printer:

```
DEVPKEY_Device_LocationInfo   http://192.168.223.1:3911/
PNPX IpAddress (…96CD 12297)  192.168.223.1
```

`192.168.223.1` is the printer's **Wi-Fi Direct** address (see
the printer's network summary page), not its LAN address `192.168.1.50`. The PC reached the
printer over Wi-Fi Direct at install time. Whenever the PC was on HomeWiFi
instead of the Direct network, the WSD queue pointed at an unreachable address.
That is a second, independent cause of E1.

`printer_doctor.ps1` reads this property for any WSD queue and flags a
`192.168.223.x` discovery address. Consider turning Wi-Fi Direct off in the
printer's EWS if nobody uses it.
