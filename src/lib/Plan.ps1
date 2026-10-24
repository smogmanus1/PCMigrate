# ==============================================================================
# PCMigrate - Plan.ps1
# Opens a migration package (old or new format) and builds the restore plan:
# one item per app, settings folder, registry key, Windows setting and path fix,
# each with a status, a reason, notes and a default selection.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

# Status -> label, colour (for GUI/report), selected by default, selectable
$script:PMStatus = [ordered]@{
    Install      = @{ Label = 'Will install';        Color = 'ForestGreen'; Default = $true;  Selectable = $true }
    Suggest      = @{ Label = 'Suggested';            Color = 'RoyalBlue';   Default = $true;  Selectable = $true }
    Manual       = @{ Label = 'Install by hand';      Color = 'RoyalBlue';   Default = $true;  Selectable = $true }
    Ready        = @{ Label = 'App installed here';   Color = 'ForestGreen'; Default = $true;  Selectable = $true }
    WithInstall  = @{ Label = 'App installs first';   Color = 'ForestGreen'; Default = $true;  Selectable = $true }
    Shared       = @{ Label = 'Shared settings';      Color = 'ForestGreen'; Default = $true;  Selectable = $true }
    Recommended  = @{ Label = 'Recommended';          Color = 'ForestGreen'; Default = $true;  Selectable = $true }
    Option       = @{ Label = 'Optional';             Color = 'Black';       Default = $false; Selectable = $true }
    Installed    = @{ Label = 'Already installed';    Color = 'Gray';        Default = $false; Selectable = $false }
    Exists       = @{ Label = 'Already set up here';  Color = 'Gray';        Default = $false; Selectable = $true }
    NotInstalled = @{ Label = 'App not installed';    Color = 'DimGray';     Default = $false; Selectable = $true }
    Leftover     = @{ Label = 'Leftover / portable';  Color = 'DimGray';     Default = $false; Selectable = $true }
    Check        = @{ Label = 'Device not found';     Color = 'DarkOrange';  Default = $false; Selectable = $true }
    Hardware     = @{ Label = 'Wrong hardware';       Color = 'Firebrick';   Default = $false; Selectable = $true }
    Skip         = @{ Label = 'Not recommended';      Color = 'Firebrick';   Default = $false; Selectable = $true }
    Retired      = @{ Label = 'Retired';              Color = 'Gray';        Default = $false; Selectable = $true }
    Info         = @{ Label = 'Info';                 Color = 'SteelBlue';   Default = $false; Selectable = $false }
}

$script:PMGroups = @('Apps to install', 'Install by hand', 'Suggested for this PC', 'App settings', 'Registry settings', 'Windows settings', 'Paths')

function New-PMItem([string]$group, [string]$kind, [string]$name, [string]$status, [string]$reason, $notes, $data, [double]$size = 0, $default = $null) {
    $meta = $script:PMStatus[$status]
    $sel = $meta.Default
    if ($null -ne $default) { $sel = [bool]$default }
    if (-not $meta.Selectable) { $sel = $false }
    return [pscustomobject]@{
        Group    = $group
        Kind     = $kind
        Name     = $name
        Status   = $status
        Label    = $meta.Label
        Reason   = $reason
        Notes    = @($notes | Where-Object { $_ })
        SizeMB   = $size
        Selected = $sel
        Default  = $sel
        Data     = $data
    }
}

# ----------------------------- Package ----------------------------------------
function Find-PMPackages([string]$root) {
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
             Where-Object { (Test-Path (Join-Path $_.FullName 'manifest.json')) -or (Test-Path (Join-Path $_.FullName 'AllPrograms.csv')) } |
             Sort-Object LastWriteTime -Descending)
}

function Open-PMPackage([string]$path) {
    $manifest = Read-PMJson (Join-Path $path 'manifest.json')
    $schema = 1
    if ($manifest -and $manifest.Schema) { $schema = [int]$manifest.Schema }
    $source = Read-PMJson (Join-Path $path 'system\profile.json')
    $oldUser = $null
    if ($source) { $oldUser = $source.UserName }
    if (-not $oldUser) {
        $t = Join-Path $path 'logs\export-transcript.txt'
        if (Test-Path -LiteralPath $t) {
            $m = Select-String -LiteralPath $t -Pattern '^Username:\s*.+\\(.+)$' | Select-Object -First 1
            if ($m) { $oldUser = $m.Matches[0].Groups[1].Value.Trim() }
        }
    }
    $computer = if ($source) { $source.ComputerName } else { ((Split-Path $path -Leaf) -split '_')[0] }
    return [pscustomobject]@{
        Path       = $path
        Name       = Split-Path $path -Leaf
        Schema     = $schema
        Manifest   = $manifest
        Source     = $source
        Computer   = $computer
        OldUser    = $oldUser
        Programs   = Read-PMCsv (Join-Path $path 'AllPrograms.csv')
        WingetInv  = Read-PMCsv (Join-Path $path 'WingetInventory.csv')
        WingetJson = Read-PMJson (Join-Path $path 'winget-apps.json')
        Manual     = Read-PMCsv (Join-Path $path 'ManualInstall.csv')
    }
}

# First [HKEY_...] line of a .reg file = the key it restores.
function Get-PMRegFileKey([string]$file) {
    try {
        $bytes = [IO.File]::ReadAllBytes($file)
        $enc = Get-PMTextEncoding $bytes
        if (-not $enc) { return $null }
        $text = Read-PMText $bytes $enc
        $m = [regex]::Match($text, '(?m)^\[(HKEY_[^\]]+)\]')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}

# Microsoft\<sub> folders inside Roaming: Office ones follow Office, the rest are Windows-internal.
$script:PMOfficeSub = @('Signatures', 'Templates', 'Proof', 'UProof', 'Word', 'Excel', 'Outlook', 'OneNote', 'Office', 'QuickStyles', 'Stationery', 'AddIns', 'Spelling', 'PowerPoint', 'Access', 'Document Building Blocks')

# ----------------------------- Settings verdict -------------------------------
function Get-PMSettingsVerdict([string]$name, $ctx) {
    $notes = New-Object System.Collections.Generic.List[string]
    $matched = @(Find-PMProgram $ctx.SrcIndex $name $ctx.Rules.Aliases)
    $cands = @($name) + @($matched | ForEach-Object { $_.Name }) + @($matched | ForEach-Object { $_.Publisher })
    $v = Get-PMRuleVerdict $ctx.Rules $cands 'settings' $ctx.Hw $ctx.Retired
    foreach ($n in $v.Notes) { $notes.Add($n) }
    if ($v.Status) { return @{ Status = $v.Status; Reason = $v.Reason; Notes = @($notes) } }

    if ($ctx.Rules.Shared -contains $name) {
        return @{ Status = 'Shared'; Reason = 'Settings shared by Windows or several apps - small and harmless.'; Notes = @($notes) }
    }
    if ($matched.Count -gt 0) {
        foreach ($p in $matched) {
            $t = Test-PMProgramInstalled $ctx.DstIndex $p.Name
            if ($t) { return @{ Status = 'Ready'; Reason = "Settings for $($t.Name), which is installed here."; Notes = @($notes) } }
        }
        foreach ($p in $matched) {
            $wid = $p.WingetId
            if (-not $wid) { $wid = Get-PMWingetAlternative $ctx.Rules $p.Name }
            if ($wid -and $ctx.InstallIds.Contains($wid)) {
                return @{ Status = 'WithInstall'; Reason = "Settings for $($p.Name) - it will be installed earlier in this run."; Notes = @($notes) }
            }
        }
        $names = (@($matched | ForEach-Object { $_.Name }) | Select-Object -First 2) -join ', '
        return @{ Status = 'NotInstalled'; Reason = "Settings for $names, which is not installed here yet. Install it first, then restore."; Notes = @($notes) }
    }
    $direct = @(Find-PMProgram $ctx.DstIndex $name $ctx.Rules.Aliases)
    if ($direct.Count -gt 0) {
        return @{ Status = 'Ready'; Reason = "Settings for $($direct[0].Name), which is installed here."; Notes = @($notes) }
    }
    return @{ Status = 'Leftover'; Reason = 'No matching program on either PC - leftover from an uninstalled app, or a portable app.'; Notes = @($notes) }
}

# ----------------------------- Build plan -------------------------------------
# $progress: scriptblock { param($pct, $text) } for UI updates (optional)
function New-PMPlan($pkg, $target, $rules, $ini, $installedIds, $targetPrograms, [scriptblock]$progress) {
    if (-not $progress) { $progress = { param($p, $t) } }
    $items = New-Object System.Collections.Generic.List[object]

    $script:PMRules = $rules
    $script:PMCtx   = $null
    $script:PMIni   = $ini
    $script:PMHw    = New-PMHardwareText $target
    $ctx = @{
        Rules      = $rules
        Hw         = New-PMHardwareText $target
        Retired    = @(Get-PMList $ini 'Retired')
        SrcIndex   = New-PMProgramIndex $pkg.Programs $pkg.WingetInv
        DstIndex   = New-PMProgramIndex $targetPrograms @()
        InstallIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    }
    $script:PMCtx = $ctx
    $idName = @{}
    foreach ($w in $pkg.WingetInv) { if ($w.Id -and $w.Name) { $idName[$w.Id] = $w.Name } }

    # ---- 1. Apps to install (winget) ----
    & $progress 5 'Checking apps...'
    if ($pkg.WingetJson) {
        foreach ($s in $pkg.WingetJson.Sources) {
            $srcName = "$($s.SourceDetails.Name)"
            foreach ($p in $s.Packages) {
                $id = "$($p.PackageIdentifier)"
                if (-not $id) { continue }
                $name = if ($idName.ContainsKey($id)) { $idName[$id] } else { $id }
                $data = @{ Id = $id; Source = $srcName }
                if ($installedIds.Contains($id) -or (Test-PMProgramInstalled $ctx.DstIndex $name)) {
                    $items.Add((New-PMItem 'Apps to install' 'winget' $name 'Installed' 'Already installed on this PC.' @() $data))
                    continue
                }
                $v = Get-PMRuleVerdict $rules @($id, $name) 'install' $ctx.Hw $ctx.Retired
                $status = if ($v.Status) { $v.Status } else { 'Install' }
                $reason = if ($v.Reason) { $v.Reason } else { "winget package $id ($srcName)" }
                $it = New-PMItem 'Apps to install' 'winget' $name $status $reason $v.Notes $data
                $items.Add($it)
                if ($it.Selected) { [void]$ctx.InstallIds.Add($id) }
            }
        }
    }

    # ---- 2. Install by hand ----
    & $progress 15 'Checking manual installs...'
    $ignore = @(Get-PMList $ini 'ManualIgnore')
    foreach ($m in $pkg.Manual) {
        if (-not $m.Name -or (Test-PMLike $m.Name $ignore)) { continue }
        $data = @{ Website = $m.Website; Version = $m.Version; Publisher = $m.Publisher }
        $t = Test-PMProgramInstalled $ctx.DstIndex $m.Name
        if ($t) {
            $items.Add((New-PMItem 'Install by hand' 'checklist' $m.Name 'Installed' "Already installed ($($t.Name))." @() $data))
            continue
        }
        $v = Get-PMRuleVerdict $rules @($m.Name, $m.Publisher) 'checklist' $ctx.Hw $ctx.Retired
        # Installable with winget after all? Then it moves to the automatic list.
        $alt = Get-PMWingetAlternative $rules $m.Name
        if ($alt -and -not $v.Status) {
            if ($installedIds.Contains($alt)) {
                $items.Add((New-PMItem 'Apps to install' 'winget' $m.Name 'Installed' 'Already installed on this PC.' @() @{ Id = $alt; Source = 'winget' }))
            } else {
                $it = New-PMItem 'Apps to install' 'winget' $m.Name 'Install' "Installed by hand on the old PC, but winget has it: $alt - installs automatically." $v.Notes @{ Id = $alt; Source = 'winget' }
                $items.Add($it)
                if ($it.Selected) { [void]$ctx.InstallIds.Add($alt) }
            }
            continue
        }
        $status = if ($v.Status) { $v.Status } else { 'Manual' }
        $extra = @($m.Version, $m.Publisher, $m.Website) | Where-Object { $_ }
        $reason = if ($v.Reason) { $v.Reason } else { 'Not available from winget - download it from the publisher. ' + ($extra -join ' | ') }
        $items.Add((New-PMItem 'Install by hand' 'checklist' $m.Name $status $reason $v.Notes $data))
    }

    # ---- 3. Suggested for this PC ----
    foreach ($s in (Get-PMSuggestions $rules $ctx.Hw $installedIds $ctx.DstIndex)) {
        if ($s.Installed) { continue }
        if ($s.Winget) {
            $items.Add((New-PMItem 'Suggested for this PC' 'winget' $s.Name 'Suggest' $s.Note @() @{ Id = $s.Winget; Source = 'winget' }))
            [void]$ctx.InstallIds.Add($s.Winget)
        } else {
            $items.Add((New-PMItem 'Suggested for this PC' 'info' $s.Name 'Info' $s.Note @() @{}))
        }
    }

    # ---- 4. App settings (AppData) ----
    $settingsItems = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('Roaming', 'Local')) {
        $base = Join-Path $pkg.Path "AppData\$scope"
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $targetBase = if ($scope -eq 'Roaming') { $env:APPDATA } else { $env:LOCALAPPDATA }
        $dirs = @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)
        $i = 0
        foreach ($d in $dirs) {
            $i++
            & $progress (20 + [int](40 * $i / [math]::Max(1, $dirs.Count))) "Checking $scope settings: $($d.Name)"
            if ($scope -eq 'Roaming' -and $d.Name -eq 'Microsoft') {
                foreach ($sub in Get-ChildItem -LiteralPath $d.FullName -Directory -Force -ErrorAction SilentlyContinue) {
                    $data = @{ Source = $sub.FullName; Target = (Join-Path $targetBase "Microsoft\$($sub.Name)"); Scope = $scope }
                    if ($script:PMOfficeSub -contains $sub.Name) {
                        $office = Test-PMProgramInstalled $ctx.DstIndex 'Microsoft 365'
                        if (-not $office) { $office = Test-PMProgramInstalled $ctx.DstIndex 'Microsoft Office' }
                        if ($office) { $st = 'Ready'; $rs = "Office settings ($($sub.Name)) - Office is installed here." }
                        else { $st = 'NotInstalled'; $rs = "Office settings ($($sub.Name)) - Office is not installed here yet." }
                        $notes = @()
                        if ($sub.Name -eq 'Signatures') { $notes = @('Your Outlook email signatures.') }
                        $it = New-PMItem 'App settings' 'dir' "Microsoft\$($sub.Name)" $st $rs $notes $data (Get-PMFolderSizeMB $sub.FullName)
                    } else {
                        $it = New-PMItem 'App settings' 'dir' "Microsoft\$($sub.Name)" 'Skip' 'Windows-internal data - not useful on another PC.' @() $data (Get-PMFolderSizeMB $sub.FullName)
                    }
                    $items.Add($it); $settingsItems.Add($it)
                }
                continue
            }
            $v = Get-PMSettingsVerdict $d.Name $ctx
            $data = @{ Source = $d.FullName; Target = (Join-Path $targetBase $d.Name); Scope = $scope }
            $it = New-PMItem 'App settings' 'dir' $d.Name $v.Status $v.Reason $v.Notes $data (Get-PMFolderSizeMB $d.FullName)
            if ($scope -eq 'Local') { $it.Name = "Local\$($d.Name)" }
            if ((Test-Path -LiteralPath $data.Target) -and $it.Status -in @('Ready', 'Shared')) {
                $it.Notes = @($it.Notes) + @('This app already has settings here - they are backed up, then replaced.')
            }
            $items.Add($it); $settingsItems.Add($it)
        }
        $loose = @(Get-ChildItem -LiteralPath $base -File -Force -ErrorAction SilentlyContinue)
        if ($loose.Count -gt 0) {
            $data = @{ Source = $base; Target = $targetBase; Scope = $scope; FilesOnly = $true; Files = @($loose | ForEach-Object { $_.Name }) }
            $items.Add((New-PMItem 'App settings' 'loose' "($scope - $($loose.Count) loose files)" 'Option' ("Files directly in AppData\$scope`: " + ((@($loose | ForEach-Object { $_.Name }) | Select-Object -First 5) -join ', ')) @() $data 0 $false))
        }
    }

    # ---- 5. Registry settings ----
    $regDir = Join-Path $pkg.Path 'Registry'
    if (Test-Path -LiteralPath $regDir) {
        $files = @(Get-ChildItem -LiteralPath $regDir -Filter *.reg -File)
        $i = 0
        foreach ($f in $files) {
            $i++
            & $progress (60 + [int](15 * $i / [math]::Max(1, $files.Count))) "Checking registry: $($f.BaseName)"
            $key = Get-PMRegFileKey $f.FullName
            if (-not $key) { $key = "HKEY_CURRENT_USER\Software\$($f.BaseName)" }
            $vendor = ($key -split '\\')[-1]
            $v = Get-PMSettingsVerdict $vendor $ctx
            $data = @{ Source = $f.FullName; Key = $key }
            $it = New-PMItem 'Registry settings' 'reg' $vendor $v.Status $v.Reason $v.Notes $data ([math]::Round($f.Length / 1MB, 2))
            $items.Add($it); $settingsItems.Add($it)
        }
    }

    # ---- 6. Windows settings (new-format packages) ----
    & $progress 76 'Checking Windows settings...'
    foreach ($it in (New-PMWindowsItems $pkg $target)) { $items.Add($it) }

    # ---- 7. Paths ----
    & $progress 80 'Scanning settings for saved paths...'
    foreach ($it in (New-PMPathItems $pkg $target $settingsItems $progress)) { $items.Add($it) }

    & $progress 100 'Plan ready.'
    return $items.ToArray()
}

# Does a program exist here? Accepts full paths and bare commands found on PATH (e.g. 'python').
function Test-PMProgramPath([string]$exe) {
    if (-not $exe) { return $false }
    if ([IO.Path]::IsPathRooted($exe)) { return (Test-Path -LiteralPath $exe) }
    # real programs only - not PowerShell aliases (curl/wget in 5.1) or the Store's python.exe stubs
    $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]($cmd -and $cmd.Source -notlike '*\Microsoft\WindowsApps\*')
}

# Is the program behind a startup item / task being installed earlier in this run?
function Test-PMInstallsThisRun([string[]]$names) {
    if (-not $script:PMCtx) { return $null }
    foreach ($n in $names) {
        if (-not $n -or $n.Length -lt 3) { continue }
        foreach ($p in @(Find-PMProgram $script:PMCtx.SrcIndex $n $script:PMCtx.Rules.Aliases)) {
            $wid = $p.WingetId
            if (-not $wid) { $wid = Get-PMWingetAlternative $script:PMCtx.Rules $p.Name }
            if ($wid -and $script:PMCtx.InstallIds.Contains($wid)) { return $p.Name }
        }
    }
    return $null
}

# Names a startup item or task can be recognised by: its own name, the program
# file name and the folders it lives in (e.g. ...\AMD\CNext\RadeonSoftware.exe).
function Get-PMPathCandidates([string]$name, [string]$exe) {
    $c = @($name)
    $exe = $exe -replace '(?i)^[A-Z]:\\Users\\[^\\]+', ''   # the user name is not a program name
    if ($exe) {
        $c += [IO.Path]::GetFileNameWithoutExtension($exe)
        $c += @($exe -split '\\' | Select-Object -Skip 1 | Where-Object { $_ -and $_ -notmatch '^(Program Files( \(x86\))?|ProgramData|Users|AppData|Local|Roaming|Programs|Windows|System32)$' })
    }
    return $c
}

# ----------------------------- Windows settings items -------------------------
function New-PMWindowsItems($pkg, $target) {
    $out = @()
    $sys = Join-Path $pkg.Path 'system'
    if (-not (Test-Path -LiteralPath $sys)) { return $out }
    $G = 'Windows settings'
    $sameChassis = (-not $pkg.Source) -or ($pkg.Source.Chassis -eq $target.Chassis)

    $regs = @(
        @{ File = 'explorer.reg';    Name = 'File Explorer options';      Why = 'File extensions, hidden files, taskbar and Start layout options.'; Sel = $true },
        @{ File = 'personalize.reg'; Name = 'Light / dark mode and accent colour'; Why = 'Your colour and theme choices.'; Sel = $true },
        @{ File = 'keyboard.reg';    Name = 'Keyboard repeat rate';       Why = 'Key repeat delay and speed.'; Sel = $true },
        @{ File = 'mouse.reg';       Name = 'Mouse settings';             Why = 'Pointer speed, double-click speed, button swap.'; Sel = $sameChassis }
    )
    foreach ($r in $regs) {
        $f = Join-Path $sys $r.File
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $notes = @()
        if ($r.File -eq 'mouse.reg' -and -not $sameChassis) { $notes = @("The old PC was a $($pkg.Source.Chassis), this one is a $($target.Chassis) - touchpad and mouse often want different speeds.") }
        $out += New-PMItem $G 'reg' $r.Name 'Recommended' $r.Why $notes @{ Source = $f; Key = (Get-PMRegFileKey $f) } 0 $r.Sel
    }

    # Known folders (Documents, Desktop... moved to another location)
    $kf = Read-PMJson (Join-Path $sys 'knownfolders.json')
    if ($kf) {
        $srcProfile = if ($pkg.Source -and $pkg.Source.UserProfile) { "$($pkg.Source.UserProfile)".TrimEnd('\') } else { '' }
        $defaults = @{ Desktop = 'Desktop'; Documents = 'Documents'; Downloads = 'Downloads'; Music = 'Music'; Pictures = 'Pictures'; Videos = 'Videos'; Favorites = 'Favorites' }
        foreach ($p in $kf.PSObject.Properties) {
            $name = $p.Name; $raw = "$($p.Value.Raw)"
            # older captures stored expanded paths - turn C:\Users\old\... back into %USERPROFILE%\...
            if ($srcProfile -and $raw.StartsWith($srcProfile + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $raw = '%USERPROFILE%' + $raw.Substring($srcProfile.Length)
            }
            if (-not $raw -or $raw -ieq "%USERPROFILE%\$($defaults[$name])") { continue }   # Windows' default location
            $expanded = [Environment]::ExpandEnvironmentVariables($raw)
            $current = $target.KnownFolders.$name
            $curRaw = if ($current) { "$($current.Raw)" } else { '' }
            if ([Environment]::ExpandEnvironmentVariables($curRaw).TrimEnd('\') -ieq $expanded.TrimEnd('\')) { continue }   # already the same here
            $data = @{ ValueName = $p.Value.ValueName; Raw = $raw; Folder = $name }
            if (Test-Path -LiteralPath $expanded) {
                $out += New-PMItem $G 'knownfolder' "$name folder -> $raw" 'Option' "On the old PC your $name folder lived at $raw. That folder exists here too." @('File Explorer restarts at the end so the change shows up.') $data 0 $true
            } else {
                $out += New-PMItem $G 'knownfolder' "$name folder -> $raw" 'Option' "On the old PC your $name folder lived at $raw, which does not exist on this PC (yet)." @('Select only if that location will exist - e.g. after mapping a drive.') $data 0 $false
            }
        }
    }

    # Environment variables
    $envJson = Read-PMJson (Join-Path $sys 'env-user.json')
    if ($envJson) {
        $vars = @(); $pathAdd = @(); $pathMissing = @()
        $skipVars = @('PATH', 'TEMP', 'TMP', 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')
        $currentPath = @(([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') | Where-Object { $_ })
        foreach ($p in $envJson.PSObject.Properties) {
            if ($p.Name -ieq 'PATH') {
                foreach ($e in ("$($p.Value)" -split ';')) {
                    if (-not $e) { continue }
                    if ($currentPath -contains $e) { continue }
                    if (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($e))) { $pathAdd += $e } else { $pathMissing += $e }
                }
                continue
            }
            if ($skipVars -contains $p.Name) { continue }
            if ([Environment]::GetEnvironmentVariable($p.Name, 'User') -eq "$($p.Value)") { continue }
            $vars += [pscustomobject]@{ Name = $p.Name; Value = "$($p.Value)" }
        }
        if ($vars.Count) {
            $out += New-PMItem $G 'envvars' "User environment variables ($($vars.Count))" 'Recommended' ((@($vars | ForEach-Object { $_.Name }) -join ', ')) @() @{ Vars = $vars }
        }
        if ($pathAdd.Count) {
            $notes = @()
            if ($pathMissing.Count) { $notes = @("Not added (folder missing here): " + ($pathMissing -join '; ')) }
            $out += New-PMItem $G 'envpath' "Add $($pathAdd.Count) folder(s) to your PATH" 'Recommended' ($pathAdd -join '; ') $notes @{ Entries = $pathAdd }
        }
    }

    # Startup items
    $startupSkip = @(Get-PMList $script:PMIni 'StartupSkip')
    $taskSkip    = @(Get-PMList $script:PMIni 'TaskSkip')
    $st = @(Read-PMJson (Join-Path $sys 'startup.json'))
    $runNow = @(Get-PMRegValues 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' | ForEach-Object { $_.Name })
    foreach ($s in $st) {
        if (-not $s -or -not $s.Name) { continue }
        if (Test-PMLike $s.Name $startupSkip) { continue }
        $exists = $false
        if ($s.Type -eq 'Run' -and ($runNow -contains $s.Name)) { $exists = $true }
        if ($s.Type -eq 'Folder' -and (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) $s.File))) { $exists = $true }
        $exe = [Environment]::ExpandEnvironmentVariables("$($s.Exe)")
        if ($s.Type -eq 'Folder' -and [IO.Path]::GetExtension("$($s.File)") -ne '.lnk') { $exe = '' }   # the script itself is what gets copied
        $data = @{ Entry = $s; Package = $pkg.Path }
        if ($exists) { $out += New-PMItem $G 'startup' "Startup: $($s.Name)" 'Exists' 'Already starts with Windows here.' @() $data; continue }
        $v = Get-PMRuleVerdict $script:PMRules (Get-PMPathCandidates $s.Name $exe) 'task' $script:PMHw @(Get-PMList $script:PMIni 'Retired')
        if ($v.Status) { $out += New-PMItem $G 'startup' "Startup: $($s.Name)" $v.Status $v.Reason $v.Notes $data; continue }
        if (-not $exe -or (Test-PMProgramPath $exe)) {
            $out += New-PMItem $G 'startup' "Startup: $($s.Name)" 'Option' "Starts with Windows: $($s.Command)" $v.Notes $data 0 $true
        } elseif ($app = Test-PMInstallsThisRun (@($s.Name) + @(Get-PMPathCandidates '' $exe))) {
            $out += New-PMItem $G 'startup' "Startup: $($s.Name)" 'WithInstall' "Starts with Windows - $app is installed earlier in this run." (@('Skipped automatically if the program is still missing at that point.') + $v.Notes) $data
        } else {
            $out += New-PMItem $G 'startup' "Startup: $($s.Name)" 'NotInstalled' "Program not found here: $exe" @() $data
        }
    }

    # Scheduled tasks
    $tasks = @(Read-PMJson (Join-Path $sys 'tasks.json'))
    foreach ($t in $tasks) {
        if (-not $t -or -not $t.Name) { continue }
        if ((Test-PMLike $t.Name $taskSkip) -or (Test-PMLike ("$($t.Path)$($t.Name)") $taskSkip)) { continue }
        $data = @{ Task = $t; Xml = (Join-Path $sys "tasks\$($t.File)") }
        $have = $null
        try { $have = Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop } catch { }
        if ($have) { $out += New-PMItem $G 'task' "Task: $($t.Name)" 'Exists' 'A task with this name already exists here.' @() $data; continue }
        $exe = [Environment]::ExpandEnvironmentVariables("$($t.Exe)")
        $v = Get-PMRuleVerdict $script:PMRules (@(Get-PMPathCandidates $t.Name $exe) + @("$($t.Path)" -split '\\' | Where-Object { $_ })) 'task' $script:PMHw @(Get-PMList $script:PMIni 'Retired')
        if ($v.Status) { $out += New-PMItem $G 'task' "Task: $($t.Name)" $v.Status $v.Reason $v.Notes $data; continue }
        $notes = @($v.Notes)
        if ($t.Password) { $notes += 'Runs whether or not you are signed in - Windows will ask for your password.' }
        if (-not $exe -or (Test-PMProgramPath $exe)) {
            $out += New-PMItem $G 'task' "Task: $($t.Name)" 'Option' "Scheduled task running: $($t.Exe) $($t.Args)" $notes $data 0 $true
        } elseif (-not [IO.Path]::IsPathRooted($exe)) {
            $out += New-PMItem $G 'task' "Task: $($t.Name)" 'Option' "Scheduled task running: $($t.Exe) $($t.Args)" (@("'$exe' is not on this PC's PATH yet - install it first or the task will fail.") + $notes) $data 0 $false
        } elseif ($app = Test-PMInstallsThisRun (@($t.Name) + @(Get-PMPathCandidates '' $exe))) {
            $out += New-PMItem $G 'task' "Task: $($t.Name)" 'WithInstall' "Scheduled task - $app is installed earlier in this run." (@('Skipped automatically if the program is still missing at that point.') + $notes) $data
        } else {
            $out += New-PMItem $G 'task' "Task: $($t.Name)" 'NotInstalled' "Program not found here: $exe" @() $data
        }
    }

    # Fonts
    $fonts = Read-PMCsv (Join-Path $pkg.Path 'Fonts\fonts.csv')
    if ($fonts.Count) {
        $winFonts = '^(Segoe|Ebrima|Gadugi|Leelawadee|Malgun|Microsoft|Myanmar|Nirmala|Javanese|Mongolian|Sitka|Cascadia|Bahnschrift|Ink Free|HoloLens|Yu Gothic|MS Gothic|SimSun|NSimSun|MingLiU|PMingLiU|Sans Serif Collection|Arial|Calibri|Cambria|Candara|Consolas|Constantia|Corbel|Courier New|Georgia|Lucida|Palatino|Tahoma|Times New Roman|Trebuchet|Verdana|Webdings|Wingdings|Symbol|Marlett|Gabriola|Comic Sans|Impact|Franklin Gothic|Mv Boli|MV Boli|Sylfaen|Mangal|Kartika|Vrinda|Shruti|Tunga|Raavi|Latha|Gautami|Kalinga|Iskoola|Nyala|Plantagenet|Euphemia|Gisha|Aharoni|David|Miriam|Narkisim|Levenim|Rod|FrankRuehl|Tw Cen)'
        $missing = @($fonts | Where-Object {
            $_.Name -notmatch $winFonts -and
            -not (Test-Path -LiteralPath (Join-Path "$env:WINDIR\Fonts" $_.File)) -and
            -not (Test-Path -LiteralPath (Join-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" $_.File))
        })
        if ($missing.Count) {
            $out += New-PMItem $G 'fonts' "Install $($missing.Count) font(s)" 'Recommended' ((@($missing | ForEach-Object { $_.Name }) | Select-Object -First 8) -join ', ') @() @{ Fonts = $missing; Dir = (Join-Path $pkg.Path 'Fonts') }
        }
    }

    # Wi-Fi
    $wifiDir = Join-Path $sys 'wifi'
    $wlan = (Get-Service WlanSvc -ErrorAction SilentlyContinue).Status -eq 'Running'
    if (Test-Path -LiteralPath $wifiDir) {
        foreach ($w in Get-ChildItem -LiteralPath $wifiDir -Filter *.xml -File) {
            $ssid = $null
            try { $ssid = ([xml](Get-Content -LiteralPath $w.FullName -Raw)).WLANProfile.name } catch { }
            if (-not $ssid) { $ssid = $w.BaseName }
            $data = @{ File = $w.FullName; Name = $ssid }
            if (-not $wlan) {
                $out += New-PMItem $G 'wifi' "Wi-Fi: $ssid" 'Option' 'No Wi-Fi on this PC (WLAN service not running).' @() $data 0 $false
            } elseif (Test-PMWifiProfile $ssid) {
                $out += New-PMItem $G 'wifi' "Wi-Fi: $ssid" 'Exists' 'This network is already saved on this PC.' @() $data
            } else {
                $out += New-PMItem $G 'wifi' "Wi-Fi: $ssid" 'Recommended' 'Saved Wi-Fi network with its password.' @() $data
            }
        }
    }

    # Mapped network drives
    foreach ($n in @(Read-PMJson (Join-Path $sys 'netdrives.json'))) {
        if (-not $n -or -not $n.Letter) { continue }
        $out += New-PMItem $G 'netdrive' "Network drive $($n.Letter): $($n.Remote)" 'Option' 'Reconnects at sign-in.' @('Only works where that network share is reachable (same home network or VPN).') @{ Drive = $n } 0 $false
    }

    # Hosts file
    $hosts = Join-Path $sys 'hosts.txt'
    if (Test-Path -LiteralPath $hosts) {
        $lines = @(Get-Content -LiteralPath $hosts | Where-Object { $_ -and $_ -notmatch '^\s*#' })
        if ($lines.Count) {
            $out += New-PMItem $G 'hosts' "Custom hosts entries ($($lines.Count))" 'Option' ((@($lines) | Select-Object -First 3) -join ' | ') @('Local network names may not apply on a different network.') @{ Lines = $lines } 0 $false
        }
    }

    # Personal files (dotfiles, PowerShell profiles, Terminal settings)
    foreach ($f in @(Read-PMJson (Join-Path $pkg.Path 'files\files.json'))) {
        if (-not $f -or -not $f.Name) { continue }
        $dest = ConvertFrom-PMPortablePath $f.Origin
        $data = @{ Source = (Join-Path $pkg.Path "files\$($f.Stored)"); Target = $dest }
        $parent = Split-Path $dest -Parent
        if ($f.NeedsParent -and -not (Test-Path -LiteralPath $parent)) {
            $out += New-PMItem $G 'file' $f.Name 'NotInstalled' "The app is not installed here ($parent missing)." @() $data
        } else {
            $out += New-PMItem $G 'file' $f.Name 'Recommended' $dest @() $data
        }
    }
    return $out
}

function Test-PMWifiProfile([string]$name) {
    if (-not (Get-Command netsh -ErrorAction SilentlyContinue)) { return $false }
    & netsh wlan show profiles name="$name" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ----------------------------- Path items -------------------------------------
function New-PMPathItems($pkg, $target, $settingsItems, [scriptblock]$progress) {
    $out = @()
    $G = 'Paths'
    $roots = @{}
    $userRefs = 0
    $oldProfile = $null
    if ($pkg.Source -and $pkg.Source.UserProfile) { $oldProfile = "$($pkg.Source.UserProfile)".TrimEnd('\') }
    elseif ($pkg.OldUser) { $oldProfile = "C:\Users\$($pkg.OldUser)" }
    # Drive letters already used by network drives or DOS-device mappings
    $reserved = @(); $netLetters = @()
    foreach ($n in @(Read-PMJson (Join-Path $pkg.Path 'system\netdrives.json'))) { if ($n -and $n.Letter) { $netLetters += "$($n.Letter)".Substring(0, 1).ToUpperInvariant() } }
    foreach ($k in Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue) { $netLetters += $k.PSChildName.Substring(0, 1).ToUpperInvariant() }
    $dos = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices' -ErrorAction SilentlyContinue
    if ($dos) { foreach ($v in $dos.GetValueNames()) { if ($v -match '^([A-Za-z]):$') { $reserved += $Matches[1].ToUpperInvariant() } } }
    $active = @($settingsItems | Where-Object { $_.Status -notin @('Skip', 'Hardware', 'Retired') })
    $i = 0
    foreach ($it in $active) {
        $i++
        if ($progress) { & $progress (80 + [int](18 * $i / [math]::Max(1, $active.Count))) "Scanning for saved paths: $($it.Name)" }
        $r = Find-PMPathRefs $it.Data.Source $oldProfile
        $it.Data.PathRefs = $r
        foreach ($k in $r.Roots.Keys) {
            if (-not $roots.ContainsKey($k)) { $roots[$k] = New-Object System.Collections.Generic.List[string] }
            if (-not $roots[$k].Contains($it.Name)) { $roots[$k].Add($it.Name) }
        }
        $userRefs += $r.User
    }

    $translations = @()
    $maps = @{}
    $aliases = @{}; $aliasRoots = @()
    foreach ($root in ($roots.Keys | Sort-Object)) {
        $res = Resolve-PMPathRoot $root $target $pkg.Source $reserved $netLetters
        $apps = (@($roots[$root]) | Select-Object -First 6) -join ', '
        switch ($res.State) {
            'OK'           { $out += New-PMItem $G 'info' "$root - works here as-is" 'Info' "Used by: $apps" @() @{ Resolution = $res } }
            'Mappable'     { if (-not $maps.ContainsKey($res.Letter)) { $maps[$res.Letter] = @() }; $maps[$res.Letter] += $res }
            'Alias'        { if (-not $aliases.ContainsKey($res.Letter)) { $aliases[$res.Letter] = $res }; $aliasRoots += $root }
            'Rewrite'      { $translations += @{ From = $root; To = $res.Target } }
            default        { $out += New-PMItem $G 'info' "$root - not available here" 'Info' "$($res.Note) Used by: $apps" @() @{ Resolution = $res } }
        }
    }

    foreach ($letter in ($aliases.Keys | Sort-Object)) {
        $to = $aliases[$letter].Target
        $used = (@($aliasRoots | Where-Object { $_.StartsWith("${letter}:") }) | Select-Object -First 4) -join ', '
        $notes = @('Works like SUBST - no files are moved. Takes effect after a restart. Undo removes it.')
        if ($aliases[$letter].Certain) {
            $out += New-PMItem $G 'drivemap' "Make drive ${letter}: another name for $to" 'Recommended' "On the old PC ${letter}: and $($to.TrimEnd('\')) were the same disk. Saved paths like $used keep working." $notes @{ Letter = $letter; AliasOf = $to; Links = @() }
        } else {
            $notes += 'This package has no disk IDs (older capture), so "same disk" is a guess from the label and size - tick it only if you know they were one disk.'
            $out += New-PMItem $G 'drivemap' "Make drive ${letter}: another name for $to" 'Option' "On the old PC ${letter}: and $($to.TrimEnd('\')) look like the same disk. Saved paths like $used would keep working." $notes @{ Letter = $letter; AliasOf = $to; Links = @() } 0 $false
        }
        if ($maps.ContainsKey($letter)) { $maps.Remove($letter) }
    }
    foreach ($letter in ($maps.Keys | Sort-Object)) {
        $links = @($maps[$letter] | ForEach-Object { @{ Top = $_.Top; Target = $_.Target } })
        $desc = (@($maps[$letter] | ForEach-Object { "$($_.Root) -> $($_.Target)" }) -join '; ')
        $out += New-PMItem $G 'drivemap' "Map drive ${letter}: so old paths keep working" 'Recommended' $desc @('Creates links only - no files are moved or copied. Takes effect after a restart. Undo removes it.') @{ Letter = $letter; Links = $links }
    }

    if ($oldProfile -and $userRefs -gt 0 -and ($oldProfile -ine $env:USERPROFILE.TrimEnd('\'))) {
        $translations += @{ From = $oldProfile; To = $env:USERPROFILE.TrimEnd('\') }
    }
    if ($translations.Count) {
        $desc = (@($translations | ForEach-Object { "$($_.From) -> $($_.To)" }) -join '; ')
        $out += New-PMItem $G 'rewrite' 'Update saved paths inside restored settings' 'Recommended' $desc @('Text settings files and registry files only. Binary files are listed in the report.') @{ Translations = $translations }
    }
    return $out
}
