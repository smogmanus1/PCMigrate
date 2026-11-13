#Requires -Version 5.1
<#
.SYNOPSIS
  PCMigrate - Update all apps with winget, and fix what fails.
.DESCRIPTION
  Updates every app winget can update, ONE APP AT A TIME, so each result is
  known. Then it deals with the failures instead of just listing them:
    - download / network hiccups      -> retried automatically
    - app is running ("in use")       -> asks you to close it, then retries
    - "different install technology"  -> offers to uninstall the old version
                                         and install the new one (asks first;
                                         app settings normally stay)
    - needs a restart                 -> reminds you at the end
  Ends with a summary and a log file.
  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
.PARAMETER Unattended
  No questions: retries what can be retried, never uninstalls anything.
#>
param([switch]$Unattended)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\Common.ps1"
$Host.UI.RawUI.WindowTitle = "PCMigrate $script:PMVersion - Update all apps"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
trap { Write-PMError "Unexpected error: $_"; Write-PMLog ($_ | Out-String); if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }

function Exit-PM([int]$code = 0) { if (-not $Unattended) { Write-Host ''; Read-Host 'Press Enter to close' }; exit $code }

if (-not (Assert-PMWindows 'Update all apps')) { Exit-PM 1 }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-PMError 'winget was not found. Install "App Installer" from the Microsoft Store, then try again.'
    Exit-PM 1
}

$logDir = Join-Path $env:USERPROFILE 'PCMigrate\Logs'
Start-PMLog (Join-Path $logDir ("update-apps_{0}.log" -f (New-PMStamp)))

# ----------------------------- winget result codes ----------------------------
# From winget's AppInstallerErrors.h. Kind decides what we do about it.
$script:Codes = @{
    '00000000' = @{ Kind = 'Ok';        Text = 'Updated' }
    '8A15002B' = @{ Kind = 'Current';   Text = 'Already up to date (no applicable update)' }
    '8A15004F' = @{ Kind = 'Current';   Text = 'Already up to date' }
    '8A150061' = @{ Kind = 'Current';   Text = 'Already installed' }
    '8A15010D' = @{ Kind = 'Current';   Text = 'Already installed' }
    '8A15008E' = @{ Kind = 'Tech';      Text = 'New version uses a different install technology' }
    '8A150101' = @{ Kind = 'InUse';     Text = 'The app is running' }
    '8A150103' = @{ Kind = 'InUse';     Text = 'A file of the app is in use' }
    '8A150111' = @{ Kind = 'InUse';     Text = 'The app is in use by another program' }
    '8A150109' = @{ Kind = 'Reboot';    Text = 'Updated - restart to finish' }
    '8A15010A' = @{ Kind = 'Reboot';    Text = 'Needs a restart before it can update' }
    '8A15010B' = @{ Kind = 'Reboot';    Text = 'Installer started a restart' }
    '8A150008' = @{ Kind = 'Retry';     Text = 'Download failed' }
    '8A15002E' = @{ Kind = 'Retry';     Text = 'Download was incomplete' }
    '8A15006B' = @{ Kind = 'Retry';     Text = 'Could not download a dependency' }
    '8A150011' = @{ Kind = 'Stop';      Text = 'Installer hash does not match (publisher changed the file; try again in a day or two)' }
    '8A150068' = @{ Kind = 'Stop';      Text = 'Pinned - you told winget not to update it (winget pin list)' }
    '8A150050' = @{ Kind = 'Stop';      Text = 'Installed version unknown - winget cannot tell if it is newer' }
    '8A150010' = @{ Kind = 'Stop';      Text = 'No installer fits this PC' }
    '8A15010C' = @{ Kind = 'Stop';      Text = 'Cancelled' }
    '8A15003A' = @{ Kind = 'Stop';      Text = 'Blocked by policy' }
    '8A15010F' = @{ Kind = 'Stop';      Text = 'Blocked by policy' }
    '8A15001B' = @{ Kind = 'Stop';      Text = 'Microsoft Store blocked by policy' }
    '8A15001C' = @{ Kind = 'Stop';      Text = 'Microsoft Store blocked by policy' }
}
function Get-PMResult([int]$code) {
    $hex = '{0:X8}' -f $code
    if ($script:Codes.ContainsKey($hex)) { return [pscustomobject]@{ Hex = $hex; Kind = $script:Codes[$hex].Kind; Text = $script:Codes[$hex].Text } }
    # anything else: installer-specific failure - worth one more try
    return [pscustomobject]@{ Hex = $hex; Kind = 'Retry'; Text = "Installer failed (code 0x$hex)" }
}

# ----------------------------- What can be updated ----------------------------
# Preferred: the WinGet PowerShell module (exact package Ids, nothing cut off).
function Get-PMUpdatesFromModule {
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Write-PMInfo 'Installing the Microsoft.WinGet.Client PowerShell module (one time)...'
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    $list = @()
    foreach ($p in @(Get-WinGetPackage -ErrorAction Stop)) {
        if (-not $p.IsUpdateAvailable) { continue }
        if (-not $p.Source) { continue }               # not from a winget source - winget can't update it
        $avail = ''
        if ($p.AvailableVersions -and @($p.AvailableVersions).Count) { $avail = "$(@($p.AvailableVersions)[0])" }
        $list += [pscustomobject]@{ Name = "$($p.Name)"; Id = "$($p.Id)"; Version = "$($p.InstalledVersion)"; Available = $avail; Source = "$($p.Source)" }
    }
    return $list
}

# Fallback: read the table that 'winget upgrade' prints. Column starts come from the header line.
function Get-PMUpdatesFromText {
    $lines = @(& winget upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>&1 | ForEach-Object { "$_" })
    $list = @()
    $h = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Name\s+Id\s+Version\s+Available') { $h = $i; break }
    }
    if ($h -lt 0) { return $list }
    $head = $lines[$h] -replace '^.*?(Name\s+Id)', '$1'
    $offset = $lines[$h].Length - $head.Length
    $cId  = $head.IndexOf('Id') + $offset
    $cVer = $head.IndexOf('Version') + $offset
    $cAv  = $head.IndexOf('Available') + $offset
    $cSrc = $head.IndexOf('Source') + $offset
    for ($i = $h + 2; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Length -le $cAv -or $l -match '^\s*\d+ upgrades? available' -or $l -match '^-+$') { break }
        $name = $l.Substring(0, [Math]::Min($cId, $l.Length)).Trim()
        $id   = $l.Substring($cId, $cVer - $cId).Trim()
        $ver  = $l.Substring($cVer, $cAv - $cVer).Trim()
        $src  = ''
        if ($cSrc -gt $cAv -and $l.Length -gt $cSrc) { $av = $l.Substring($cAv, $cSrc - $cAv).Trim(); $src = $l.Substring($cSrc).Trim() }
        else { $av = $l.Substring($cAv).Trim() }
        if (-not $id -or $id -match '\u2026$') { continue }    # cut-off Id - can't be used safely
        $list += [pscustomobject]@{ Name = $name; Id = $id; Version = $ver; Available = $av; Source = $src }
    }
    return $list
}

function Get-PMUpdates {
    try { return @(Get-PMUpdatesFromModule) }
    catch {
        Write-PMWarn "WinGet PowerShell module unavailable ($($_.Exception.Message)) - reading winget's table instead."
        return @(Get-PMUpdatesFromText)
    }
}

# ----------------------------- One app at a time ------------------------------
$common = @('--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')

function Invoke-PMUpgrade($p) {
    $wargs = @('upgrade', '--id', $p.Id) + $common + @('--include-unknown')
    if ($p.Source) { $wargs += @('--source', $p.Source) }
    & winget @wargs | Out-Host
    return (Get-PMResult $LASTEXITCODE)
}

# Uninstall the old version, install the new one. Used only for "different install technology".
function Invoke-PMReinstall($p) {
    Write-PMInfo "    Uninstalling the old version of $($p.Name)..."
    $u = @('uninstall', '--id', $p.Id, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
    if ($p.Source) { $u += @('--source', $p.Source) }
    & winget @u | Out-Host
    $ur = Get-PMResult $LASTEXITCODE
    if ($ur.Kind -ne 'Ok' -and $ur.Kind -ne 'Reboot') {
        return [pscustomobject]@{ Hex = $ur.Hex; Kind = 'Stop'; Text = "Could not uninstall the old version ($($ur.Text)) - nothing was changed" }
    }
    Write-PMInfo "    Installing the new version of $($p.Name)..."
    $in = @('install', '--id', $p.Id) + $common
    if ($p.Source) { $in += @('--source', $p.Source) }
    & winget @in | Out-Host
    $ir = Get-PMResult $LASTEXITCODE
    if ($ir.Kind -eq 'Ok' -or $ir.Kind -eq 'Current') { return [pscustomobject]@{ Hex = $ir.Hex; Kind = 'Ok'; Text = 'Reinstalled with the new install technology' } }
    if ($ir.Kind -eq 'Reboot') { return $ir }
    # The old version is gone and the new one failed: say so loudly, with the exact fix.
    $fix = "winget install --id $($p.Id) --exact"
    if ($p.Source) { $fix += " --source $($p.Source)" }
    return [pscustomobject]@{ Hex = $ir.Hex; Kind = 'Stop'; Text = "OLD VERSION REMOVED but the new install failed ($($ir.Text)). Install it with:  $fix" }
}

function Show-PMLine($p, $r) {
    $color = switch ($r.Kind) { 'Ok' { 'Green' } 'Current' { 'DarkGray' } 'Reboot' { 'Cyan' } default { 'Yellow' } }
    Write-Host ("    -> {0}" -f $r.Text) -ForegroundColor $color
    Write-PMLog ("RESULT {0} [{1}] 0x{2} {3}" -f $p.Name, $p.Id, $r.Hex, $r.Text)
}

# ----------------------------- Run ---------------------------------------------
Write-Host ''
Write-Host "PCMigrate $script:PMVersion - updating all apps on $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host 'Close your browsers and other open apps first - an app that is running cannot be updated.'

Write-PMStep '1/4  Refreshing the app catalogs'
& winget source update --disable-interactivity

Write-PMStep '2/4  Finding apps with updates'
$todo = @(Get-PMUpdates)
if (-not $todo.Count) { Write-PMOk 'Everything is up to date.'; Exit-PM 0 }
foreach ($p in $todo) { Write-Host ("  {0,-40} {1} -> {2}" -f $p.Name, $p.Version, $p.Available) }
Write-PMInfo "$($todo.Count) app(s) to update."

Write-PMStep '3/4  Updating, one app at a time'
$results = @{}
$n = 0
foreach ($p in $todo) {
    $n++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}  ({3})" -f $n, $todo.Count, $p.Name, $p.Id) -ForegroundColor White
    $r = Invoke-PMUpgrade $p
    Show-PMLine $p $r
    $results[$p.Id] = $r
}

Write-PMStep '4/4  Fixing what failed'
$fixed = $false

# a) Network / installer hiccups: one automatic retry
foreach ($p in $todo) {
    if ($results[$p.Id].Kind -ne 'Retry') { continue }
    $fixed = $true
    Write-Host ''
    Write-Host "Retrying $($p.Name) (last time: $($results[$p.Id].Text))..." -ForegroundColor White
    Start-Sleep -Seconds 3
    $r = Invoke-PMUpgrade $p
    if ($r.Kind -eq 'Retry') { $r = [pscustomobject]@{ Hex = $r.Hex; Kind = 'Stop'; Text = "$($r.Text) - failed twice" } }
    Show-PMLine $p $r
    $results[$p.Id] = $r
}

# b) Apps that were running: ask to close them, then retry (up to 2 rounds)
for ($round = 1; $round -le 2; $round++) {
    $busy = @($todo | Where-Object { $results[$_.Id].Kind -eq 'InUse' })
    if (-not $busy.Count) { break }
    $fixed = $true
    Write-Host ''
    Write-Host 'These apps could not update because they are running:' -ForegroundColor Yellow
    foreach ($p in $busy) { Write-Host "  - $($p.Name)" }
    if ($Unattended) { Start-Sleep -Seconds 10 }
    else {
        $ans = Read-Host 'Close them (check the system tray too), then press Enter to retry  (S = skip)'
        if ($ans -match '^[sS]') { break }
    }
    foreach ($p in $busy) {
        Write-Host ''
        Write-Host "Retrying $($p.Name)..." -ForegroundColor White
        $r = Invoke-PMUpgrade $p
        Show-PMLine $p $r
        $results[$p.Id] = $r
    }
}

# c) "Different install technology": winget won't upgrade across installer types.
#    The fix is uninstall + install. Asked per app; never done unattended.
$tech = @($todo | Where-Object { $results[$_.Id].Kind -eq 'Tech' })
if ($tech.Count) {
    $fixed = $true
    Write-Host ''
    Write-Host 'These apps changed how they install, so winget cannot update them in place:' -ForegroundColor Yellow
    foreach ($p in $tech) { Write-Host "  - $($p.Name)  $($p.Version) -> $($p.Available)" }
    Write-Host 'PCMigrate can uninstall the old version and install the new one. Your settings for the app'
    Write-Host 'normally stay (they live in your user folders), but sign-ins or licences may need re-entering.'
    foreach ($p in $tech) {
        if ($Unattended) { Write-PMWarn "  $($p.Name): skipped (unattended runs never uninstall)"; continue }
        Write-Host ''
        $ans = Read-Host "Reinstall $($p.Name) now?  Y = yes, N = no"
        if ($ans -notmatch '^[yY]') { Write-PMInfo "    Skipped $($p.Name)."; continue }
        $r = Invoke-PMReinstall $p
        Show-PMLine $p $r
        $results[$p.Id] = $r
    }
}
if (-not $fixed) { Write-PMOk 'Nothing needed fixing.' }

# ----------------------------- Summary -----------------------------------------
$groups = [ordered]@{
    'Updated'               = @($todo | Where-Object { $results[$_.Id].Kind -eq 'Ok' })
    'Already up to date'    = @($todo | Where-Object { $results[$_.Id].Kind -eq 'Current' })
    'Restart to finish'     = @($todo | Where-Object { $results[$_.Id].Kind -eq 'Reboot' })
    'Not updated'           = @($todo | Where-Object { 'Ok', 'Current', 'Reboot' -notcontains $results[$_.Id].Kind })
}
Write-Host ''
Write-Host '===== Summary =====' -ForegroundColor Cyan
foreach ($g in $groups.Keys) {
    $items = $groups[$g]
    if (-not $items.Count) { continue }
    $color = switch ($g) { 'Updated' { 'Green' } 'Already up to date' { 'DarkGray' } 'Restart to finish' { 'Cyan' } default { 'Yellow' } }
    Write-Host ("{0} ({1})" -f $g, $items.Count) -ForegroundColor $color
    foreach ($p in $items) {
        if ($g -eq 'Not updated') { Write-Host ("  - {0}: {1}" -f $p.Name, $results[$p.Id].Text) }
        else { Write-Host "  - $($p.Name)" }
    }
}
Write-PMLog ("SUMMARY updated={0} current={1} restart={2} failed={3}" -f $groups['Updated'].Count, $groups['Already up to date'].Count, $groups['Restart to finish'].Count, $groups['Not updated'].Count)
Write-Host ''
if ($groups['Restart to finish'].Count -or $groups['Updated'].Count) { Write-Host 'Restart the PC, open your main apps once, then capture.' -ForegroundColor Cyan }
Write-Host "Log: $script:PMLogFile" -ForegroundColor DarkGray
if ($groups['Not updated'].Count) { Exit-PM 2 } else { Exit-PM 0 }
