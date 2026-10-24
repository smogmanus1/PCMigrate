# Changelog

## 1.0.2 - 2026-10-24

- Launcher: new **0. Update all apps first** button (winget upgrade --all, agreements accepted) to run on the old PC before capturing
- Capture creates the package folder only after you press Enter (nothing half-made while the window waits)
- A log that can no longer be written gives one warning instead of an error on every line

## 1.0.1 - 2026-10-24

Fixes from the first real capture (a desktop with ten drive letters pointing at one disk).

- Drive aliases: when the old PC had several letters for the same disk (e.g. E: and F:), the new PC maps the missing letter to the existing one instead of creating folder links
- Relocated folders (Desktop, Documents...) are read without expanding %USERPROFILE%; only really moved folders are offered
- Scheduled tasks and startup items are filtered (Windows tips, telemetry, installer-made tasks) and checked by the hardware rules (e.g. ASUS tasks on a non-ASUS PC)
- Startup items and tasks for apps installed in the same run restore after the install
- Tasks that run a command from PATH (e.g. `python script.py`) are recognised
- Windows' own fonts are no longer captured as "added fonts"
- Better matching of installed programs to their winget packages

## 1.0.0 - 2026-10-24

First public release. A rewrite of Brad Schrunk's PCMigration tools, with the compatibility decisions moved to the new PC.

- Hardware-aware compatibility engine with editable JSON rules (GPU, CPU, maker, chassis, devices, printers)
- Settings-to-program matching with aliases; settings restored only for installed (or just-installed) apps
- winget installs, including winget alternatives for apps the old PC had installed by hand
- Machine-identity protection for remote-access, VPN and sync clients
- Path detection and fixing: drive-letter mapping via junction + DOS device, and text/registry path rewriting
- Windows preferences, known folders, environment/PATH, startup items, scheduled tasks, fonts, Terminal settings, PowerShell profiles, optional Wi-Fi and network drives
- Hardware-specific suggestions (HP, Dell, Lenovo, MSI, Intel)
- WinForms checklist, HTML report, preview mode, unattended mode
- Backups, journal, System Restore point and one-click Undo
- Reads packages made by the earlier PCMigration export tool
