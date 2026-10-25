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

global PM_Version := "1.0.4"
global PM_Src     := A_ScriptDir "\src"
global PM_Ini     := A_ScriptDir "\PCMigrate.ini"
global PM_Rules   := A_ScriptDir "\rules\compat-rules.json"

PM_Gui := Gui("+MinSize360x", "PCMigrate " PM_Version " - " A_ComputerName)
PM_Gui.SetFont("s10", "Segoe UI")
PM_Gui.MarginX := 16, PM_Gui.MarginY := 12
PM_Gui.SetFont("s13 bold")
PM_Gui.AddText("w340", "PCMigrate")
PM_Gui.SetFont("s9 norm cGray")
PM_Gui.AddText("w340 y+2", "Move apps and settings to a new PC - it checks what fits the new hardware.")
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

PM_Run(script, elevate, extra := "") {
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
        . "Concept, design direction and testing:  Brad Schrunk`n"
        . "Architecture and code:  Claude by Anthropic`n`n"
        . "MIT License - github.com/smogmanus1/PCMigrate", "About PCMigrate", "Iconi")
}
