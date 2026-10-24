# ==============================================================================
# PCMigrate - Common.ps1
# Shared helpers: settings (INI), JSON, logging, text-file handling, misc.
# Part of PCMigrate - https://github.com/smogmanus1/PCMigrate
# Authors: Brad Schrunk (concept, design direction, testing)
#          Claude by Anthropic (architecture and code)
# License: MIT
# Windows PowerShell 5.1 compatible - keep this file ASCII only.
# ==============================================================================

$script:PMVersion = '1.0.3'
$script:PMSchema  = 2

# ----------------------------- Console output ---------------------------------
function Write-PMStep([string]$msg) {
    Write-Host ''
    Write-Host "===== $msg =====" -ForegroundColor Cyan
    Write-PMLog "STEP $msg"
}
function Write-PMInfo([string]$msg)  { Write-Host $msg;                              Write-PMLog "INFO $msg" }
function Write-PMOk([string]$msg)    { Write-Host $msg -ForegroundColor Green;       Write-PMLog "OK   $msg" }
function Write-PMWarn([string]$msg)  { Write-Host $msg -ForegroundColor Yellow;      Write-PMLog "WARN $msg" }
function Write-PMError([string]$msg) { Write-Host $msg -ForegroundColor Red;         Write-PMLog "ERR  $msg" }

$script:PMLogFile = $null
function Start-PMLog([string]$path) {
    $dir = Split-Path $path -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:PMLogFile = $path
    Write-PMLog "PCMigrate $script:PMVersion log started on $env:COMPUTERNAME as $env:USERNAME"
}
function Write-PMLog([string]$msg) {
    if (-not $script:PMLogFile) { return }
    try {
        Add-Content -LiteralPath $script:PMLogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Folder gone (deleted or moved while running)? Warn once and stop logging instead of flooding the screen.
        $f = $script:PMLogFile; $script:PMLogFile = $null
        Write-Host "Log file can no longer be written ($f) - was the folder deleted? Logging stopped." -ForegroundColor Yellow
    }
}

# ----------------------------- Settings (INI) ---------------------------------
# Sections hold either key=value pairs or plain list lines; both are kept.
function Read-PMIni([string]$Path) {
    $ini = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $ini }
    $section = '_'
    $ini[$section] = @{ Keys = @{}; List = New-Object System.Collections.Generic.List[string] }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $ini.ContainsKey($section)) {
                $ini[$section] = @{ Keys = @{}; List = New-Object System.Collections.Generic.List[string] }
            }
            continue
        }
        $val = [Environment]::ExpandEnvironmentVariables($t)
        $ini[$section].List.Add($val)
        $eq = $t.IndexOf('=')
        if ($eq -gt 0) {
            $k = $t.Substring(0, $eq).Trim()
            $v = [Environment]::ExpandEnvironmentVariables($t.Substring($eq + 1).Trim())
            $ini[$section].Keys[$k] = $v
        }
    }
    return $ini
}
function Get-PMSetting($ini, [string]$section, [string]$key, $default) {
    if ($ini.ContainsKey($section) -and $ini[$section].Keys.ContainsKey($key)) {
        $v = $ini[$section].Keys[$key]
        if ($default -is [bool]) { return ($v -match '^(1|true|yes|on)$') }
        if ($default -is [int])  { $n = 0; if ([int]::TryParse($v, [ref]$n)) { return $n } else { return $default } }
        return $v
    }
    return $default
}
function Get-PMList($ini, [string]$section) {
    if ($ini.ContainsKey($section)) { return @($ini[$section].List) }
    return @()
}
# Key=Value pairs of a section, as an ordered list of objects (keeps duplicates out).
function Get-PMPairs($ini, [string]$section) {
    $out = @()
    if ($ini.ContainsKey($section)) {
        foreach ($k in $ini[$section].Keys.Keys) { $out += [pscustomobject]@{ Key = $k; Value = $ini[$section].Keys[$k] } }
    }
    return $out
}

# ----------------------------- JSON -------------------------------------------
function Resolve-PMFullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}
function Save-PMJson($obj, [string]$Path, [int]$Depth = 8) {
    $Path = Resolve-PMFullPath $Path
    $dir = Split-Path $Path -Parent
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $obj -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}
function Read-PMJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $Path = Resolve-PMFullPath $Path
    $raw = [IO.File]::ReadAllText($Path)
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if (-not $raw.Trim()) { return $null }
    return (ConvertFrom-Json -InputObject $raw)
}
# CSV read that tolerates a missing file.
function Read-PMCsv([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Import-Csv -LiteralPath $Path)
}

# ----------------------------- Wildcards / names ------------------------------
function Test-PMLike([string]$text, $patterns) {
    if (-not $text) { return $false }
    foreach ($p in @($patterns)) { if ($p -and $text -like $p) { return $true } }
    return $false
}
# Lowercase alphanumerics only, minus common company suffixes. Used for fuzzy matching.
function ConvertTo-PMKey([string]$s) {
    if (-not $s) { return '' }
    $t = $s.ToLowerInvariant()
    $t = $t -replace '\(.*?\)', ' '
    $t = $t -replace '\b(inc|ltd|llc|gmbh|corp|corporation|co|company|software|technologies|technology|systems|limited|sp|e\.?v|s\.?a|ag|bv|pty|projects|development|computer)\b\.?', ' '
    $t = $t -replace '\bv?\d+(\.\d+)+\b', ' '
    $t = $t -replace '\b(x64|x86|64-bit|32-bit|64bit|32bit|en-us)\b', ' '
    $t = $t -replace '[^a-z0-9]', ''
    return $t
}

# ----------------------------- Files ------------------------------------------
function Get-PMFolderSizeMB([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $item = Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer) { return [math]::Round($item.Length / 1MB, 2) }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    return [math]::Round($sum / 1MB, 2)
}

# Detects how a text file is encoded. Returns $null for binary files.
function Get-PMTextEncoding([byte[]]$bytes) {
    $n = $bytes.Length
    if ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return 'utf8bom' }
    if ($n -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return 'utf16le' }
    if ($n -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return 'utf16be' }
    $sample = [math]::Min($n, 4096)
    if ($sample -eq 0) { return 'utf8' }
    $zeroEven = 0; $zeroOdd = 0; $ctrl = 0
    for ($i = 0; $i -lt $sample; $i++) {
        $b = $bytes[$i]
        if ($b -eq 0) { if ($i % 2 -eq 0) { $zeroEven++ } else { $zeroOdd++ } }
        elseif ($b -lt 9 -or ($b -gt 13 -and $b -lt 32 -and $b -ne 27)) { $ctrl++ }
    }
    if ($zeroOdd -gt ($sample / 4) -and $zeroEven -lt ($sample / 50)) { return 'utf16le-nobom' }
    if (($zeroEven + $zeroOdd) -gt 0 -or $ctrl -gt ($sample / 20)) { return $null }
    # Valid UTF-8? Otherwise it is an ANSI (Windows-1252 etc.) file - keep it that way.
    try { [void](New-Object Text.UTF8Encoding $false, $true).GetString($bytes); return 'utf8' } catch { return 'ansi' }
}
function Read-PMText([byte[]]$bytes, [string]$enc) {
    switch ($enc) {
        'utf8bom'       { return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
        'utf16le'       { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
        'utf16le-nobom' { return [Text.Encoding]::Unicode.GetString($bytes) }
        'utf16be'       { return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
        'ansi'          { return [Text.Encoding]::GetEncoding(28591).GetString($bytes) }   # byte-exact round trip
        default         { return [Text.Encoding]::UTF8.GetString($bytes) }
    }
}
function Write-PMText([string]$path, [string]$text, [string]$enc) {
    switch ($enc) {
        'utf8bom'       { $e = New-Object Text.UTF8Encoding $true }
        'utf16le'       { $e = New-Object Text.UnicodeEncoding $false, $true }
        'utf16le-nobom' { $e = New-Object Text.UnicodeEncoding $false, $false }
        'utf16be'       { $e = New-Object Text.UnicodeEncoding $true, $true }
        'ansi'          { $e = [Text.Encoding]::GetEncoding(28591) }
        default         { $e = New-Object Text.UTF8Encoding $false }
    }
    [IO.File]::WriteAllText($path, $text, $e)
}

# Runs robocopy and returns $true when it succeeded (exit codes 0-7).
function Invoke-PMRobocopy([string]$src, [string]$dst, [string[]]$extra, [string]$log) {
    $rcArgs = @($src, $dst, '/E', '/FFT', '/XJ', '/R:1', '/W:1', '/NP', '/NFL', '/NDL') + @($extra | Where-Object { $_ })
    if ($log) { $rcArgs += "/LOG+:$log" }
    & robocopy @rcArgs | Out-Null
    return ($LASTEXITCODE -lt 8)
}

# ----------------------------- Elevation / user -------------------------------
function Test-PMAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# Name of the user who owns the desktop (explorer.exe). If an admin elevated with a
# DIFFERENT account, HKCU and AppData would belong to the wrong person.
function Get-PMDesktopUser {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$sid" -ErrorAction Stop | Select-Object -First 1
        if ($p) {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if ($o.User) { return $o.User }
        }
    } catch { }
    return $null
}

# Replaces environment-specific prefixes with tokens so paths travel between PCs.
function ConvertTo-PMPortablePath([string]$path) {
    if (-not $path) { return $path }
    $map = @(
        @('%LOCALAPPDATA%', $env:LOCALAPPDATA),
        @('%APPDATA%',      $env:APPDATA),
        @('%USERPROFILE%',  $env:USERPROFILE)
    )
    foreach ($m in $map) {
        if ($m[1] -and $path.StartsWith($m[1], [StringComparison]::OrdinalIgnoreCase)) {
            return $m[0] + $path.Substring($m[1].Length)
        }
    }
    return $path
}
function ConvertFrom-PMPortablePath([string]$path) {
    if (-not $path) { return $path }
    return [Environment]::ExpandEnvironmentVariables($path)
}

function New-PMStamp { return (Get-Date -Format 'yyyyMMdd_HHmm') }

# Name/value pairs of one registry key (without PowerShell's PS* helper properties).
function Get-PMRegValues([string]$path) {
    $out = @()
    $k = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $k) { return $out }
    foreach ($n in $k.GetValueNames()) {
        if ($n -eq '') { continue }
        $out += [pscustomobject]@{ Name = $n; Value = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    }
    return $out
}
