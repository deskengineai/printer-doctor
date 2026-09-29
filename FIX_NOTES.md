# HP Color LaserJet MFP M283cdw — "Unknown status" queue fix

**Date:** 2026-09-15
**Printer:** `NPIXXXXXX (HP Color LaserJet MFP M283cdw)` @ 192.168.1.50
**Status:** Port fault fixed, queue reads `Normal`, data path verified.
**See Round 2 at the bottom — the 45-page job did NOT print, and black toner is at 0%.**

---

## Symptom

Print Queue showed:

```
NPIXXXXXX (HP Color LaserJet MFP M283cdw), Job 3
Unknown status
45 pages, 86.1 MB
```

Printer was pingable and awake. Disabling the printer's sleep timer did **not**
help, because sleep was never the root cause.

## Root cause

Two stacked problems, both from the port type:

1. **The printer was installed on a WSD port**
   (`WSD-<port-guid>`). WSD uses multicast discovery
   to locate the device. When the discovery session drops — printer sleeps,
   Wi-Fi roams, DHCP renews, router drops multicast — Windows keeps the queue
   but loses the device handle. The queue then reports `Offline` and individual
   jobs report `Unknown status`. WSD does not reliably re-discover on its own;
   it typically needs a spooler restart or a printer reinstall.

2. **SNMP status polling.** Windows polls the printer over SNMP to decide
   whether the queue is online. A sleeping or busy M283cdw stops answering SNMP,
   Windows reads that silence as "device gone," and flips the queue Offline —
   *even when the print data path on port 9100 is perfectly fine.* This is why
   the printer answered ping but the queue stayed dead.

Verified before changing anything:

```
Test-Connection 192.168.1.50          -> True
Test-NetConnection 192.168.1.50 :9100 -> True   (data path was always healthy)
Test-NetConnection 192.168.1.50 :80   -> True
```

## Fix applied

Ran `fix_printer_port.ps1` (since retired and replaced by `printer_doctor.ps1`) elevated. It:

1. Confirmed the printer answers on RAW 9100 before touching anything.
2. Created a Standard TCP/IP port `IP_192.168.1.50` -> `192.168.1.50:9100`.
3. Set `SNMP=0`, `Protocol=1` (RAW), `PortNumber=9100` under
   `HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\IP_192.168.1.50`.
   SNMP off is the part that stops the Offline flapping — Windows no longer
   guesses at printer state, it just streams bytes to 9100 and the printer
   wakes itself.
4. Repointed the printer off WSD onto the new port.
5. Cleared the `WorkOffline` flag if set.
6. Restarted the spooler so the queued job re-dispatched. **This step was a
   mistake** — see Round 2. Queued jobs survive a spooler restart, but a job
   actively *rendering* does not: the filter pipeline is killed with it.

## Result

```
2026-09-15 08:41:40  Printer reachable at 192.168.1.50:9100.
2026-09-15 08:41:41  Created port IP_192.168.1.50 -> 192.168.1.50:9100.
2026-09-15 08:41:42  Port configured: SNMP=0 (disabled), Protocol=RAW, PortNumber=9100.
2026-09-15 08:41:43  Printer moved from 'WSD-...' to 'IP_192.168.1.50'.
2026-09-15 08:41:50  Spooler restarted.
2026-09-15 08:42:20  RESULT: Status=Normal  Port=IP_192.168.1.50  JobCount=0
```

> **Superseded — see Round 2.** JobCount going to 0 here was read as the job
> printing. It did not. Step 6's spooler restart killed the filter pipeline
> mid-render and destroyed the job (event 824, `0x800706BE`).

## Remaining risk: DHCP

The printer is on **DHCP**, not a static IP:

```
IP Configured By:       DHCP
DHCP Expiration Time:   00:13:33 (Days:Hours:Minutes)
DHCP/BOOTP Server:      192.168.1.1
```

A TCP/IP port is pinned to `192.168.1.50`. If the router hands the printer a
different address, the queue breaks again — this time with a real "cannot
connect," not a phantom offline.

**Do one of these:**

- Add a DHCP reservation for MAC `xx:xx:xx:xx:xx:xx` -> `192.168.1.50` on the
  router at `192.168.1.1`. Preferred — survives printer factory resets.
- Or set a static IP on the printer itself via its web UI at
  `http://192.168.1.50` → Network → IPv4 → Manual IP.

If the address ever does change, run `printer_doctor.ps1 -Fix`, choose option 6 and enter the new address. (Originally: re-run `fix_printer_port.ps1` after editing
`$PrinterIP` at the top.

## Notes for next time

- Never reinstall this printer using "Add a printer" auto-discovery — Windows
  will silently pick WSD again and the problem returns. Always choose
  *Add a local printer or network printer with manual settings* → *Create a new
  port* → *Standard TCP/IP Port*, and uncheck "Query the printer and
  automatically select the driver to use."
- Printer sleep settings are irrelevant to this failure and can be left at the
  HP default. See [sleep settings.png](sleep%20settings.png) for what was
  changed during troubleshooting; it can be reverted.
- Old WSD port `WSD-<port-guid>` was left in place
  (harmless, unreferenced). Remove with:
  `Remove-PrinterPort -Name 'WSD-<port-guid>'`

---

# Round 2 — 2026-09-15 08:45: "says printing but nothing comes out"

## Correction to Round 1

Round 1 above claimed the 45-page job "cleared the queue on its own." **That was
wrong.** The job did not print. It was destroyed.

PrintService/Operational event log:

```
8:41:42  Id 801  Printing job 3.
8:41:42  Id 306  Settings for printer ... were changed.
8:41:44  Id 824  ERROR - A fatal error occurred while printing job
                 Microsoft Word - Document_A, id 3.
                 The print filter pipeline process was terminated.
                 Error information: 0x800706BE.
```

`0x800706BE` is `RPC_S_CALL_FAILED`. Step 6 of `fix_printer_port.ps1`
(`Restart-Service Spooler -Force`) killed `printfilterpipelinesvc.exe` while the
V4 driver was mid-render on an 86 MB job. JobCount dropped to 0 because the job
died, not because it printed.

**Lesson:** never `Restart-Service Spooler -Force` with a job actively
rendering. Repoint the port, then let the job retry, or pause the queue first
and resume after. The script has been left as-is but should not be re-run while
a job is in the queue.

## Second, independent cause: black toner is empty

`http://192.168.1.50/DevMgmt/ConsumableConfigDyn.xml`:

```
K (Black)    level =   0 %   <-- empty
C (Cyan)     level =   1 %   <-- effectively empty
M (Magenta)  level =  20 %
Y (Yellow)   level =  20 %
```

`ProductStatusDyn.xml` alerts: `cartridgeVeryLow` / StrictWarning on Black,
`cartridgeLow` on Cyan. Printer's own status string still reads `Ready`.

A 45-page mono Word document with black at 0% will produce blank or ghost pages
even when everything else is correct. If the printer's "Very Low" cartridge
policy is set to *Stop*, it halts outright and no page is produced at all.

## Data path verified good

Sent 192 bytes of raw PCL directly to `192.168.1.50:9100`, bypassing the driver
and spooler entirely. The page printed. That proves:

- the TCP/IP port fix from Round 1 is working,
- the network path, port 9100, and the printer's engine are all healthy,
- the failure was the killed filter pipeline plus the empty black cartridge, not
  the port.

## Port changed again (cosmetic, not a fault)

At 08:43:48 the printer was repointed from `IP_192.168.1.50` to
`IP4_<device-uuid>_192.168.1.50`, created by the HP
driver package. Both are Standard TCP/IP, RAW, `192.168.1.50:9100`, so printing
works either way.

**One difference that matters:** the HP-created port has no `SNMP` registry
value, so SNMP status polling is back on. That is the setting that caused the
original Offline flapping. It has NOT been changed yet, because applying it
requires a spooler restart and a job was printing.

To apply later, when the queue is empty, elevated:

```powershell
$p = 'IP4_<device-uuid>_192.168.1.50'
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\$p" -Name SNMP -Value 0 -Type DWord
Restart-Service Spooler          # ONLY with an empty queue
```

## Status

| Item | State |
|---|---|
| Queue Offline / Unknown status | Fixed (Round 1 port change) |
| Raw data path to printer | Verified working |
| Job 3 (Document_A) | Destroyed by spooler restart, never printed |
| Black toner | 0 % — replace |
| Cyan toner | 1 % — replace |
| SNMP polling on active port | Still enabled, pending |

---

# Round 3 — Print Queue window showed a phantom job

**Symptom:** after the queue was verified empty, the Windows 11 Print Queue app
still displayed `Job 3 / Document_A / Unknown status / 45 pages,
86.1 MB`. It only disappeared after clicking the refresh icon.

**This was a stale window, not a stale queue.** Checked directly against the
spooler at the same moment:

```
NPIXXXXXX (HP Color LaserJet MFP M283cdw)   Normal   JobCount: 0
Spool files in C:\Windows\System32\spool\PRINTERS: 0
```

Zero jobs, zero orphaned .SHD/.SPL files.

**Cause:** the Print Queue app receives live updates through an RPC change
notification from the Spooler service. `Restart-Service Spooler -Force` tears
that channel down, and the app does not re-subscribe — it keeps rendering its
last snapshot indefinitely. "Unknown status" is what it shows for a job record
it still holds but can no longer get live status for. Refresh forces a fresh
`EnumJobs` call, which is why one click cleared it.

Same spooler restart, three consequences: killed the render pipeline, destroyed
job 3, and orphaned the window that was displaying it.

**Rule:** after any spooler restart, close and reopen the Print Queue window.
Do not diagnose from it. `Get-Printer` / `Get-PrintJob` read the spooler
directly and stayed accurate throughout.

**Note on the original fault:** this UI staleness did *not* cause the Round 1
problem. That one was real — `Get-Printer` independently reported
`PrinterStatus: Offline` on the WSD port before anything was restarted.

---

# Round 4 — Document_B.pdf: out of paper, and the toner gauges are fiction

**Actual blocker: the paper tray was empty.**

```
PrinterStatus: trayEmptyOrOpen
Job 3: Document_B.pdf - "Printing, Retained", 0 of 20 pages, Size 0
Spool files: 0
```

`Size 0` with spool count 0 meant the job had already streamed to the device.
The printer was holding it, waiting for paper. Loading the tray released it with
no reprint needed — status went `trayEmptyOrOpen` -> `processing`.

## Correction: the "black toner is empty" call in Round 2 was wrong

Round 2 read `K = 0%` and recommended replacing the black cartridge. The
cartridges are **aftermarket**, and HP cannot measure non-genuine supplies.
Full consumable detail:

```
K: 0%   LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
C: 1%   LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
M: 20%  LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)
Y: 20%  LifeState=ok  UniqueID=(blank)  MeasuredQuantity=(blank)  Warranty=(blank)

All four: SelectibilityNumber 206A, InstallDate 2025-02-12
Alert table: genuineHP x4 (acknowledgeConsumableState)
```

Five tells that the percentages are estimates, not measurements:

1. `ConsumableUniqueID` blank on all four — no readable HP chip.
2. `MeasuredQuantityState` blank — nothing actually measured.
3. `WarrantyStatus` blank — supply not recognized.
4. Magenta and Yellow at *identical* 20%; one shared InstallDate across all four.
   Real gauges don't tie.
5. `LifeState: ok` on the same cartridge reported at 0%.

With no chip to read, the firmware falls back to counting pages since it last
saw a cartridge-change event and extrapolating. Those numbers mean nothing here.

**Rule for this printer: judge toner by print quality on paper, not by the EWS
percentages or the HP Smart gauge.** The `genuineHP` alerts and the level
readings can be ignored. `LifeState` is the only supply field still worth
reading.

## Status

| Item | State |
|---|---|
| Queue Offline / Unknown status | Fixed (Round 1 port change) |
| Raw data path to printer | Verified working |
| Job 3 (Document_A) | Destroyed by spooler restart, never printed |
| Document_B.pdf | Printing, released by loading paper |
| Toner levels | Unmeasurable (aftermarket). Ignore the percentages. |
| Paper stock | Exhausted — restock |
| SNMP polling on active port | Still enabled, pending |
