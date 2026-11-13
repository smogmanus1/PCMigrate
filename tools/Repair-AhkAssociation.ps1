#Requires -Version 5.1
<#
.SYNOPSIS
  Repairs double-clicking .ahk files ("This app can't run on your PC").
.DESCRIPTION
  1. Finds AutoHotkey v2 (AutoHotkey64.exe / AutoHotkey32.exe).
  2. Shows which program Windows currently uses for .ahk files, and what is
     wrong with it (missing file, empty file, wrong processor type...).
  3. Registers AutoHotkey v2 for .ahk files for the signed-in user and clears
     the broken "always use this app" choice, so Windows uses the fixed one.
  4. If Windows refuses to clear that choice, opens the "Open with" window so
     you can pick AutoHotkey64 and tick "Always".
  Changes only your own user settings (HKCU). No admin rights needed.
  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
#>
param([switch]$Unattended)

$ErrorActionPreference = 'Continue'
$toolRoot = Split-Path $PSScriptRoot -Parent
$Host.UI.RawUI.WindowTitle = 'PCMigrate - repair .ahk file association'
function Exit-Fix([int]$code = 0) { if (-not $Unattended) { Write-Host ''; Read-Host 'Press Enter to close' }; exit $code }
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# ----------------------------- 1. Find AutoHotkey v2 --------------------------
function Find-Ahk {
    $exe = 'AutoHotkey64.exe'
    if (-not [Environment]::Is64BitOperatingSystem) { $exe = 'AutoHotkey32.exe' }
    $dirs = @()
    foreach ($k in 'HKLM:\SOFTWARE\AutoHotkey', 'HKCU:\SOFTWARE\AutoHotkey') {
        try { $d = (Get-ItemProperty -LiteralPath $k -Name InstallDir -ErrorAction Stop).InstallDir; if ($d) { $dirs += $d } } catch { }
    }
    $dirs += (Join-Path $env:ProgramFiles 'AutoHotkey')
    $dirs += (Join-Path $env:LOCALAPPDATA 'Programs\AutoHotkey')
    foreach ($d in $dirs) {
        $p = Join-Path $d "v2\$exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# What kind of program file is this? (reads the Windows program header)
function Get-ExeProblem([string]$path) {
    if (-not $path) { return 'no program is set' }
    if (-not (Test-Path -LiteralPath $path)) { return "the program file does not exist: $path" }
    $f = Get-Item -LiteralPath $path
    if ($f.Length -lt 1024) { return "the program file is empty or damaged ($($f.Length) bytes): $path" }
    if ($f.Attributes -band 0x400000) { return "the program file is only in the cloud (not downloaded): $path" }
    try {
        $fs = [IO.File]::OpenRead($path)
        try {
            $b = New-Object byte[] 4096
            [void]$fs.Read($b, 0, $b.Length)
        } finally { $fs.Dispose() }
        if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return "the file is not a Windows program: $path" }
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        if ($pe -lt 0 -or $pe + 6 -gt $b.Length) { return $null }
        $machine = [BitConverter]::ToUInt16($b, $pe + 4)
        $osArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
        switch ($machine) {
            0x8664 { if (-not [Environment]::Is64BitOperatingSystem) { return "it is a 64-bit program on 32-bit Windows: $path" } }
            0xAA64 { if (-not $osArm) { return "it is an ARM program, but this PC has an Intel/AMD processor: $path" } }
            0x01C4 { if (-not $osArm) { return "it is an ARM program, but this PC has an Intel/AMD processor: $path" } }
        }
    } catch { return "the program file can't be read ($($_.Exception.Message)): $path" }
    return $null
}

function Get-Reg([string]$key, [string]$name) {
    try { return (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).$name } catch { return $null }
}

# Which ProgId and command does Explorer use for .ahk right now?
function Get-AhkHandler {
    $fe = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ahk'
    $progId = Get-Reg "$fe\UserChoiceLatest\ProgId" 'ProgId'
    $from = 'your "always use this app" choice'
    if (-not $progId) { $progId = Get-Reg "$fe\UserChoice" 'ProgId' }
    if (-not $progId) { $progId = Get-Reg 'HKCU:\Software\Classes\.ahk' '(default)'; $from = 'your user file types' }
    if (-not $progId) { $progId = Get-Reg 'HKLM:\Software\Classes\.ahk' '(default)'; $from = 'the PC-wide file types' }
    $cmd = $null
    if ($progId) {
        foreach ($root in 'HKCU:\Software\Classes', 'HKLM:\Software\Classes') {
            $c = Get-Reg "$root\$progId\shell\open\command" '(default)'
            if ($c) { $cmd = $c; break }
        }
    }
    $exe = $null
    if ($cmd) {
        if ($cmd -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($cmd -match '^\s*(.+?\.exe)') { $exe = $Matches[1] }
        if ($exe) { $exe = [Environment]::ExpandEnvironmentVariables($exe) }
    }
    return [pscustomobject]@{ ProgId = $progId; From = $from; Command = $cmd; Exe = $exe }
}

function Update-Shell {
    try {
        Add-Type -Namespace PM -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, int f, System.IntPtr a, System.IntPtr b);' -ErrorAction Stop
        [PM.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch { }
}

# ----------------------------- Run ---------------------------------------------
Say ''
Say 'Repairing double-click for .ahk files' 'Cyan'
Say ''

$ahk = Find-Ahk
if (-not $ahk) {
    Say 'AutoHotkey v2 is not installed on this PC.' 'Yellow'
    Say 'Install it from https://www.autohotkey.com  or type:  winget install AutoHotkey.AutoHotkey'
    Exit-Fix 1
}
$problem = Get-ExeProblem $ahk
if ($problem) { Say "AutoHotkey itself looks broken: $problem" 'Red'; Say 'Reinstall AutoHotkey v2, then run this again.'; Exit-Fix 1 }
Say "AutoHotkey v2 found:  $ahk" 'Green'

$before = Get-AhkHandler
Say ''
Say 'Right now, .ahk files open with:'
if ($before.Command) { Say "  $($before.Command)" } else { Say '  (nothing usable)' }
Say "  (set by $($before.From); ProgId: $($before.ProgId))" 'DarkGray'
$why = Get-ExeProblem $before.Exe
if ($why) { Say "That is why it fails: $why" 'Yellow' }

# Register AutoHotkey v2 for .ahk, for this user only
$cmdLine = '"' + $ahk + '" "%1" %*'
$prog = 'HKCU:\Software\Classes\AutoHotkeyScript.v2'
New-Item -Path "$prog\shell\open\command" -Force | Out-Null
Set-Item -LiteralPath $prog -Value 'AutoHotkey v2 Script'
Set-Item -LiteralPath "$prog\shell\open\command" -Value $cmdLine
New-Item -Path "$prog\DefaultIcon" -Force | Out-Null
Set-Item -LiteralPath "$prog\DefaultIcon" -Value ('"' + $ahk + '",0')
New-Item -Path "$prog\shell\edit\command" -Force | Out-Null
Set-Item -LiteralPath "$prog\shell\edit\command" -Value ('"' + "$env:WINDIR\System32\notepad.exe" + '" "%1"')
New-Item -Path 'HKCU:\Software\Classes\.ahk\OpenWithProgids' -Force | Out-Null
Set-Item -LiteralPath 'HKCU:\Software\Classes\.ahk' -Value 'AutoHotkeyScript.v2'
New-ItemProperty -LiteralPath 'HKCU:\Software\Classes\.ahk\OpenWithProgids' -Name 'AutoHotkeyScript.v2' -Value '' -PropertyType String -Force | Out-Null
# Also list AutoHotkey64 properly in "Open with"
$app = 'HKCU:\Software\Classes\Applications\' + (Split-Path $ahk -Leaf)
New-Item -Path "$app\shell\open\command" -Force | Out-Null
Set-Item -LiteralPath "$app\shell\open\command" -Value $cmdLine
New-ItemProperty -LiteralPath $app -Name 'FriendlyAppName' -Value 'AutoHotkey v2' -PropertyType String -Force | Out-Null
New-Item -Path "$app\SupportedTypes" -Force | Out-Null
New-ItemProperty -LiteralPath "$app\SupportedTypes" -Name '.ahk' -Value '' -PropertyType String -Force | Out-Null
Say ''
Say 'Registered AutoHotkey v2 for .ahk files.' 'Green'

# Clear the broken "always use" choice so Windows falls back to the registration above
$fe = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.ahk'
$blocked = $false
foreach ($sub in 'UserChoice', 'UserChoiceLatest') {
    if (Test-Path -LiteralPath "$fe\$sub") {
        try { Remove-Item -LiteralPath "$fe\$sub" -Recurse -Force -ErrorAction Stop; Say "Cleared the old choice ($sub)." 'Green' }
        catch { $blocked = $true }
    }
}
Update-Shell

$after = Get-AhkHandler
$ok = ($after.Exe -and (Resolve-Path -LiteralPath $after.Exe -ErrorAction SilentlyContinue) -and
       ((Resolve-Path -LiteralPath $after.Exe).Path -eq (Resolve-Path -LiteralPath $ahk).Path))
Say ''
if ($ok -and -not $blocked) {
    Say 'Fixed. Double-clicking .ahk files now starts AutoHotkey v2.' 'Green'
    Exit-Fix 0
}

# Windows protects the choice: let the user set it once in the official window
Say 'Windows protects the "always use this app" setting, so it has to be chosen once by hand.' 'Yellow'
Say 'The "Open with" window opens now:'
Say "  1. Pick  AutoHotkey v2  (or AutoHotkey64). If it isn't listed: Choose an app on your PC >  $ahk"
Say '  2. Click  Always.'
$sample = Join-Path $toolRoot 'PCMigrate.ahk'
if (-not (Test-Path -LiteralPath $sample)) {
    $sample = Join-Path $env:TEMP 'test-association.ahk'
    Set-Content -LiteralPath $sample -Value "MsgBox('AutoHotkey works - .ahk files open correctly now.')" -Encoding UTF8
}
if (-not $Unattended) {
    Read-Host 'Press Enter to open the window'
    Start-Process -FilePath "$env:WINDIR\System32\rundll32.exe" -ArgumentList "shell32.dll,OpenAs_RunDLL $sample"
}
Exit-Fix 0
