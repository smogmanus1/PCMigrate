#Requires AutoHotkey v2.0
; ==============================================================================
; FreeTools.ahk - "Free tools" window for PCMigrate
; Shows excellent free utilities many people have never heard of.
;   Installed  -> Launch it
;   Missing    -> Install it with winget (or open its web page if winget can't)
; Included by PCMigrate.ahk. To add a tool, add one line to FT_Catalog().
; Fields: name, category, what-it-does, exe names (or full paths), uninstall-list
;         name pattern, winget ID ("" = none), web page,
;         optional 8th field: Store / MSIX package name patterns, e.g. ["Microsoft.Todos_*"]
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
    t.Push(["WizTree", "Cleanup", "Like WinDirStat but many times faster: reads the drive's file table directly, so a full scan takes seconds. Free for personal use.",
        ["WizTree64.exe", "%ProgramFiles%\WizTree\WizTree64.exe", "%ProgramFiles%\WizTree\WizTree.exe"], "WizTree*", "AntibodySoftware.WizTree", "https://diskanalyzer.com"])
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
    t.Push(["Angry IP Scanner", "Network", "Scans your home network and lists every device on it: computers, phones, printers, cameras, with names and open ports.",
        ["ipscan.exe", "%ProgramFiles(x86)%\Angry IP Scanner\ipscan.exe", "%ProgramFiles%\Angry IP Scanner\ipscan.exe"], "Angry IP Scanner*", "angryziber.AngryIPScanner", "https://angryip.org"])
    t.Push(["Brave", "Web", "Fast web browser built on Chrome's engine that blocks ads and trackers out of the box. Chrome extensions work.",
        ["brave.exe", "%ProgramFiles%\BraveSoftware\Brave-Browser\Application\brave.exe", "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe"], "Brave*", "Brave.Brave", "https://brave.com"])
    t.Push(["LibreWolf", "Web", "Privacy-first version of Firefox: no telemetry, tracking protection and uBlock Origin built in.",
        ["librewolf.exe", "%ProgramFiles%\LibreWolf\librewolf.exe"], "LibreWolf*", "LibreWolf.LibreWolf", "https://librewolf.net"])
    t.Push(["Claude", "AI", "Anthropic's AI assistant as a desktop app: writing, research, coding help, and work with the files on your PC.",
        ["%LOCALAPPDATA%\AnthropicClaude\claude.exe"], "Claude", "Anthropic.Claude", "https://claude.ai/download", ["Claude_*__pzs8sxrjxfjjc"]])
    t.Push(["ChatGPT", "AI", "OpenAI's AI assistant as a desktop app, with a keyboard shortcut to ask it anything from anywhere.",
        [], "ChatGPT*", "OpenAI.ChatGPT", "https://chatgpt.com/download", ["OpenAI.Codex_*__2p2nqsd0c76g0", "OpenAI.ChatGPT*"]])
    t.Push(["Microsoft To Do", "Productivity", "Simple to-do lists and reminders that sync with your phone and Outlook tasks.",
        [], "", "9NBLGGH5R558", "https://apps.microsoft.com/detail/9nblggh5r558", ["Microsoft.Todos_*__8wekyb3d8bbwe"]])
    t.Push(["Git", "Coding", "Keeps every version of your scripts and projects, and sends them to GitHub. Adds Git Bash and the git command.",
        ["git.exe", "%ProgramFiles%\Git\cmd\git.exe"], "Git", "Git.Git", "https://git-scm.com"])
    t.Push(["GitHub Desktop", "Coding", "Point-and-click Git: see what changed, commit and push to GitHub without typing commands.",
        ["GitHubDesktop.exe", "%LOCALAPPDATA%\GitHubDesktop\GitHubDesktop.exe"], "GitHub Desktop*", "GitHub.GitHubDesktop", "https://desktop.github.com"])
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
    if (tool.Length >= 8 && FT_InStoreApps(tool[8]))
        return "(installed)"
    return ""
}

FT_Expand(p) {
    while RegExMatch(p, "%([^%]+)%", &m)
        p := StrReplace(p, m[0], EnvGet(m[1]))
    return p
}

; Store / MSIX apps (Microsoft To Do, ChatGPT, Claude from the Store...) don't show in the uninstall
; list. Windows keeps one registry key per installed package, named PackageName_Version_Arch__PublisherId.
FT_InStoreApps(patterns) {
    key := "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages"
    for pat in patterns {
        rx := "i)^" StrReplace(RegExReplace(pat, "([.+?^${}()|\[\]\\])", "\$1"), "*", ".*") "$"
        try loop reg, key, "K" {
            if RegExMatch(A_LoopRegName, rx)
                return true
        }
    }
    return false
}

FT_InUninstallList(pattern) {
    rx := "i)^" StrReplace(RegExReplace(pattern, "([.+?^${}()|\[\]\\])", "\$1"), "*", ".*") "$"   ; whole name, so "Git" doesn't match "GitHub Desktop"
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
    lv := g.AddListView("w660 r18 y+10 -Multi Grid", ["Tool", "Type", "Status", "What it does"])
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
                MsgBox(t[1] " is installed. Start it from the Start menu (type " Chr(34) t[1] Chr(34) ").", "PCMigrate", "Iconi")
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
        ; The window shows winget's progress. winget's result code is written to a temp file
        ; so PCMigrate can react: refresh the list on success, offer the web page on failure
        ; (e.g. the publisher moved the download and winget's link gives "404 Not found").
        tmp := A_Temp "\pcmigrate-install-" A_TickCount ".txt"
        try FileDelete(tmp)
        cmd := A_ComSpec ' /v:on /c "title Installing ' t[1] ' && winget install --id ' t[6]
            . ' -e --silent --accept-package-agreements --accept-source-agreements & (echo !errorlevel!)>"' tmp '"'
            . ' & echo. & echo ===== Finished. You can close this window. ===== & pause >nul"'
        Run(cmd)    ; per-user installs need no admin; installers that do will ask for it themselves
        started := A_TickCount
        SetTimer(FT_WaitInstall, 1000)

        FT_WaitInstall() {
            if !FileExist(tmp) {
                if (A_TickCount - started > 60 * 60 * 1000)     ; give up watching after an hour
                    SetTimer(, 0)
                return
            }
            SetTimer(, 0)
            code := ""
            try code := Trim(FileRead(tmp), " `r`n")
            try FileDelete(tmp)
            ; 0 = installed; 0x8A150061 / 0x8A15010D = already installed; 0x8A150109 = restart to finish
            if (code = "0" || code = "-1978335135" || code = "-1978334963" || code = "-1978334967") {
                FT_Refresh()
                return
            }
            hex := IsInteger(code) ? Format("0x{:08X}", code & 0xFFFFFFFF) : code
            if MsgBox("winget couldn't install " t[1] " (code " hex ").`n`n"
                . "This usually means the publisher moved the download and winget's link is out of date. "
                . "It is normally fixed within a few days.`n`n"
                . "Open the " t[1] " web page to download it yourself?", "PCMigrate - Install", "YesNo Icon!") = "Yes"
                Run(t[7])
        }
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
