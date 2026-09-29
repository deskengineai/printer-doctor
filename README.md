# Printer Doctor

Finds out why a Windows PC won't print, explains it in plain English, and fixes it only after asking first. Works with any printer brand.

Built after a real "printer offline / Unknown status" incident. Every mistake made along the way is written up in [ERRORS.md](ERRORS.md), and each one became a safety rule in the script.

**Feature overview:** open [printer_doctor.html](printer_doctor.html) in a browser.

> **Status: beta.** Diagnosis, preview and reports have been run on a real printer. The actions that change settings (commit, select, rollback, single actions) have so far only been exercised in a test harness, not on a live admin session. Run `-Preview` first and keep the automatic backup; `-Rollback` undoes port and SNMP changes. Please open an issue with a `-Report-Public` file if something goes wrong.

## Quick start

| Mode | Command | Changes the PC? |
|---|---|---|
| **Diagnose** | `.\printer_doctor.ps1` | No. No admin needed. |
| **Preview changes** | `.\printer_doctor.ps1 -Preview` | No. Lists every change the fix would make. |
| **Commit changes** | `.\printer_doctor.ps1 -Commit` | Yes, after one approval. Stops at the first failure. |
| **Select changes** | `.\printer_doctor.ps1 -Select` | Yes, only the plan steps you pick. |
| **Roll back** | `.\printer_doctor.ps1 -Rollback` | Yes, undoes the latest backup's recorded changes. |
| Single actions | `.\printer_doctor.ps1 -Fix` | Menu of individual actions; each asks first. |
| Reports | `-Report` (private) or `-Report-Public` (redacted) | No. |

Changes need an elevated PowerShell (Run as administrator).

Downloaded as a ZIP from GitHub? Windows blocks the scripts until you unblock them once: `Get-ChildItem *.ps1 | Unblock-File`
If scripts are still blocked: `powershell -ExecutionPolicy Bypass -File .\printer_doctor.ps1`

## What it checks

- Print Spooler service, stuck jobs, and offline or paused queues
- Port type (WSD, Standard TCP/IP, IPP, USB, shared), plus SNMP status polling
- Name lookup, ping, print ports 9100 / 631 / 515 / 80, and the route to the printer
- Wrong Wi-Fi, VPN capturing printer traffic, and Public network profiles
- The printer's own status over IPP: paper out, jam, door open
- Missing, damaged, or generic drivers
- Recent print errors, destroyed jobs (event 824), and the last confirmed print (event 307)

Each finding is ranked **Likely cause**, **Possible cause**, or **Needs manual review**, and comes with one safe next step.

## Preview, commit, select

`-Preview` builds a fix plan from the diagnosis and shows exactly what would change, for example:

```
  2. [change, admin] Move the printer to a Standard TCP/IP port
       + Create port IP_192.168.1.50 -> 192.168.1.50:9100 (RAW)
       + SNMP status monitoring on the new port: ON - the printer answers SNMP
       + Printer port: 'WSD-...' -> 'IP_192.168.1.50'
       + Old port 'WSD-...' is kept, so you can switch back
  3. [change] Set the printer online
       + 'Use Printer Offline': on -> off
  4. [you] Make the printer answer SNMP (keeps SNMP on)
```

`[change]` steps are done by the script; `[you]` steps need a person. Nothing outside the list is changed.
`-Commit` applies every change after one approval, then shows a before/after table. `-Select` applies only the step numbers you type. Deleting print jobs is always asked separately.

## SNMP

Some people rely on SNMP so Windows can report paper-out and jams, so **SNMP is kept by default** (`-Snmp Keep`).

- If the printer ignores SNMP, the plan tells you how to turn SNMP on in the printer instead of switching Windows polling off.
- A new port copies the old port's SNMP setting. Coming from WSD, SNMP is turned on only if the printer answers it, because polling a silent printer marks the queue Offline.
- `-Snmp Off` allows the plan to turn Windows SNMP polling off. The trade-off is shown before anything changes.

## Rollback

The first change of any run writes `backup_<date>\rollback.json`: the printer's port, that port's SNMP setting, and every port the script creates.

- `-Rollback` (or **R** in the `-Fix` menu) moves the printer back to its original port, restores the SNMP setting, and deletes ports the script created.
- During `-Commit`, if a step fails, or the printer stops answering on port 9100 afterwards, the script shows the rollback and asks once.
- Deleted print jobs cannot be restored. The "Use Printer Offline" flag is left off.

## Single actions (`-Fix`)

Every action asks first, and the printer's settings are backed up before any change. The spooler is never restarted while a job is printing, because that destroys the job. The menu also has **P** preview, **C** commit, **S** select and **R** rollback.

1. Back up printer settings
2. Restart the Print Spooler (guarded)
3. Clear stuck jobs
4. Set the printer online / resume the queue
5. Re-test DNS and reachability
6. Move the printer to a Standard TCP/IP port
7. Open the Windows port settings
8. Disable SNMP status monitoring (the script shows its evidence and the trade-off first)
9. Write an escalation report
10. Write a redacted public report

## Public reports

`-Report-Public` writes `escalation_public_*.md` with document names, user, PC, printer, Wi-Fi, network and VPN names, SNMP community, GUIDs and email addresses replaced by placeholders. IPs keep only the first two octets and MACs keep only the vendor prefix. Raw event text is swapped for a plain meaning plus the error code. Port type, driver, status, error codes and firewall state are kept, because a helper needs them.

## Files

| File | Purpose |
|---|---|
| `printer_doctor.ps1` | Main tool: diagnosis and guarded recovery |
| `PrinterLib.ps1` | IPP / SNMP / web-page probes. Must sit next to `printer_doctor.ps1` |
| `printer_status.ps1` | Quick health check for HP printers, read from the printer's web service |
| `set_snmp_off.ps1` | Standalone: disable SNMP on a printer's live port, with a queue guard |
| `ERRORS.md`, `FIX_NOTES.md` | Incident write-up (identifying details redacted) |
| `printer_doctor.html` | Feature overview page |
| `LICENSE` | MIT |

## Generated files

The scripts write these next to themselves. They contain your IPs, MAC addresses, PC name and username, and are git-ignored:
`escalation_*.md`, `backup_*/`, `printer_doctor_state.json`, `fix_log.txt`

Requirements: Windows 10/11 and Windows PowerShell 5.1 or later.

## License

MIT - see [LICENSE](LICENSE). Provided as is, with no warranty. It changes Windows printer settings only after you approve, and backs them up first.
