#Requires -Version 5.1
<#
.SYNOPSIS
  PCMigrate - Restore. Run on the NEW PC, as administrator.
.DESCRIPTION
  Reads a migration package, profiles THIS PC's hardware and software, and builds
  a plan of what fits: apps to install, settings for apps that are present, and
  items to skip because they need hardware this PC does not have. You review the
  plan in a checklist window, then PCMigrate applies it with full backups and an
  undo journal.
  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
.PARAMETER Package
  Package folder. Default: newest package in PackageRoot (you pick if several).
.PARAMETER Unattended
  No window, no prompts - applies the recommended selection.
.PARAMETER WhatIf
  Build the plan and write the report only. Nothing is changed.
#>
param(
    [string]$Package,
    [string]$ConfigPath,
    [string]$PackageRoot,
    [switch]$Unattended,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
$toolRoot = Split-Path $PSScriptRoot -Parent
foreach ($lib in 'Common', 'SystemInfo', 'Compat', 'PathScan', 'Plan', 'Apply', 'Report') { . "$PSScriptRoot\lib\$lib.ps1" }
$Host.UI.RawUI.WindowTitle = "PCMigrate $script:PMVersion - Restore"
trap {
    Write-PMError "Unexpected error: $_"
    Write-PMLog ($_ | Out-String)
    Write-PMError "If the restore had already started, use 'Undo last restore' to reverse what was changed."
    if (-not $Unattended) { Read-Host 'Press Enter to close' }
    exit 1
}

function Exit-PM([int]$code = 0) { if (-not $Unattended) { Read-Host 'Press Enter to close' }; exit $code }
if (-not (Assert-PMWindows 'Restore')) { Exit-PM 1 }

if (-not $ConfigPath) { $ConfigPath = Join-Path $toolRoot 'PCMigrate.ini' }
$ini = Read-PMIni $ConfigPath
$rulesPath = Get-PMSetting $ini 'Paths' 'RulesFile' ''
if (-not $rulesPath) { $rulesPath = Join-Path $toolRoot 'rules\compat-rules.json' }
if (-not $PackageRoot) { $PackageRoot = Get-PMSetting $ini 'Paths' 'PackageRoot' '' }
if (-not $PackageRoot) { $PackageRoot = Split-Path $toolRoot -Parent }

Write-Host ''
Write-Host "PCMigrate $script:PMVersion - restore onto $env:COMPUTERNAME" -ForegroundColor Cyan

# ----------------------------- Safety checks ----------------------------------
if (-not (Test-PMAdmin) -and -not $WhatIf) {
    Write-PMError 'Please run this as administrator (the launcher does this for you).'
    Exit-PM 1
}
$desk = Get-PMDesktopUser
if ($desk -and $desk -ne $env:USERNAME) {
    Write-PMError "This window runs as '$env:USERNAME' but the signed-in user is '$desk'."
    Write-PMError 'Settings would go to the wrong account. Sign in as the user you are migrating to and run it again'
    Write-PMError 'from that account (approve the admin prompt with that account if it is an administrator).'
    Exit-PM 1
}

# ----------------------------- Package ----------------------------------------
if (-not $Package) {
    $pkgs = @(Find-PMPackages $PackageRoot)
    if (-not $pkgs.Count) {
        Write-PMError "No migration packages found in $PackageRoot"
        Write-PMInfo 'Run Capture on the old PC first, and let the package finish syncing / copying.'
        Exit-PM 1
    }
    if ($pkgs.Count -eq 1 -or $Unattended) { $Package = $pkgs[0].FullName }
    else {
        Write-Host ''
        for ($i = 0; $i -lt $pkgs.Count; $i++) { Write-Host ("  {0}. {1}   ({2:yyyy-MM-dd HH:mm})" -f ($i + 1), $pkgs[$i].Name, $pkgs[$i].LastWriteTime) }
        $pick = Read-Host 'Which package? (Enter = 1)'
        if (-not $pick) { $pick = '1' }
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $pkgs.Count) { Write-PMError 'Invalid choice.'; Exit-PM 1 }
        $Package = $pkgs[$idx - 1].FullName
    }
}
$pkg = Open-PMPackage $Package
Write-PMInfo "Package: $($pkg.Path)  (format $($pkg.Schema), from $($pkg.Computer))"
if ($pkg.Computer -eq $env:COMPUTERNAME) { Write-PMWarn 'Note: this package was captured on THIS computer.' }

$rules = Read-PMRules $rulesPath

# ----------------------------- Analyse ----------------------------------------
$pf = $null
if (-not $Unattended) { . "$PSScriptRoot\lib\Gui.ps1"; Initialize-PMGui; $pf = New-PMProgressForm 'PCMigrate - checking this PC' }
$progress = { param($p, $t) if ($pf) { Update-PMProgressForm $pf $p $t } else { Write-Progress -Activity 'PCMigrate' -Status $t -PercentComplete $p } }

& $progress 1 'Reading this PC''s hardware...'
$target = Get-PMSystemProfile
& $progress 3 'Listing installed programs...'
$targetPrograms = Get-PMInstalledPrograms
& $progress 4 'Asking winget what is installed...'
$installedIds = Get-PMWingetInstalled

$plan = New-PMPlan $pkg $target $rules $ini $installedIds $targetPrograms $progress
if ($pf) { $pf.Form.Close(); $pf.Form.Dispose() } else { Write-Progress -Activity 'PCMigrate' -Completed }

$diffs = @(Compare-PMProfiles $pkg.Source $target)
$srcText = Format-PMProfileSummary $pkg.Source
$dstText = Format-PMProfileSummary $target
Write-PMInfo "Old PC : $srcText"
Write-PMInfo "This PC: $dstText"
foreach ($d in $diffs) { Write-PMInfo "  - $d" }

$reportPath = Join-Path $pkg.Path ("PCMigrate-Report-{0}-{1}.html" -f $env:COMPUTERNAME, (New-PMStamp))

if ($WhatIf) {
    [void](New-PMReport $plan $pkg $target $diffs $reportPath $null)
    Write-PMOk "Plan written to $reportPath (nothing was changed)."
    if (-not $Unattended) { Invoke-Item $reportPath }
    Exit-PM 0
}

# ----------------------------- Review -----------------------------------------
if (-not $Unattended) {
    while ($true) {
        $choice = Show-PMPlan $plan $srcText $dstText $diffs $pkg.Name
        if ($choice -eq 'Report') {
            [void](New-PMReport $plan $pkg $target $diffs $reportPath $null)
            Invoke-Item $reportPath
            continue
        }
        break
    }
    if ($choice -ne 'Apply') { Write-PMInfo 'Cancelled - nothing was changed.'; Exit-PM 0 }
}

# ----------------------------- Apply ------------------------------------------
$result = Invoke-PMPlan $plan $pkg $ini
[void](New-PMReport $plan $pkg $target $diffs $reportPath $result)
Copy-Item -LiteralPath $reportPath -Destination $result.Session -Force -ErrorAction SilentlyContinue

Write-PMStep 'Restore finished'
Write-PMInfo "$($result.Selected) item(s) processed."
if ($result.Failed.Count) {
    Write-PMWarn "$($result.Failed.Count) problem(s):"
    foreach ($f in $result.Failed) { Write-PMWarn "  - $f" }
} else { Write-PMOk 'No problems.' }
Write-PMInfo "Report: $reportPath"
Write-PMInfo "Undo data: $($result.Session)  (use 'Undo last restore' in the launcher)"
if ($result.Checklist) { Write-PMInfo "Install-by-hand checklist: $($result.Checklist)" }
if ($result.Reboot) { Write-PMWarn 'Restart the PC to finish (drive mapping takes effect after a restart).' }
else { Write-PMInfo 'Sign out and back in so every setting takes effect.' }

if (-not $Unattended) {
    if ($result.Checklist) { Start-Process notepad.exe -ArgumentList "`"$($result.Checklist)`"" }
    Invoke-Item $reportPath
}
Exit-PM 0
