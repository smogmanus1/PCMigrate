#Requires AutoHotkey v2.0
; ==============================================================================
; FreeTools.ahk - "Free tools" window for PCMigrate
; Shows excellent free utilities many people have never heard of.
;   Installed  -> Launch it
;   Missing    -> Install it with winget (or open its web page if winget can't)
; Included by PCMigrate.ahk. To add a tool, add one line to FT_Catalog().
; Fields: name, category, what-it-does, exe names (or full paths), uninstall-list
;         name pattern, winget ID ("" = none), web page
; Please verify new winget IDs with:  winget show --id <ID>
; ==============================================================================

FT_Catalog() {
    t := []
    t.Push(["Everything", "Find files", "Finds any file on your PC instantly, as you type. Far faster than Windows search.",
        ["Everything.exe", "%ProgramFiles%\Everything\Everything.exe"], "Everything*", "voidtools.Everything", "https://www.voidtools.com"])
    t.Push(["dnGrep", "Find files", "Searches INSIDE your files (text, Word, PDF, zip) and can replace text across many files at once.",
        ["dnGrep.exe", "%ProgramFiles%\dnGrep\dnGrep.exe"], "dnGrep*", "dnGrep.dnGrep", "https://dngrep.github.io"])
    t.Push(["Notepad++", "Editing", "Fast, free text and code editor with tabs, syntax colors and search across files.",
        ["notepad++.exe", "%ProgramFiles%\Notepad++\notepad++.exe"], "Notepad++*", "Notepad++.Notepad++", "https://notepad-plus-plus.org"])
    t.Push(["Visual Studio Code", "Editing", "Microsoft's free code editor, with thousands of add-ons. Good for scripts, web pages and config files.",
        ["Code.exe", "%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe", "%ProgramFiles%\Microsoft VS Code\Code.exe"], "Microsoft Visual Studio Code*", "Microsoft.VisualStudioCode", "https://code.visualstudio.com"])
    t.Push(["WinMerge", "Editing", "Compares two files or two folders side by side and shows exactly what changed.",
        ["WinMergeU.exe", "%ProgramFiles%\WinMerge\WinMergeU.exe"], "WinMerge*", "WinMerge.WinMerge", "https://winmerge.org"])
    t.Push(["Bulk Crap Uninstaller", "Cleanup", "Removes many programs at once, including leftovers a normal uninstall misses. Great for cleaning a PC.",
        ["BCUninstaller.exe", "%ProgramFiles%\BCUninstaller\BCUninstaller.exe"], "Bulk Crap Uninstaller*", "Klocman.BulkCrapUninstaller", "https://www.bcuninstaller.com"])
    t.Push(["WinDirStat", "Cleanup", "Draws a map of your drive so you can see at a glance what is eating the space.",
        ["WinDirStat.exe", "%ProgramFiles%\WinDirStat\WinDirStat.exe"], "WinDirStat*", "WinDirStat.WinDirStat", "https://windirstat.net"])
    t.Push(["Wireshark", "Network", "Shows the network traffic on your PC. The standard tool for finding out what is talking to what.",
        ["Wireshark.exe", "%ProgramFiles%\Wireshark\Wireshark.exe"], "Wireshark*", "WiresharkFoundation.Wireshark", "https://www.wireshark.org"])
    t.Push(["Process Explorer", "System", "A much better Task Manager from Microsoft Sysinternals: shows which program owns every process and file.",
        ["procexp64.exe", "procexp.exe"], "", "Microsoft.Sysinternals.ProcessExplorer", "https://learn.microsoft.com/sysinternals/downloads/process-explorer"])
    t.Push(["PowerToys", "System", "Microsoft's free power-user add-ons: window layouts, quick launcher, color picker, bulk rename and more.",
        ["PowerToys.exe", "%LOCALAPPDATA%\PowerToys\PowerToys.exe", "%ProgramFiles%\PowerToys\PowerToys.exe"], "PowerToys*", "Microsoft.PowerToys", "https://learn.microsoft.com/windows/powertoys"])
    t.Push(["HWiNFO", "System", "Detailed readout of your hardware: temperatures, fans, voltages, exact part numbers.",
        ["HWiNFO64.exe", "%ProgramFiles%\HWiNFO64\HWiNFO64.exe"], "HWiNFO*", "REALiX.HWiNFO", "https://www.hwinfo.com"])
    t.Push(["CrystalDiskInfo", "System", "Checks the health of your hard drive or SSD and warns you before it fails.",
        ["DiskInfo64.exe", "%ProgramFiles%\CrystalDiskInfo\DiskInfo64.exe"], "CrystalDiskInfo*", "CrystalDewWorld.CrystalDiskInfo", "https://crystalmark.info"])
    t.Push(["7-Zip", "Files", "Opens and makes zip, 7z, rar and many other archive types.",
        ["7zFM.exe", "%ProgramFiles%\7-Zip\7zFM.exe"], "7-Zip*", "7zip.7zip", "https://www.7-zip.org"])
    t.Push(["ShareX", "Capture", "Free screenshot and screen-recording tool with annotations and automatic upload.",
        ["ShareX.exe", "%ProgramFiles%\ShareX\ShareX.exe"], "ShareX*", "ShareX.ShareX", "https://getsharex.com"])
    t.Push(["VLC media player", "Media", "Plays almost any audio or video file with no extra codecs needed.",
        ["vlc.exe", "%ProgramFiles%\VideoLAN\VLC\vlc.exe"], "VLC media player*", "VideoLAN.VLC", "https://www.videolan.org"])
    t.Push(["OBS Studio", "Media", "Free screen recording and live streaming.",
        ["obs64.exe", "%ProgramFiles%\obs-studio\bin\64bit\obs64.exe"], "OBS Studio*", "OBSProject.OBSStudio", "https://obsproject.com"])
    t.Push(["KeePassXC", "Security", "Free offline password manager. Your passwords stay in a file you control.",
        ["KeePassXC.exe", "%ProgramFiles%\KeePassXC\KeePassXC.exe"], "KeePassXC*", "KeePassXCTeam.KeePassXC", "https://keepassxc.org"])
    t.Push(["Rufus", "System", "Makes a bootable USB stick for installing Windows or Linux.",
        ["rufus.exe"], "", "Rufus.Rufus", "https://rufus.ie"])
    t.Push(["AutoHotkey v2", "Automation", "The scripting language PCMigrate's launcher is written in. Automate clicks, keys, windows and text.",
        ["AutoHotkey64.exe", "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"], "AutoHotkey*", "AutoHotkey.AutoHotkey", "https://www.autohotkey.com"])
    return t
}

; Returns the program's full path if found, "" if not installed. Also returns the
; folder-less "found in uninstall list" case as "(installed)" so we can still say Installed.
FT_Find(tool) {
    for p in tool[4] {
        p := FT_Expand(p)
        if InStr(p, "\") {
            if FileExist(p)
                return p
        } else {
            ; Bare exe name: registry App Paths (machine, then user), then PATH
            for root in ["HKLM", "HKCU"]
                try {
                    v := RegRead(root "\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\" p, "")
                    if (v != "" && FileExist(Trim(v, '"')))
                        return Trim(v, '"')
                }
            try {
                if (RunWait(A_ComSpec ' /c where "' p '" >nul 2>&1', , "Hide") = 0)
                    return p
            }
        }
    }
    ; Last resort: look for the name in the installed-programs list
    if (tool[5] != "" && FT_InUninstallList(tool[5]))
        return "(installed)"
    return ""
}

FT_Expand(p) {
    while RegExMatch(p, "%([^%]+)%", &m)
        p := StrReplace(p, m[0], EnvGet(m[1]))
    return p
}

FT_InUninstallList(pattern) {
    rx := "i)^" StrReplace(RegExReplace(pattern, "([.+?^${}()|\[\]\\])", "\$1"), "*", ".*")
    for key in ["HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
              , "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
              , "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"]
        try loop reg, key, "K" {
            try if RegExMatch(RegRead(key "\" A_LoopRegName, "DisplayName"), rx)
                return true
        }
    return false
}

FT_Show(*) {
    static g := ""
    if IsObject(g) {
        g.Show()
        return
    }
    cat := FT_Catalog()
    g := Gui("+Resize +MinSize700x400", "PCMigrate - Free tools")
    g.SetFont("s10", "Segoe UI")
    g.MarginX := 14, g.MarginY := 12
    g.SetFont("s13 bold")
    g.AddText("w660", "Free tools worth knowing")
    g.SetFont("s9 norm cGray")
    g.AddText("w660 y+2", "Excellent free programs many people have never heard of. Pick one: Launch it if you have it, Install it if you don't.")
    g.SetFont("s10 norm cDefault")
    lv := g.AddListView("w660 r14 y+10 -Multi Grid", ["Tool", "Type", "Status", "What it does"])
    rows := []
    for t in cat {
        found := FT_Find(t)
        status := found != "" ? "Installed" : (t[6] != "" ? "Not installed" : "Web page")
        lv.Add("", t[1], t[2], status, t[3])
        rows.Push({tool: t, path: found})
    }
    lv.ModifyCol(1, 150), lv.ModifyCol(2, 80), lv.ModifyCol(3, 95), lv.ModifyCol(4, 320)
    info := g.AddText("w660 h40 y+8 cGray", "Select a tool to see what you can do with it.")
    btnGo := g.AddButton("w180 h32 Section Disabled", "Launch / Install")
    btnWeb := g.AddButton("w140 h32 x+8 Disabled", "Open web page")
    btnRef := g.AddButton("w120 h32 x+8", "Re-check")
    g.AddButton("w90 h32 x+8", "Close").OnEvent("Click", (*) => g.Hide())

    sel := 0
    lv.OnEvent("ItemSelect", (ctl, item, selected) => (selected ? FT_Select(item) : 0))
    lv.OnEvent("DoubleClick", (ctl, item) => (item ? FT_Do(item) : 0))
    btnGo.OnEvent("Click", (*) => FT_Do(sel))
    btnWeb.OnEvent("Click", (*) => sel ? Run(rows[sel].tool[7]) : 0)
    btnRef.OnEvent("Click", (*) => FT_Refresh())
    g.OnEvent("Close", (*) => g.Hide())
    g.OnEvent("Escape", (*) => g.Hide())

    FT_Select(i) {
        sel := i
        r := rows[i]
        installed := r.path != ""
        btnGo.Enabled := installed || r.tool[6] != ""
        btnGo.Text := installed ? "Launch" : "Install with winget"
        btnWeb.Enabled := true
        info.Value := r.tool[1] ": " r.tool[3]
            . (installed ? "" : (r.tool[6] != "" ? "`nWill run: winget install --id " r.tool[6] : "`nNo automatic install - use the web page."))
    }

    FT_Do(i) {
        if !i
            return
        r := rows[i], t := r.tool
        if (r.path != "") {
            if (r.path = "(installed)") {
                MsgBox(t[1] " is installed, but PCMigrate can't tell where. Find it in the Start menu.", "PCMigrate", "Iconi")
                return
            }
            try Run('"' r.path '"')
            catch as e
                MsgBox("Couldn't start " t[1] ":`n" e.Message, "PCMigrate", "Icon!")
            return
        }
        if (t[6] = "") {
            Run(t[7])
            return
        }
        if !PM_Win.Winget {
            if MsgBox("winget was not found on this PC, so it can't install " t[1] " automatically.`n`nOpen the web page instead?", "PCMigrate", "YesNo Icon!") = "Yes"
                Run(t[7])
            return
        }
        if MsgBox("Install " t[1] " now?`n`n" t[3] "`n`nThis runs:  winget install --id " t[6], "PCMigrate - Install", "OKCancel Iconi") != "OK"
            return
        cmd := A_ComSpec ' /k "title Installing ' t[1] ' && winget install --id ' t[6]
            . ' -e --silent --accept-package-agreements --accept-source-agreements & echo. & echo ===== Finished. You can close this window. ====="'
        Run(cmd)    ; per-user installs need no admin; installers that do will ask for it themselves
    }

    FT_Refresh() {
        for i, r in rows {
            r.path := FT_Find(r.tool)
            lv.Modify(i, "Col3", r.path != "" ? "Installed" : (r.tool[6] != "" ? "Not installed" : "Web page"))
        }
        if sel
            FT_Select(sel)
    }

    g.Show("w690")
}
