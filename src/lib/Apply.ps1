# ==============================================================================
# PCMigrate - Apply.ps1
# Carries out the selected plan items. Every change is backed up first and
# written to a journal (journal.json) so Undo can put things back exactly.
# Restore sessions live in %USERPROFILE%\PCMigrate\Restores\<timestamp>.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

$script:PMSession = $null
$script:PMDosKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\DOS Devices'

# ----------------------------- Journal ----------------------------------------
function New-PMSession($pkg) {
    $dir = Join-Path $env:USERPROFILE ("PCMigrate\Restores\{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path (Join-Path $dir 'backups') -Force | Out-Null
    $script:PMSession = @{
        Dir     = $dir
        Backups = Join-Path $dir 'backups'
        Counter = 0
        Journal = [ordered]@{
            Tool     = "PCMigrate $script:PMVersion"
            Created  = (Get-Date).ToString('s')
            Computer = $env:COMPUTERNAME
            User     = $env:USERNAME
            Package  = $pkg.Path
            Undone   = $false
            Entries  = New-Object System.Collections.Generic.List[object]
        }
    }
    Save-PMJournal
    return $script:PMSession
}
function Save-PMJournal {
    $j = $script:PMSession.Journal
    $copy = [ordered]@{}
    foreach ($k in $j.Keys) { $copy[$k] = $j[$k] }
    $copy.Entries = $j.Entries.ToArray()
    Save-PMJson $copy (Join-Path $script:PMSession.Dir 'journal.json') 6
}
function Add-PMJournal([hashtable]$entry) {
    $entry.Time = (Get-Date).ToString('s')
    $script:PMSession.Journal.Entries.Add([pscustomobject]$entry)
    Save-PMJournal
}
function New-PMBackupPath([string]$prefix, [string]$ext = '') {
    $script:PMSession.Counter++
    return Join-Path $script:PMSession.Backups ("{0}_{1:000}{2}" -f $prefix, $script:PMSession.Counter, $ext)
}

# ----------------------------- Primitives -------------------------------------
function Test-PMRegKey([string]$key) {
    & reg.exe query $key 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Imports a .reg file (optionally rewriting paths first), backing up the key.
function Import-PMRegFile([string]$file, [string]$key, $translations, [string]$label) {
    $backup = $null
    if ($key -and (Test-PMRegKey $key)) {
        $backup = New-PMBackupPath 'reg' '.reg'
        & reg.exe export $key $backup /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $backup)) {
            Write-PMWarn "    could not back up $key - left unchanged"
            return $false
        }
    }
    $toImport = $file
    if ($translations) {
        $tmp = New-PMBackupPath 'import' '.reg'
        Copy-Item -LiteralPath $file -Destination $tmp -Force
        [void](Update-PMFilePaths $tmp $null $translations)
        $toImport = $tmp
    }
    Add-PMJournal @{ Type = 'regkey'; Key = $key; Backup = $backup; Label = $label }
    & reg.exe import $toImport 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Copy-PMDir([string]$src, [string]$dst, [string]$label) {
    $backup = $null
    if (Test-Path -LiteralPath $dst) {
        $backup = New-PMBackupPath 'dir'
        if (-not (Invoke-PMRobocopy $dst $backup @() (Join-Path $script:PMSession.Dir 'backup.log'))) {
            Write-PMWarn "    could not back up $dst completely - left unchanged"
            return $false
        }
    }
    Add-PMJournal @{ Type = 'dir'; Target = $dst; Backup = $backup; Label = $label }
    return (Invoke-PMRobocopy $src $dst @('/MT:8') (Join-Path $script:PMSession.Dir 'copy.log'))
}

function Copy-PMFile([string]$src, [string]$dst, [string]$label) {
    if (Test-Path -LiteralPath $src -PathType Container) { return (Copy-PMDir $src $dst $label) }
    $backup = $null
    if (Test-Path -LiteralPath $dst) {
        $backup = New-PMBackupPath 'file' ([IO.Path]::GetExtension($dst))
        Copy-Item -LiteralPath $dst -Destination $backup -Force -ErrorAction Stop
    }
    Add-PMJournal @{ Type = 'file'; Target = $dst; Backup = $backup; Label = $label }
    $parent = Split-Path $dst -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    return $true
}

# Sets one registry value, remembering the old one.
function Set-PMRegValue([string]$path, [string]$name, $value, [string]$kind = 'String', [string]$label) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $k = Get-Item -LiteralPath $path
    $existed = $k.GetValueNames() -contains $name
    $old = $null; $oldKind = $null
    if ($existed) {
        $old = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $oldKind = "$($k.GetValueKind($name))"
    }
    Add-PMJournal @{ Type = 'value'; Path = $path; Name = $name; Existed = $existed; Old = $old; OldKind = $oldKind; Label = $label }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $kind -Force | Out-Null
}

# Tells running programs that environment variables changed.
function Send-PMEnvChanged {
    [Environment]::SetEnvironmentVariable('PCMigrateRefresh', '1', 'User')
    [Environment]::SetEnvironmentVariable('PCMigrateRefresh', $null, 'User')
}

# ----------------------------- Item handlers ----------------------------------
function Invoke-PMWingetInstall($items) {
    $results = @()
    $n = 0; $total = @($items).Count
    foreach ($it in $items) {
        $n++
        $id = $it.Data.Id; $src = $it.Data.Source
        Write-Host ''
        Write-Host ("[{0}/{1}] Installing {2}  ({3})" -f $n, $total, $it.Name, $id) -ForegroundColor Cyan
        $wgArgs = @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($src) { $wgArgs += @('--source', $src) }
        $global:LASTEXITCODE = $null
        & winget @wgArgs
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = -1 }
        # 0x8A15002B / 0x8A150061 = already installed / no newer version
        $ok = ($code -in @(0, -1978335189, -1978335135))
        $results += [pscustomobject]@{ Name = $it.Name; Id = $id; Ok = $ok; Code = ('0x{0:X8}' -f ($code -band 0xFFFFFFFF)) }
        Add-PMJournal @{ Type = 'winget'; Id = $id; Ok = $ok; Code = $code; Label = $it.Name }
        if ($ok) { Write-PMOk "  installed: $($it.Name)" } else { Write-PMWarn ("  FAILED: {0} (code 0x{1:X8})" -f $it.Name, ($code -band 0xFFFFFFFF)) }
    }
    return $results
}

function Invoke-PMSettingsItem($it, $translations) {
    switch ($it.Kind) {
        'dir' {
            $ok = Copy-PMDir $it.Data.Source $it.Data.Target $it.Name
            if ($ok -and $translations -and $it.Data.PathRefs -and $it.Data.PathRefs.Files.Count) {
                $n = 0
                foreach ($f in $it.Data.PathRefs.Files) {
                    $rel = $f.Path.Substring($it.Data.Source.Length).TrimStart('\')
                    $n += Update-PMFilePaths (Join-Path $it.Data.Target $rel) $f.Enc $translations
                }
                if ($n) { Write-PMInfo "    $n saved path(s) updated" }
            }
            return $ok
        }
        'loose' {
            foreach ($f in $it.Data.Files) { [void](Copy-PMFile (Join-Path $it.Data.Source $f) (Join-Path $it.Data.Target $f) "$($it.Name): $f") }
            return $true
        }
        'reg' { return (Import-PMRegFile $it.Data.Source $it.Data.Key $translations $it.Name) }
    }
    return $false
}

function Invoke-PMWindowsItem($it, $pkg, [ref]$flags) {
    switch ($it.Kind) {
        'reg' { return (Import-PMRegFile $it.Data.Source $it.Data.Key $null $it.Name) }
        'knownfolder' {
            Set-PMRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' $it.Data.ValueName $it.Data.Raw 'ExpandString' $it.Name
            $flags.Value.Explorer = $true
            return $true
        }
        'envvars' {
            foreach ($v in $it.Data.Vars) {
                $kind = if ($v.Value -match '%') { 'ExpandString' } else { 'String' }
                Set-PMRegValue 'HKCU:\Environment' $v.Name $v.Value $kind "Environment: $($v.Name)"
            }
            Send-PMEnvChanged
            return $true
        }
        'envpath' {
            $k = Get-Item 'HKCU:\Environment'
            $cur = "$($k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))"
            $parts = @($cur -split ';' | Where-Object { $_ })
            foreach ($e in $it.Data.Entries) { if ($parts -notcontains $e) { $parts += $e } }
            Set-PMRegValue 'HKCU:\Environment' 'Path' ($parts -join ';') 'ExpandString' 'User PATH'
            Send-PMEnvChanged
            return $true
        }
        'startup' {
            $e = $it.Data.Entry
            if ($e.Type -eq 'Run') {
                $kind = if ("$($e.Command)" -match '%') { 'ExpandString' } else { 'String' }
                Set-PMRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' $e.Name $e.Command $kind $it.Name
            } else {
                $src = Join-Path $pkg.Path "system\startup\$($e.File)"
                [void](Copy-PMFile $src (Join-Path ([Environment]::GetFolderPath('Startup')) $e.File) $it.Name)
            }
            return $true
        }
        'task' { return (Register-PMTask $it) }
        'fonts' { return (Install-PMFonts $it) }
        'wifi' {
            if (Test-PMWifiProfile $it.Data.Name) { Write-PMInfo '    already saved here - skipped'; return $true }
            & netsh wlan add profile filename="$($it.Data.File)" user=current 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            if ($ok) { Add-PMJournal @{ Type = 'wifi'; Name = $it.Data.Name; Label = $it.Name } }
            return $ok
        }
        'netdrive' {
            $d = $it.Data.Drive
            $key = "HKCU:\Network\$($d.Letter)"
            $existed = Test-Path $key
            $backup = $null
            if ($existed) {
                $backup = New-PMBackupPath 'reg' '.reg'
                & reg.exe export "HKCU\Network\$($d.Letter)" $backup /y 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-PMWarn "    could not back up network drive $($d.Letter): - left unchanged"; return $false }
            }
            Add-PMJournal @{ Type = 'regkey'; Key = "HKEY_CURRENT_USER\Network\$($d.Letter)"; Backup = $backup; Label = $it.Name }
            New-Item -Path $key -Force | Out-Null
            New-ItemProperty -Path $key -Name RemotePath -Value $d.Remote -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name UserName -Value '' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name ProviderName -Value 'Microsoft Windows Network' -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $key -Name ProviderType -Value 0x20000 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $key -Name ConnectionType -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $key -Name DeferFlags -Value 4 -PropertyType DWord -Force | Out-Null
            return $true
        }
        'hosts' {
            $hosts = "$env:WINDIR\System32\drivers\etc\hosts"
            $current = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue)
            $add = @($it.Data.Lines | Where-Object { $current -notcontains $_ })
            if (-not $add.Count) { return $true }
            $backup = New-PMBackupPath 'hosts'
            Copy-Item -LiteralPath $hosts -Destination $backup -Force
            Add-PMJournal @{ Type = 'file'; Target = $hosts; Backup = $backup; Label = $it.Name }
            Add-Content -LiteralPath $hosts -Value (@('', '# Added by PCMigrate') + $add) -Encoding ASCII
            return $true
        }
        'file' { return (Copy-PMFile $it.Data.Source $it.Data.Target $it.Name) }
    }
    return $false
}

function Register-PMTask($it) {
    $t = $it.Data.Task
    try { if (Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop) { Write-PMInfo "    already exists - skipped"; return $true } } catch { }
    $xml = Get-Content -LiteralPath $it.Data.Xml -Raw
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $xml = [regex]::Replace($xml, '<UserId>(?!S-1-5-(18|19|20)<)(?!(SYSTEM|LOCAL SERVICE|NETWORK SERVICE)<)[^<]*</UserId>', "<UserId>$sid</UserId>")
    try {
        if ($t.Password) {
            $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message "Task '$($t.Name)' runs when you are signed out - enter your Windows password"
            if (-not $cred) { return $false }
            Register-ScheduledTask -Xml $xml -TaskName $t.Name -TaskPath $t.Path -User $cred.UserName -Password $cred.GetNetworkCredential().Password -ErrorAction Stop | Out-Null
        } else {
            Register-ScheduledTask -Xml $xml -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null
        }
        Add-PMJournal @{ Type = 'task'; Name = $t.Name; Path = $t.Path; Label = $it.Name }
        return $true
    } catch {
        Write-PMWarn "    $($_.Exception.Message)"
        return $false
    }
}

function Install-PMFonts($it) {
    $fontsDir = "$env:WINDIR\Fonts"
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $n = 0
    foreach ($f in $it.Data.Fonts) {
        $src = Join-Path $it.Data.Dir $f.File
        $dst = Join-Path $fontsDir $f.File
        if (-not (Test-Path -LiteralPath $src) -or (Test-Path -LiteralPath $dst)) { continue }
        try {
            Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
            New-ItemProperty -Path $key -Name $f.Name -Value $f.File -PropertyType String -Force | Out-Null
            Add-PMJournal @{ Type = 'font'; File = $dst; RegName = $f.Name; Label = $f.Name }
            $n++
        } catch { Write-PMWarn "    font $($f.File): $($_.Exception.Message)" }
    }
    Write-PMInfo "    $n font(s) installed"
    return $true
}

function Invoke-PMDriveMap($it) {
    $letter = $it.Data.Letter
    if (Test-Path "${letter}:\") { Write-PMWarn "    Drive ${letter}: is in use now - skipped."; return $false }
    $dosNames = @((Get-Item $script:PMDosKey).GetValueNames())
    if ((Test-Path "HKCU:\Network\$letter") -or ($dosNames -contains "${letter}:")) {
        Write-PMWarn "    Drive ${letter}: is already mapped (network drive or another mapping) - skipped."
        return $false
    }
    $root = "C:\PCMigrate\Drives\$letter"
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Add-PMJournal @{ Type = 'mkdir'; Target = $root; Label = $it.Name }
    }
    foreach ($l in $it.Data.Links) {
        $link = Join-Path $root $l.Top
        if (Test-Path -LiteralPath $link) { continue }
        New-Item -ItemType Junction -Path $link -Target $l.Target | Out-Null
        Add-PMJournal @{ Type = 'junction'; Target = $link; Label = "$link -> $($l.Target)" }
    }
    Set-PMRegValue $script:PMDosKey "${letter}:" "\??\$root" 'String' $it.Name
    return $true
}

# ----------------------------- Orchestration ----------------------------------
function Invoke-PMPlan($plan, $pkg, $ini) {
    $sel = @($plan | Where-Object { $_.Selected })
    $flags = @{ Reboot = $false; Explorer = $false }
    $failed = New-Object System.Collections.Generic.List[string]
    $session = New-PMSession $pkg
    Start-PMLog (Join-Path $session.Dir 'restore.log')
    Write-PMInfo "Restore session: $($session.Dir)"

    if (Get-PMSetting $ini 'Restore' 'CreateRestorePoint' $true) {
        Write-PMStep 'Creating a System Restore point'
        try {
            $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
            Checkpoint-Computer -Description 'PCMigrate restore' -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -ErrorAction Stop
            if (@(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count -gt $before) { Write-PMOk 'Restore point created.' }
            else { Write-PMWarn 'Windows skipped the restore point (it allows one per 24 hours). PCMigrate keeps its own backups.' }
        } catch { Write-PMWarn "Could not create a restore point ($($_.Exception.Message)). Continuing - PCMigrate keeps its own backups." }
    }

    $translations = $null
    $rw = $sel | Where-Object { $_.Kind -eq 'rewrite' } | Select-Object -First 1
    if ($rw) { $translations = $rw.Data.Translations }

    # 1. Apps
    $apps = @($sel | Where-Object { $_.Kind -eq 'winget' })
    $wingetResults = @()
    if ($apps.Count) {
        Write-PMStep "Installing $($apps.Count) app(s) with winget"
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-PMWarn 'winget is not available for this account - install "App Installer" from the Microsoft Store, then run Restore again.'
            foreach ($a in $apps) { $failed.Add("Install: $($a.Name) (winget not available)") }
        } else {
            & winget source update 2>&1 | Out-Null
            $wingetResults = Invoke-PMWingetInstall $apps
            foreach ($r in $wingetResults | Where-Object { -not $_.Ok }) { $failed.Add("Install: $($r.Name) ($($r.Code))") }
        }
    }

    # 2. Checklist
    $manual = @($sel | Where-Object { $_.Kind -eq 'checklist' })
    $checklist = $null
    if ($manual.Count) {
        $checklist = Join-Path $session.Dir 'Install-by-hand.txt'
        $lines = @("Install these by hand - winget can't install them.", "From $($pkg.Computer), restored $(Get-Date -Format 'yyyy-MM-dd HH:mm')", '')
        foreach ($m in $manual) {
            $extra = @($m.Data.Version, $m.Data.Publisher, $m.Data.Website) | Where-Object { $_ }
            $lines += "[ ] $($m.Name)" + $(if ($extra) { "   (" + ($extra -join ' | ') + ")" } else { '' })
            foreach ($n in $m.Notes) { $lines += "      - $n" }
        }
        $lines | Out-File $checklist -Encoding UTF8
    }

    # 3. Settings
    $settings = @($sel | Where-Object { $_.Group -in @('App settings', 'Registry settings') })
    if ($settings.Count) {
        Write-PMStep "Restoring $($settings.Count) settings item(s)"
        foreach ($it in $settings) {
            Write-PMInfo "  $($it.Name)"
            $ok = $false
            try { $ok = Invoke-PMSettingsItem $it $translations } catch { Write-PMWarn "    $($_.Exception.Message)" }
            if (-not $ok) { $failed.Add("Settings: $($it.Name)"); Write-PMWarn '    problem - see restore.log / copy.log' }
        }
    }

    # 4. Windows settings
    $win = @($sel | Where-Object { $_.Group -eq 'Windows settings' })
    if ($win.Count) {
        Write-PMStep "Applying $($win.Count) Windows setting(s)"
        foreach ($it in $win) {
            Write-PMInfo "  $($it.Name)"
            $ok = $false
            try { $ok = Invoke-PMWindowsItem $it $pkg ([ref]$flags) } catch { Write-PMWarn "    $($_.Exception.Message)" }
            if (-not $ok) { $failed.Add("Windows: $($it.Name)") }
        }
    }

    # 5. Drive maps
    foreach ($it in @($sel | Where-Object { $_.Kind -eq 'drivemap' })) {
        Write-PMStep $it.Name
        $ok = $false
        try { $ok = Invoke-PMDriveMap $it } catch { Write-PMWarn "  $($_.Exception.Message)" }
        if ($ok) { $flags.Reboot = $true; Write-PMOk "  Done - drive $($it.Data.Letter): appears after a restart." }
        else { $failed.Add($it.Name) }
    }

    if ($flags.Explorer) {
        Write-PMInfo 'Restarting File Explorer...'
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        # Windows restarts the shell itself; starting it from here would run it as administrator
        for ($i = 0; $i -lt 30 -and -not (Get-Process explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Write-PMWarn 'File Explorer did not restart by itself - sign out and back in.' }
    }

    return [pscustomobject]@{
        Session   = $session.Dir
        Selected  = $sel.Count
        Failed    = @($failed)
        Winget    = $wingetResults
        Checklist = $checklist
        Reboot    = $flags.Reboot
    }
}
