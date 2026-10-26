#Requires -Version 5.1
<#
.SYNOPSIS
  PCMigrate - Capture. Run on the OLD PC.
.DESCRIPTION
  Creates a migration package: a hardware/OS profile of this PC, every installed
  program, a winget reinstall list, app settings (AppData + per-vendor registry),
  Windows preferences, startup items, scheduled tasks, fonts and personal config
  files. Nothing is changed on this PC.
  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
.PARAMETER PackageRoot
  Folder to create the package in. Default: PCMigrate.ini [Paths] PackageRoot,
  or the folder that contains the PCMigrate folder.
.PARAMETER Unattended
  No prompts.
#>
param(
    [string]$ConfigPath,
    [string]$PackageRoot,
    [switch]$Unattended
)

$ErrorActionPreference = 'Continue'
$toolRoot = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\SystemInfo.ps1"
$Host.UI.RawUI.WindowTitle = "PCMigrate $script:PMVersion - Capture"
trap { Write-PMError "Unexpected error: $_"; Write-PMLog ($_ | Out-String); if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }
if (-not (Assert-PMWindows 'Capture')) { if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }

if (-not $ConfigPath) { $ConfigPath = Join-Path $toolRoot 'PCMigrate.ini' }
$ini = Read-PMIni $ConfigPath
if (-not $PackageRoot) { $PackageRoot = Get-PMSetting $ini 'Paths' 'PackageRoot' '' }
if (-not $PackageRoot) { $PackageRoot = Split-Path $toolRoot -Parent }

Write-Host ''
Write-Host "PCMigrate $script:PMVersion - capturing $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "Packages go to: $PackageRoot"
Write-Host ''
if (-not $Unattended) {
    Write-Host 'Close the programs whose settings you want (browsers, editors, mail, etc.)' -ForegroundColor Yellow
    Write-Host 'so their files are not locked or half-written. Nothing on this PC is changed.' -ForegroundColor Yellow
    Read-Host 'Press Enter to start'
}

# The package folder is created only now, so nothing half-made sits around while the window waits.
$pkg    = Join-Path $PackageRoot ("{0}_{1}" -f $env:COMPUTERNAME, (New-PMStamp))
$sys    = Join-Path $pkg 'system'
$logDir = Join-Path $pkg 'logs'
try { New-Item -ItemType Directory -Path $sys, $logDir -Force -ErrorAction Stop | Out-Null }
catch { Write-PMError "Cannot create the package folder $pkg : $($_.Exception.Message)"; if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }
Start-PMLog (Join-Path $logDir 'capture.log')
Write-PMInfo "Package: $pkg"

# ----------------------------- 1. System profile ------------------------------
Write-PMStep '1/9  Hardware and system profile'
$prof = Get-PMSystemProfile
Save-PMJson $prof (Join-Path $sys 'profile.json')
Write-PMInfo (Format-PMProfileSummary $prof)
Write-PMInfo ("{0} devices, {1} printers, {2} drives recorded" -f @($prof.Devices).Count, @($prof.Printers).Count, @($prof.Drives).Count)

# ----------------------------- 2. Programs ------------------------------------
Write-PMStep '2/9  Installed programs'
$programs = Get-PMInstalledPrograms
$programs | Export-Csv (Join-Path $pkg 'AllPrograms.csv') -NoTypeInformation -Encoding UTF8
Get-PMStoreApps | Export-Csv (Join-Path $pkg 'StoreApps.csv') -NoTypeInformation -Encoding UTF8
$byName = @{}; foreach ($p in $programs) { $byName[$p.Name] = $p }
Write-PMInfo "$(@($programs).Count) programs listed"

# ----------------------------- 3. winget --------------------------------------
Write-PMStep '3/9  winget reinstall list'
$jsonPath = Join-Path $pkg 'winget-apps.json'
$exportOut = @()
if (Get-Command winget -ErrorAction SilentlyContinue) {
    $exportOut = & winget export -o $jsonPath --accept-source-agreements --disable-interactivity 2>&1
    $exportOut | Out-File (Join-Path $logDir 'winget-export.log') -Encoding UTF8
    $j = Read-PMJson $jsonPath
    if ($j) {
        $count = ($j.Sources | ForEach-Object { @($_.Packages).Count } | Measure-Object -Sum).Sum
        Write-PMInfo "$count apps can be reinstalled automatically"
    } else { Write-PMWarn 'winget export produced no file - see logs\winget-export.log' }
} else {
    Write-PMWarn 'winget is not installed - apps will be listed for manual install only.'
}

# Inventory with sources (tells us what winget can NOT reinstall)
$inv = @()
try {
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-PMInfo 'Installing the Microsoft.WinGet.Client PowerShell module (one time)...'
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    $inv = @(Get-WinGetPackage | Select-Object Name, Id, InstalledVersion, Source)
} catch {
    Write-PMWarn "WinGet PowerShell module unavailable ($($_.Exception.Message)) - using winget export warnings."
}
$inv | Export-Csv (Join-Path $pkg 'WingetInventory.csv') -NoTypeInformation -Encoding UTF8

# ----------------------------- 4. Manual-install list -------------------------
Write-PMStep '4/9  Apps winget cannot reinstall'
if ($inv.Count) {
    $manualNames = $inv | Where-Object { -not $_.Source -and $_.Id -notlike 'MSIX\*' } | ForEach-Object { "$($_.Name)".Trim() }
} else {
    $manualNames = $exportOut | ForEach-Object { if ("$_" -match 'not available from any source:\s*(.+)$') { $Matches[1].Trim() } }
}
$ignore = Get-PMList $ini 'ManualIgnore'
$manual = @()
foreach ($n in ($manualNames | Sort-Object -Unique)) {
    if (Test-PMLike $n $ignore) { continue }
    $info = $byName[$n]
    $manual += [pscustomobject]@{ Name = $n; Version = $info.Version; Publisher = $info.Publisher; Website = $info.Website }
}
$manual | Export-Csv (Join-Path $pkg 'ManualInstall.csv') -NoTypeInformation -Encoding UTF8
Write-PMInfo "$($manual.Count) apps need a manual install (the new PC decides which are relevant)"

# ----------------------------- 5. AppData -------------------------------------
Write-PMStep '5/9  App settings (AppData)'
$skipNames = Get-PMList $ini 'SkipFolderNames'
$roamExcl  = @(Get-PMList $ini 'RoamingExclude' | ForEach-Object { Join-Path $env:APPDATA $_ })
$roamDst   = Join-Path $pkg 'AppData\Roaming'
Write-PMInfo 'Copying %APPDATA% ...'
$ok = Invoke-PMRobocopy $env:APPDATA $roamDst (@('/MT:8', '/XD') + $roamExcl + $skipNames) (Join-Path $logDir 'roaming.log')
if (-not $ok) { Write-PMWarn '  Some files could not be copied (usually files locked by a running app) - see logs\roaming.log' }
Write-PMInfo "  Roaming: $(Get-PMFolderSizeMB $roamDst) MB"
foreach ($rel in (Get-PMList $ini 'LocalAppData')) {
    $src = Join-Path $env:LOCALAPPDATA $rel
    if (-not (Test-Path -LiteralPath $src)) { Write-PMInfo "  (not found) Local\$rel"; continue }
    [void](Invoke-PMRobocopy $src (Join-Path $pkg "AppData\Local\$rel") (@('/MT:8', '/XD') + $skipNames) (Join-Path $logDir 'local.log'))
    Write-PMInfo "  Local\$rel"
}

# ----------------------------- 6. Registry ------------------------------------
Write-PMStep '6/9  Registry settings (HKCU\Software, one file per vendor)'
$regDir = Join-Path $pkg 'Registry'
New-Item -ItemType Directory -Path $regDir -Force | Out-Null
$regSkip = Get-PMList $ini 'RegistrySkip'
$n = 0
foreach ($k in Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue) {
    $name = $k.PSChildName
    if ($regSkip -contains $name) { continue }
    $file = Join-Path $regDir (($name -replace '[\\/:*?"<>|]', '_') + '.reg')
    & reg.exe export "HKCU\Software\$name" $file /y 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $n++ }
}
Write-PMInfo "$n vendor keys exported"

# ----------------------------- 7. Windows settings ----------------------------
Write-PMStep '7/9  Windows preferences, startup items, tasks'
$regExports = @(
    @('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'explorer.reg'),
    @('HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'personalize.reg'),
    @('HKCU\Control Panel\Mouse', 'mouse.reg'),
    @('HKCU\Control Panel\Keyboard', 'keyboard.reg')
)
foreach ($r in $regExports) { & reg.exe export $r[0] (Join-Path $sys $r[1]) /y 2>&1 | Out-Null }
Save-PMJson $prof.KnownFolders (Join-Path $sys 'knownfolders.json')

# User environment variables (unexpanded)
$envOut = [ordered]@{}
$envKey = Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue
if ($envKey) {
    foreach ($v in $envKey.GetValueNames()) {
        $envOut[$v] = $envKey.GetValue($v, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}
Save-PMJson $envOut (Join-Path $sys 'env-user.json')

# Startup items
function Get-PMExeFromCommand([string]$cmd) {
    if (-not $cmd) { return '' }
    $c = $cmd.Trim()
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -lt 0) { return $c.Trim('"') }; return $c.Substring(1, $end - 1) }
    $m = [regex]::Match($c, '^(.+?\.(exe|cmd|bat|com|vbs|ps1|lnk|ahk))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    # unquoted path with spaces: grow word by word until it names an existing file
    $parts = $c -split ' '
    for ($n = $parts.Count; $n -ge 1; $n--) {
        $try = ($parts[0..($n - 1)] -join ' ')
        if (Test-Path -LiteralPath $try -PathType Leaf) { return $try }
    }
    return $parts[0]
}
$startup = @()
foreach ($p in (Get-PMRegValues 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')) {
    $cmd = [Environment]::ExpandEnvironmentVariables("$($p.Value)")
    $startup += [pscustomobject]@{ Type = 'Run'; Name = $p.Name; Command = "$($p.Value)"; Exe = (ConvertTo-PMPortablePath (Get-PMExeFromCommand $cmd)); File = '' }
}
$startupDir = [Environment]::GetFolderPath('Startup')
if (Test-Path -LiteralPath $startupDir) {
    $shell = New-Object -ComObject WScript.Shell
    New-Item -ItemType Directory -Path (Join-Path $sys 'startup') -Force | Out-Null
    foreach ($l in Get-ChildItem -LiteralPath $startupDir -File -Force | Where-Object { $_.Extension -in '.lnk', '.url', '.ahk', '.bat', '.cmd', '.vbs' }) {
        $exe = ''
        if ($l.Extension -eq '.lnk') { try { $exe = $shell.CreateShortcut($l.FullName).TargetPath } catch { } }
        else { $exe = $l.FullName }
        Copy-Item -LiteralPath $l.FullName -Destination (Join-Path $sys 'startup') -Force
        $startup += [pscustomobject]@{ Type = 'Folder'; Name = $l.BaseName; Command = $exe; Exe = (ConvertTo-PMPortablePath $exe); File = $l.Name }
    }
}
Save-PMJson @($startup) (Join-Path $sys 'startup.json')
Write-PMInfo "$($startup.Count) startup items"

# Scheduled tasks (yours, not Windows' own or app updaters)
$taskSkip = Get-PMList $ini 'TaskSkip'
$tasks = @()
New-Item -ItemType Directory -Path (Join-Path $sys 'tasks') -Force | Out-Null
try {
    foreach ($t in Get-ScheduledTask -ErrorAction Stop) {
        if ($t.TaskPath -like '\Microsoft\*') { continue }
        if ((Test-PMLike $t.TaskName $taskSkip) -or (Test-PMLike ($t.TaskPath + $t.TaskName) $taskSkip)) { continue }
        $act = @($t.Actions | Where-Object { $_.Execute }) | Select-Object -First 1
        $file = (($t.TaskPath.Trim('\') + '_' + $t.TaskName) -replace '[\\/:*?"<>|]', '_').Trim('_') + '.xml'
        try {
            Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-File (Join-Path $sys "tasks\$file") -Encoding Unicode
        } catch { continue }
        $tasks += [pscustomobject]@{
            Name     = $t.TaskName
            Path     = $t.TaskPath
            File     = $file
            Exe      = if ($act) { ConvertTo-PMPortablePath ([Environment]::ExpandEnvironmentVariables("$($act.Execute)".Trim('"'))) } else { '' }
            Args     = if ($act) { "$($act.Arguments)" } else { '' }
            Password = ("$($t.Principal.LogonType)" -eq 'Password')
        }
    }
} catch { Write-PMWarn "Could not read scheduled tasks: $($_.Exception.Message)" }
Save-PMJson @($tasks) (Join-Path $sys 'tasks.json')
Write-PMInfo "$($tasks.Count) scheduled tasks"

# Mapped network drives
$net = @()
foreach ($k in Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue) {
    $v = Get-ItemProperty $k.PSPath
    $net += [pscustomobject]@{ Letter = $k.PSChildName.ToUpperInvariant(); Remote = $v.RemotePath }
}
Save-PMJson @($net) (Join-Path $sys 'netdrives.json')

# Hosts file (only if it has entries)
$hostsFile = "$env:WINDIR\System32\drivers\etc\hosts"
if (Test-Path -LiteralPath $hostsFile) {
    $lines = @(Get-Content -LiteralPath $hostsFile | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    if ($lines.Count) { $lines | Out-File (Join-Path $sys 'hosts.txt') -Encoding UTF8 }
}

# Wi-Fi (opt-in: passwords are stored in plain text)
if (Get-PMSetting $ini 'Capture' 'IncludeWifi' $false) {
    $wifi = Join-Path $sys 'wifi'
    New-Item -ItemType Directory -Path $wifi -Force | Out-Null
    & netsh wlan export profile key=clear folder="$wifi" 2>&1 | Out-Null
    Write-PMWarn "Wi-Fi profiles exported WITH passwords to $wifi - keep this package private."
}

# ----------------------------- 8. Fonts and personal files --------------------
Write-PMStep '8/9  Fonts and personal config files'
$fontDir = Join-Path $pkg 'Fonts'
New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
$fonts = @()
$userFonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$ufReg = @(Get-PMRegValues 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts')
if ($ufReg.Count) {
    foreach ($p in $ufReg) {
        $f = "$($p.Value)"; if (-not [IO.Path]::IsPathRooted($f)) { $f = Join-Path $userFonts $f }
        if (Test-Path -LiteralPath $f) {
            Copy-Item -LiteralPath $f -Destination $fontDir -Force
            $fonts += [pscustomobject]@{ File = (Split-Path $f -Leaf); Name = $p.Name; Scope = 'User' }
        }
    }
}
# Machine fonts added after Windows was installed (skips the fonts Windows ships with)
$osDate = $null; if ($prof.OSInstalled) { $osDate = ([datetime]$prof.OSInstalled).AddHours(2) }
$mfReg = @(Get-PMRegValues 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')
if ($mfReg.Count -and $osDate) {
    foreach ($p in $mfReg) {
        $f = "$($p.Value)"; if (-not [IO.Path]::IsPathRooted($f)) { $f = Join-Path "$env:WINDIR\Fonts" $f }
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $fi = Get-Item -LiteralPath $f
        $owner = ''; try { $owner = (Get-Acl -LiteralPath $f).Owner } catch { }
        if ($owner -match 'TrustedInstaller') { continue }   # shipped with Windows (updates can re-stamp their dates)
        if ($fi.CreationTime -gt $osDate -and -not ($fonts | Where-Object { $_.File -eq $fi.Name })) {
            Copy-Item -LiteralPath $f -Destination $fontDir -Force
            $fonts += [pscustomobject]@{ File = $fi.Name; Name = $p.Name; Scope = 'Machine' }
        }
    }
}
$fonts | Export-Csv (Join-Path $fontDir 'fonts.csv') -NoTypeInformation -Encoding UTF8
Write-PMInfo "$($fonts.Count) added fonts"

# Personal config files - skipped when they already live in Dropbox/OneDrive
$docs = [Environment]::GetFolderPath('MyDocuments')
$candidates = @(
    @{ Name = 'Git config (.gitconfig)';            Path = "$env:USERPROFILE\.gitconfig";  NeedsParent = $false },
    @{ Name = 'WSL config (.wslconfig)';            Path = "$env:USERPROFILE\.wslconfig";  NeedsParent = $false },
    @{ Name = 'Windows PowerShell profile';         Path = "$docs\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"; NeedsParent = $false },
    @{ Name = 'PowerShell 7 profile';               Path = "$docs\PowerShell\Microsoft.PowerShell_profile.ps1";        NeedsParent = $false },
    @{ Name = 'Windows Terminal settings';          Path = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"; NeedsParent = $true }
)
if (Get-PMSetting $ini 'Capture' 'IncludeSsh' $false) {
    $candidates += @{ Name = 'SSH config and keys (.ssh)'; Path = "$env:USERPROFILE\.ssh"; NeedsParent = $false }
}
$synced = @($prof.Dropbox, $prof.OneDrive) | Where-Object { $_ }
$filesDir = Join-Path $pkg 'files'
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
$files = @(); $i = 0
foreach ($c in $candidates) {
    if (-not (Test-Path -LiteralPath $c.Path)) { continue }
    $isSynced = $false
    foreach ($s in $synced) { if ($c.Path.StartsWith($s, [StringComparison]::OrdinalIgnoreCase)) { $isSynced = $true } }
    if ($isSynced) { Write-PMInfo "  $($c.Name): already in a synced folder - skipped"; continue }
    $i++
    $stored = "{0:00}_{1}" -f $i, (Split-Path $c.Path -Leaf)
    Copy-Item -LiteralPath $c.Path -Destination (Join-Path $filesDir $stored) -Recurse -Force
    $files += [pscustomobject]@{ Name = $c.Name; Origin = (ConvertTo-PMPortablePath $c.Path); Stored = $stored; NeedsParent = $c.NeedsParent }
    Write-PMInfo "  $($c.Name)"
}
Save-PMJson @($files) (Join-Path $filesDir 'files.json')

# ----------------------------- 9. Manifest ------------------------------------
Write-PMStep '9/9  Finishing'
$size = Get-PMFolderSizeMB $pkg
Save-PMJson ([ordered]@{
    Tool        = 'PCMigrate'
    Version     = $script:PMVersion
    Schema      = $script:PMSchema
    Created     = (Get-Date).ToString('s')
    Computer    = $env:COMPUTERNAME
    User        = $env:USERNAME
    SizeMB      = $size
    Programs    = @($programs).Count
    ManualApps  = $manual.Count
    Startup     = $startup.Count
    Tasks       = $tasks.Count
    Fonts       = $fonts.Count
    WifiIncluded = [bool](Get-PMSetting $ini 'Capture' 'IncludeWifi' $false)
}) (Join-Path $pkg 'manifest.json')

Write-PMOk "Capture finished: $pkg ($size MB)"
Write-Host ''
Write-Host 'Next: when the package has synced (or is copied) to the new PC, run' -ForegroundColor Green
Write-Host '"2. Restore onto this PC" there. The new PC decides what fits its hardware.' -ForegroundColor Green
if (-not $Unattended) {
    Invoke-Item $pkg
    Read-Host 'Press Enter to close'
}
