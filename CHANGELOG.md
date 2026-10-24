# Changelog

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
