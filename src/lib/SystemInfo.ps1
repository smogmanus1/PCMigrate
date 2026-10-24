# ==============================================================================
# PCMigrate - SystemInfo.ps1
# Builds a profile of a PC: hardware, OS, drives, user folders, sync folders,
# printers, devices and installed software. The same profile is captured on the
# old PC and built live on the new PC so the two can be compared.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

function Get-PMCim([string]$class, [string]$filter) {
    try {
        if ($filter) { return @(Get-CimInstance -ClassName $class -Filter $filter -ErrorAction Stop) }
        return @(Get-CimInstance -ClassName $class -ErrorAction Stop)
    } catch { return @() }
}

function Get-PMChassis {
    $types = @()
    foreach ($e in (Get-PMCim 'Win32_SystemEnclosure')) { $types += @($e.ChassisTypes) }
    $battery = (Get-PMCim 'Win32_Battery').Count -gt 0
    $laptop  = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktop = @(3, 4, 5, 6, 7, 13, 15, 16, 24, 35, 36)
    if ($types | Where-Object { $laptop -contains $_ })  { return 'laptop' }
    if ($types | Where-Object { $desktop -contains $_ }) { if ($battery) { return 'laptop' } else { return 'desktop' } }
    if ($battery) { return 'laptop' }
    return 'unknown'
}

function Get-PMDropboxPath {
    foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if (-not $base) { continue }
        $info = Join-Path $base 'Dropbox\info.json'
        if (Test-Path -LiteralPath $info) {
            try {
                $j = Read-PMJson $info
                if ($j.personal.path) { return $j.personal.path }
                if ($j.business.path) { return $j.business.path }
            } catch { }
        }
    }
    return $null
}

function Get-PMKnownFolders {
    $out = [ordered]@{}
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $names = [ordered]@{
        'Desktop'   = 'Desktop'
        'Documents' = 'Personal'
        'Downloads' = '{374DE290-123F-4565-9164-39C4925E467B}'
        'Music'     = 'My Music'
        'Pictures'  = 'My Pictures'
        'Videos'    = 'My Video'
        'Favorites' = 'Favorites'
    }
    $vals = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    foreach ($n in $names.Keys) {
        $raw = $null
        if ($vals) { $raw = $vals.($names[$n]) }
        if ($raw) {
            $out[$n] = [ordered]@{
                ValueName = $names[$n]
                Raw       = $raw
                Expanded  = [Environment]::ExpandEnvironmentVariables($raw)
            }
        }
    }
    return $out
}

function Get-PMDevices {
    # Compact "Manufacturer | Name | VID_xxxx" lines for every present PnP device.
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($d in (Get-PMCim 'Win32_PnPEntity')) {
        if (-not $d.Name) { continue }
        $vid = ''
        foreach ($h in @($d.HardwareID)) {
            if ("$h" -match '(VID_[0-9A-F]{4}|VEN_[0-9A-F]{4})') { $vid = $Matches[1]; break }
        }
        $line = ('{0} | {1} | {2}' -f $d.Manufacturer, $d.Name, $vid).Trim()
        if (-not $lines.Contains($line)) { $lines.Add($line) }
    }
    return @($lines | Sort-Object)
}

function Get-PMInstalledPrograms {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName -and -not $_.ReleaseType } |
        Select-Object @{n='Name';    e={ $_.DisplayName.Trim() }},
                      @{n='Version'; e={ $_.DisplayVersion }},
                      Publisher, InstallDate, InstallLocation,
                      @{n='Website'; e={ if ($_.URLInfoAbout) { $_.URLInfoAbout } else { $_.HelpLink } }} |
        Sort-Object Name -Unique)
}

function Get-PMStoreApps {
    try {
        return @(Get-AppxPackage -ErrorAction Stop |
            Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
            Select-Object @{n='Name'; e={ $_.Name }}, @{n='Publisher'; e={ $_.Publisher }}, Version, PackageFamilyName)
    } catch { return @() }
}

# IDs of everything winget can see as installed. Uses the WinGet PowerShell module
# when present, otherwise "winget export" to a temp file.
function Get-PMWingetInstalled {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $done = $false
    if (Get-Module -ListAvailable -Name Microsoft.WinGet.Client) {
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            foreach ($p in Get-WinGetPackage) { if ($p.Id) { [void]$ids.Add($p.Id) } }
            $done = $true
        } catch { }
    }
    if (-not $done -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $tmp = Join-Path $env:TEMP ("pm_winget_{0}.json" -f [guid]::NewGuid().ToString('N'))
        & winget export -o $tmp --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
        $j = Read-PMJson $tmp
        if ($j) { foreach ($s in $j.Sources) { foreach ($p in $s.Packages) { [void]$ids.Add($p.PackageIdentifier) } } }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return ,$ids   # comma keeps the HashSet intact (no unrolling)
}

function Get-PMSystemProfile([switch]$Quick) {
    $cs   = Get-PMCim 'Win32_ComputerSystem' | Select-Object -First 1
    $os   = Get-PMCim 'Win32_OperatingSystem' | Select-Object -First 1
    $bb   = Get-PMCim 'Win32_BaseBoard' | Select-Object -First 1
    $cpus = Get-PMCim 'Win32_Processor'
    $gpus = Get-PMCim 'Win32_VideoController' | Where-Object { $_.Name -and $_.Name -notmatch 'Basic Display|Remote Display|Virtual|Mirage|Parsec|Meta Virtual' }

    $drives = @()
    foreach ($d in (Get-PMCim 'Win32_LogicalDisk')) {
        $drives += [pscustomobject]@{
            Letter = $d.DeviceID
            Type   = switch ([int]$d.DriveType) { 2 {'Removable'} 3 {'Fixed'} 4 {'Network'} 5 {'CD'} 6 {'RAM'} default {'Other'} }
            Label  = $d.VolumeName
            SizeGB = if ($d.Size) { [math]::Round($d.Size / 1GB, 0) } else { 0 }
            Network = $d.ProviderName
        }
    }
    $printers = @()
    foreach ($p in (Get-PMCim 'Win32_Printer')) {
        if ($p.Name -match '^(Microsoft Print to PDF|Microsoft XPS|Fax|OneNote|Send To OneNote|Adobe PDF)') { continue }
        $printers += [pscustomobject]@{ Name = $p.Name; Driver = $p.DriverName; Port = $p.PortName }
    }

    $installDate = $null
    if ($os -and $os.InstallDate) { $installDate = ([datetime]$os.InstallDate).ToString('s') }

    $prof = [ordered]@{
        Schema       = $script:PMSchema
        Tool         = "PCMigrate $script:PMVersion"
        Captured     = (Get-Date).ToString('s')
        ComputerName = $env:COMPUTERNAME
        UserName     = $env:USERNAME
        UserProfile  = $env:USERPROFILE
        Manufacturer = if ($cs) { "$($cs.Manufacturer)".Trim() } else { '' }
        Model        = if ($cs) { "$($cs.Model)".Trim() } else { '' }
        Board        = if ($bb) { ("$($bb.Manufacturer) $($bb.Product)").Trim() } else { '' }
        Chassis      = Get-PMChassis
        Cpu          = @($cpus | ForEach-Object { "$($_.Name)".Trim() })
        CpuVendor    = (@($cpus | ForEach-Object { switch -Regex ("$($_.Manufacturer)") { 'AMD' {'AMD'} 'Intel' {'Intel'} 'Qualcomm|ARM' {'ARM'} default { "$($_.Manufacturer)" } } }) | Select-Object -First 1)
        Gpu          = @($gpus | ForEach-Object { "$($_.Name)".Trim() })
        Arch         = $env:PROCESSOR_ARCHITECTURE
        RamGB        = if ($cs -and $cs.TotalPhysicalMemory) { [math]::Round($cs.TotalPhysicalMemory / 1GB, 0) } else { 0 }
        OS           = if ($os) { "$($os.Caption)".Trim() } else { '' }
        OSBuild      = if ($os) { "$($os.BuildNumber)" } else { '' }
        OSInstalled  = $installDate
        Drives       = $drives
        Dropbox      = Get-PMDropboxPath
        OneDrive     = $env:OneDrive
        KnownFolders = Get-PMKnownFolders
        Printers     = $printers
        Devices      = @()
    }
    if (-not $Quick) { $prof.Devices = Get-PMDevices }
    return [pscustomobject]$prof
}

# One-line description used in headers: "HP ZBook Fury 17 G7 (laptop) - Intel Core i7 - NVIDIA Quadro"
function Format-PMProfileSummary($p) {
    if (-not $p) { return 'unknown (older package - no hardware profile)' }
    $gpu = (@($p.Gpu) | Select-Object -First 2) -join ' + '
    $cpu = (@($p.Cpu) | Select-Object -First 1) -replace '\s+', ' ' -replace '\(R\)|\(TM\)|CPU|Processor', '' -replace '\s+', ' '
    return ('{0} {1} ({2}) - {3} - {4}' -f $p.Manufacturer, $p.Model, $p.Chassis, $cpu.Trim(), $gpu).Trim()
}

# Lists what differs between two profiles, as short human-readable lines.
function Compare-PMProfiles($src, $dst) {
    $out = @()
    if (-not $src) { return @('Source hardware unknown (package made by an older version) - rules use this PC only.') }
    if ($src.CpuVendor -ne $dst.CpuVendor) { $out += "CPU: $($src.CpuVendor) -> $($dst.CpuVendor)" }
    $vend = { param($list) $v = @(); foreach ($g in @($list)) { if ($g -match 'NVIDIA') { $v += 'NVIDIA' } elseif ($g -match 'AMD|Radeon') { $v += 'AMD' } elseif ($g -match 'Intel') { $v += 'Intel' } }; ($v | Sort-Object -Unique) -join '+' }
    $a = & $vend $src.Gpu; $b = & $vend $dst.Gpu
    if ($a -ne $b) { $out += "Graphics: $a -> $b" }
    if ($src.Manufacturer -ne $dst.Manufacturer) { $out += "Maker: $($src.Manufacturer) -> $($dst.Manufacturer)" }
    if ($src.Chassis -ne $dst.Chassis) { $out += "Type: $($src.Chassis) -> $($dst.Chassis)" }
    if ($src.Arch -ne $dst.Arch) { $out += "Architecture: $($src.Arch) -> $($dst.Arch)" }
    if ($src.UserName -ne $dst.UserName) { $out += "User: $($src.UserName) -> $($dst.UserName)" }
    $sl = @($src.Drives | Where-Object { $_.Type -eq 'Fixed' } | ForEach-Object { $_.Letter }) -join ' '
    $dl = @($dst.Drives | Where-Object { $_.Type -eq 'Fixed' } | ForEach-Object { $_.Letter }) -join ' '
    if ($sl -ne $dl) { $out += "Drives: $sl -> $dl" }
    if ($src.Dropbox -and $dst.Dropbox -and $src.Dropbox -ne $dst.Dropbox) { $out += "Dropbox: $($src.Dropbox) -> $($dst.Dropbox)" }
    if (-not $out) { $out += 'No significant hardware differences.' }
    return $out
}
