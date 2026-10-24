#Requires -Version 5.1
<#
.SYNOPSIS
  PCMigrate - Undo a restore session.
.DESCRIPTION
  Reads the journal of a restore session and reverses every change in reverse
  order: settings folders and files are put back from their backups, registry
  keys and values are restored, tasks, fonts, Wi-Fi profiles and drive mappings
  are removed. Apps that were installed are NOT uninstalled (listed instead).
  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
.PARAMETER Session
  Session folder. Default: you pick from a list (newest first).
#>
param([string]$Session, [switch]$Unattended)

. "$PSScriptRoot\lib\Common.ps1"
$Host.UI.RawUI.WindowTitle = "PCMigrate $script:PMVersion - Undo"
$root = Join-Path $env:USERPROFILE 'PCMigrate\Restores'
trap { Write-PMError "Unexpected error: $_"; Write-PMLog ($_ | Out-String); if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit 1 }

if (-not $Session) {
    $sessions = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path (Join-Path $_.FullName 'journal.json') } | Sort-Object Name -Descending)
    if (-not $sessions.Count) { Write-Host 'No restore sessions found.' -ForegroundColor Yellow; if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit }
    Write-Host ''
    Write-Host 'Restore sessions (newest first):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $sessions.Count; $i++) {
        $j = Read-PMJson (Join-Path $sessions[$i].FullName 'journal.json')
        $state = if ($j.Undone) { '  (already undone)' } else { '' }
        Write-Host ("  {0}. {1}  - {2} change(s) from {3}{4}" -f ($i + 1), $sessions[$i].Name, @($j.Entries).Count, (Split-Path "$($j.Package)" -Leaf), $state)
    }
    if ($Unattended) {
        $first = $sessions | Where-Object { -not (Read-PMJson (Join-Path $_.FullName 'journal.json')).Undone } | Select-Object -First 1
        if (-not $first) { Write-Host 'Every session has already been undone.'; exit }
        $Session = $first.FullName
    } else {
        $pick = Read-Host 'Number to undo (Enter = 1, Q = quit)'
        if ($pick -match '^[qQ]') { exit }
        if (-not $pick) { $pick = '1' }
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $sessions.Count) {
            Write-Host 'Invalid choice.' -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1
        }
        $Session = $sessions[$idx - 1].FullName
    }
}

$journalPath = Join-Path $Session 'journal.json'
$j = Read-PMJson $journalPath
if (-not $j) { Write-Host "No journal in $Session" -ForegroundColor Red; exit 1 }
Start-PMLog (Join-Path $Session 'undo.log')
if (-not (Test-PMAdmin)) { Write-PMWarn 'Not running as administrator - some items (fonts, drive mappings, tasks) may fail.' }
if ($j.Undone) { Write-PMWarn 'This session was already undone once.' }

$entries = @($j.Entries)
[array]::Reverse($entries)
Write-PMStep "Undoing $($entries.Count) change(s) from $(Split-Path $Session -Leaf)"
if (-not $Unattended) {
    Write-Host 'Close the apps whose settings were restored before continuing.' -ForegroundColor Yellow
    if ((Read-Host 'Proceed? [y/N]') -notmatch '^\s*[yY]') { exit }
}

$installed = @()
$problems = 0
foreach ($e in $entries) {
    try {
        switch ($e.Type) {
            # A recorded backup that has gone missing means: leave the item alone (never delete it).
            'dir' {
                if ($e.Backup) {
                    if (-not (Test-Path -LiteralPath $e.Backup)) { throw "backup missing ($($e.Backup)) - left unchanged" }
                    & robocopy $e.Backup $e.Target /MIR /XJ /R:1 /W:1 /NP /NFL /NDL | Out-Null
                    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }
                } elseif (Test-Path -LiteralPath $e.Target) {
                    Remove-Item -LiteralPath $e.Target -Recurse -Force -ErrorAction Stop   # did not exist before the restore
                }
            }
            'file' {
                if ($e.Backup) {
                    if (-not (Test-Path -LiteralPath $e.Backup)) { throw "backup missing ($($e.Backup)) - left unchanged" }
                    Copy-Item -LiteralPath $e.Backup -Destination $e.Target -Force -ErrorAction Stop
                } elseif (Test-Path -LiteralPath $e.Target) {
                    Remove-Item -LiteralPath $e.Target -Force -ErrorAction Stop
                }
            }
            'regkey' {
                if ($e.Backup -and -not (Test-Path -LiteralPath $e.Backup)) { throw "backup missing ($($e.Backup)) - key left unchanged" }
                if ($e.Key) { & reg.exe delete $e.Key /f 2>&1 | Out-Null }
                if ($e.Backup) {
                    & reg.exe import $e.Backup 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "reg import of $($e.Backup) failed" }
                }
            }
            'value' {
                if ($e.Existed) {
                    $kind = if ($e.OldKind) { $e.OldKind } else { 'String' }
                    New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Old -PropertyType $kind -Force | Out-Null
                } else {
                    Remove-ItemProperty -Path $e.Path -Name $e.Name -Force -ErrorAction SilentlyContinue
                }
            }
            'task'     { Unregister-ScheduledTask -TaskName $e.Name -TaskPath $e.Path -Confirm:$false -ErrorAction Stop }
            'font'     {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $e.RegName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $e.File) {
                    try { Remove-Item -LiteralPath $e.File -Force -ErrorAction Stop }
                    catch { throw "font file is in use - restart, then delete $($e.File)" }
                }
            }
            'wifi'     { & netsh wlan delete profile name="$($e.Name)" 2>&1 | Out-Null }
            'junction' { if (Test-Path -LiteralPath $e.Target) { [IO.Directory]::Delete($e.Target) } }   # removes the link only
            'mkdir'    { if ((Test-Path -LiteralPath $e.Target) -and -not (Get-ChildItem -LiteralPath $e.Target -Force)) { Remove-Item -LiteralPath $e.Target -Force } }
            'winget'   { if ($e.Ok) { $installed += $e.Label } }
        }
        if ($e.Type -ne 'winget') { Write-PMInfo "  undone: $($e.Label)" }
    } catch {
        $problems++
        Write-PMWarn "  problem undoing $($e.Label): $($_.Exception.Message)"
    }
}
[Environment]::SetEnvironmentVariable('PCMigrateRefresh', '1', 'User')
[Environment]::SetEnvironmentVariable('PCMigrateRefresh', $null, 'User')

# Mark the journal as undone (only when everything went back cleanly)
if ($problems -eq 0) {
    $raw = Read-PMJson $journalPath
    $raw.Undone = $true
    Save-PMJson $raw $journalPath 6
}

Write-PMStep 'Undo finished'
if ($problems) { Write-PMWarn "$problems item(s) had problems - see $(Join-Path $Session 'undo.log')" } else { Write-PMOk 'Everything was put back.' }
if ($installed.Count) {
    Write-PMInfo ''
    Write-PMInfo 'Apps installed during that restore are still installed (uninstall them from Settings > Apps if you want):'
    foreach ($a in $installed) { Write-PMInfo "  - $a" }
}
Write-PMInfo 'Restart the PC if a drive mapping or fonts were removed.'
if (-not $Unattended) { Read-Host 'Press Enter to close' }
