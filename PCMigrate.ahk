#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
; PCMigrate.ahk - launcher
; PCMigrate moves your apps and settings from an old Windows PC to a new one,
; and decides on the NEW PC what actually fits its hardware.
;
;   0. Update all apps        - optional, on the OLD PC first (winget upgrade --all)
;   1. Capture this PC        - run on the OLD PC (creates a package)
;   2. Restore onto this PC   - run on the NEW PC (checks hardware, you pick, it applies)
;   3. Undo last restore      - puts back everything a restore changed
;
; Project : https://github.com/smogmanus1/PCMigrate
; Authors : Brad Schrunk (concept, design direction, testing)
;           Claude by Anthropic (architecture and code)
; License : MIT
; ==============================================================================

global PM_Version := "1.0.6"
global PM_Src     := A_ScriptDir "\src"
global PM_Ini     := A_ScriptDir "\PCMigrate.ini"
global PM_Rules   := A_ScriptDir "\rules\compat-rules.json"
global PM_Win     := PM_WindowsInfo()

if !PM_CheckWindows(PM_Win)
    ExitApp()

PM_Gui := Gui("+MinSize360x", "PCMigrate " PM_Version " - " A_ComputerName)
PM_Gui.SetFont("s10", "Segoe UI")
PM_Gui.MarginX := 16, PM_Gui.MarginY := 12
PM_Gui.SetFont("s13 bold")
PM_Gui.AddText("w340", "PCMigrate")
PM_Gui.SetFont("s9 norm cGray")
PM_Gui.AddText("w340 y+2", "Move apps and settings to a new PC - it checks what fits the new hardware.")
; One-line system check: Windows version and whether winget (automatic app installs) is available
PM_Gui.SetFont("s9 norm c" (PM_Win.Supported && PM_Win.Winget ? "2E7D32" : "B35C00"))
PM_Gui.AddText("w340 y+8", PM_StatusLine(PM_Win))
PM_Gui.SetFont("s10 norm cDefault")

PM_Gui.AddText("w340 y+14", "On the OLD PC:")
PM_Gui.AddButton("w340 h32", "0.  Update all apps first  (admin)").OnEvent("Click", PM_UpdateApps)
PM_Gui.AddButton("w340 h40", "1.  Capture this PC").OnEvent("Click", (*) => PM_Run("Capture.ps1", false))
PM_Gui.AddText("w340 y+14", "On the NEW PC:")
PM_Gui.AddButton("w340 h40", "2.  Restore onto this PC  (admin)").OnEvent("Click", (*) => PM_Run("Restore.ps1", true))
PM_Gui.AddButton("w340 h32", "Preview only - report, change nothing").OnEvent("Click", (*) => PM_Run("Restore.ps1", false, "-WhatIf"))
PM_Gui.AddButton("w340 h32", "3.  Undo last restore  (admin)").OnEvent("Click", (*) => PM_Run("Undo.ps1", true))

PM_Gui.AddText("w340 y+14 0x10")
PM_Gui.AddButton("w166 h30 Section", "Packages folder").OnEvent("Click", PM_OpenPackages)
PM_Gui.AddButton("w166 h30 x+8", "Restore backups").OnEvent("Click", PM_OpenBackups)
PM_Gui.AddButton("w166 h30 xs", "Settings (INI)").OnEvent("Click", (*) => Run('notepad.exe "' PM_Ini '"'))
PM_Gui.AddButton("w166 h30 x+8", "Hardware rules").OnEvent("Click", (*) => Run('notepad.exe "' PM_Rules '"'))
PM_Gui.AddButton("w340 h30 xs", "About").OnEvent("Click", PM_About)

PM_Gui.OnEvent("Close", (*) => ExitApp())
PM_Gui.OnEvent("Escape", (*) => ExitApp())
PM_Gui.Show()

; ---------------------------------------------------------------------------
; Windows version check
;   Windows 10 / 11  : supported
;   Windows 8 / 8.1  : capture only, best effort (needs PowerShell 5.1; no winget)
;   Windows 7 / older: not supported
; ---------------------------------------------------------------------------
PM_WindowsInfo() {
    v := StrSplit(A_OSVersion, ".")                  ; "major.minor.build", e.g. 10.0.22631
    major := (v.Length >= 1 && IsInteger(v[1])) ? Integer(v[1]) : 0
    minor := (v.Length >= 2 && IsInteger(v[2])) ? Integer(v[2]) : 0
    build := (v.Length >= 3 && IsInteger(v[3])) ? Integer(v[3]) : 0
    if (major >= 10)
        name := (build >= 22000) ? "Windows 11" : "Windows 10"
    else if (major = 6 && minor = 3)
        name := "Windows 8.1"
    else if (major = 6 && minor = 2)
        name := "Windows 8"
    else if (major = 6 && minor = 1)
        name := "Windows 7"
    else
        name := "Windows " A_OSVersion
    ; winget is installed per user as an app alias by Microsoft's App Installer
    winget := FileExist(EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\winget.exe") != ""
    return { Major: major, Minor: minor, Build: build, Name: name, Winget: winget
           , Supported: major >= 10, CaptureOnly: (major = 6 && minor >= 2) }
}

PM_StatusLine(w) {
    s := w.Name " (build " w.Build ")"
    if !w.Supported
        return s " - not supported. Capture only, best effort."
    if !w.Winget
        return s " - supported, but winget was not found: apps will go on the install-by-hand list. "
             . "Get " Chr(34) "App Installer" Chr(34) " from the Microsoft Store to fix this."
    return s " - supported. winget found."
}

PM_CheckWindows(w) {
    if w.Supported
        return true
    if w.CaptureOnly {
        r := MsgBox("This PC runs " w.Name ".`n`n"
            . "PCMigrate is built for Windows 10 and 11. On " w.Name " you can try a CAPTURE, "
            . "so you can move to a new PC, but it is not tested:`n`n"
            . "  - PowerShell 5.1 is required. If it is missing, install Windows Management Framework 5.1 from Microsoft first.`n"
            . "  - winget does not exist on " w.Name ", so every app goes on the install-by-hand list. "
            . "Your settings, fonts and preferences still come along.`n"
            . "  - Restoring onto " w.Name " is not possible.`n`n"
            . "Open PCMigrate anyway?", "PCMigrate - " w.Name, "YesNo Icon!")
        return r = "Yes"
    }
    MsgBox("This PC runs " w.Name ".`n`n"
        . "PCMigrate needs Windows 10 or 11. " w.Name " is missing parts of PowerShell that PCMigrate relies on.`n`n"
        . "To move to a new PC from here, copy your Documents, Desktop, Pictures and browser bookmarks "
        . "to a USB drive and reinstall your programs on the new PC by hand.", "PCMigrate - " w.Name, "Iconx")
    return false
}

PM_Run(script, elevate, extra := "") {
    if (!PM_Win.Supported && script != "Capture.ps1") {
        MsgBox("Restore and Undo need Windows 10 or 11. This PC runs " PM_Win.Name ".", "PCMigrate", "Iconx")
        return
    }
    path := PM_Src "\" script
    if !FileExist(path) {
        MsgBox("Can't find:`n" path "`n`nKeep the PCMigrate folder together (PCMigrate.ahk, PCMigrate.ini, src, rules).", "PCMigrate", "Iconx")
        return
    }
    ; a 32-bit AutoHotkey must still start 64-bit PowerShell, or Windows hides the 64-bit programs from it.
    ; Elevated (*RunAs) launches are started by a 64-bit service, so plain powershell.exe is already 64-bit there.
    ps := (!elevate && A_PtrSize = 4 && A_Is64bitOS) ? A_WinDir "\Sysnative\WindowsPowerShell\v1.0\powershell.exe" : "powershell.exe"
    cmd := ps ' -NoProfile -ExecutionPolicy Bypass -STA -File "' path '" ' extra
    try Run((elevate ? "*RunAs " : "") cmd, A_ScriptDir)
    catch
        MsgBox("Cancelled (administrator permission was not given).", "PCMigrate", "Icon!")
}

; Updates every winget-managed app so the captured settings match the versions the new PC will install.
; Licence and source agreements are accepted automatically; the window stays open so you can read the results.
PM_UpdateApps(*) {
    if MsgBox("Update all apps with winget now?`n`nClose your browsers and other open apps first - an installer can't update an app that is running.`n`nAfterwards: restart, open your main apps once, then capture.", "PCMigrate", "OKCancel Iconi") != "OK"
        return
    upd := "winget source update && winget upgrade --all --include-unknown --silent"
        . " --accept-package-agreements --accept-source-agreements --disable-interactivity"
    cmd := A_ComSpec ' /k "title PCMigrate - updating apps && ' upd ' & echo. & echo ===== Done. Run it again to catch anything that was in use, then restart. ====="'
    try Run("*RunAs " cmd)
    catch
        MsgBox("Cancelled (administrator permission was not given).", "PCMigrate", "Icon!")
}

PM_PackageRoot() {
    root := IniRead(PM_Ini, "Paths", "PackageRoot", "")
    while RegExMatch(root, "%([^%]+)%", &m)          ; expand %VARIABLES% like the PowerShell side does
        root := StrReplace(root, m[0], EnvGet(m[1]))
    if (root = "")
        root := RegExReplace(A_ScriptDir, "\\[^\\]+$")   ; folder that contains PCMigrate
    return root
}

PM_OpenPackages(*) {
    root := PM_PackageRoot()
    DirCreate(root)
    Run(root)
}

PM_OpenBackups(*) {
    dir := EnvGet("USERPROFILE") "\PCMigrate\Restores"
    if !DirExist(dir) {
        MsgBox("No restores have been run on this PC yet.", "PCMigrate", "Iconi")
        return
    }
    Run(dir)
}

PM_About(*) {
    MsgBox("PCMigrate " PM_Version "`n`n"
        . "Moves apps and settings from an old Windows PC to a new one and checks, on the new PC, "
        . "what actually fits its hardware - graphics, processor, maker, laptop or desktop, connected "
        . "devices and printers.`n`n"
        . "Runs on Windows 10 and 11.  This PC: " PM_Win.Name " (build " PM_Win.Build ").`n`n"
        . "Concept, design direction and testing:  Brad Schrunk`n"
        . "Architecture and code:  Claude by Anthropic`n`n"
        . "MIT License - github.com/smogmanus1/PCMigrate", "About PCMigrate", "Iconi")
}
