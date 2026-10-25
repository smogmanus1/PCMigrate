# ==============================================================================
# PCMigrate - Gui.ps1
# The restore plan window: a checklist grouped by category, coloured by status,
# with recommended items pre-ticked, a filter box and a details pane.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

function Initialize-PMGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try {
        Add-Type -Namespace PMNative -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction SilentlyContinue
        [void][PMNative.Dpi]::SetProcessDPIAware()
    } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# Simple progress window used while the plan is being built.
function New-PMProgressForm([string]$title) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.Width = 560; $f.Height = 150
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.ControlBox = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds(16, 16, 510, 22); $lbl.Text = 'Starting...'
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.SetBounds(16, 48, 510, 22); $bar.Minimum = 0; $bar.Maximum = 100
    $f.Controls.AddRange(@($lbl, $bar))
    $f.Show(); $f.Refresh()
    return @{ Form = $f; Label = $lbl; Bar = $bar }
}
function Update-PMProgressForm($pf, [int]$pct, [string]$text) {
    if (-not $pf) { return }
    $pf.Bar.Value = [math]::Max(0, [math]::Min(100, $pct))
    if ($text.Length -gt 90) { $text = $text.Substring(0, 87) + '...' }
    $pf.Label.Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

# Shows the plan. Updates .Selected on each item. Returns 'Apply', 'Report' or 'Cancel'.
function Show-PMPlan($plan, [string]$sourceText, [string]$targetText, [string[]]$diffs, [string]$packageName) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PCMigrate $script:PMVersion - restore plan for $env:COMPUTERNAME"
    $form.Width = 1280; $form.Height = 860
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)

    # ---- Header ----
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'; $header.Height = 96; $header.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
    $hText = New-Object System.Windows.Forms.Label
    $hText.Dock = 'Fill'; $hText.AutoSize = $false
    $hText.Text = "From:  $sourceText    [$packageName]`r`nTo:      $targetText`r`nDifferences:  " + ($diffs -join '   |   ')
    $header.Controls.Add($hText)

    # ---- Toolbar ----
    $tool = New-Object System.Windows.Forms.FlowLayoutPanel
    $tool.Dock = 'Top'; $tool.Height = 38; $tool.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 0)
    $lblF = New-Object System.Windows.Forms.Label; $lblF.Text = 'Filter:'; $lblF.AutoSize = $true; $lblF.Margin = New-Object System.Windows.Forms.Padding(0, 7, 4, 0)
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Width = 260
    $bRec  = New-Object System.Windows.Forms.Button; $bRec.Text = 'Recommended'; $bRec.AutoSize = $true
    $bAll  = New-Object System.Windows.Forms.Button; $bAll.Text = 'Select all shown'; $bAll.AutoSize = $true
    $bNone = New-Object System.Windows.Forms.Button; $bNone.Text = 'Clear shown'; $bNone.AutoSize = $true
    $hide  = New-Object System.Windows.Forms.CheckBox; $hide.Text = 'Hide items with nothing to do'; $hide.AutoSize = $true; $hide.Checked = $true; $hide.Margin = New-Object System.Windows.Forms.Padding(16, 6, 0, 0)
    $tool.Controls.AddRange(@($lblF, $filter, $bRec, $bAll, $bNone, $hide))

    # ---- List ----
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
    $lv.ShowItemToolTips = $true; $lv.HideSelection = $false
    [void]$lv.Columns.Add('Item', 330)
    [void]$lv.Columns.Add('Status', 140)
    [void]$lv.Columns.Add('Why', 640)
    [void]$lv.Columns.Add('MB', 70, 'Right')

    # ---- Details + buttons ----
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'; $bottom.Height = 150
    $details = New-Object System.Windows.Forms.TextBox
    $details.Multiline = $true; $details.ReadOnly = $true; $details.ScrollBars = 'Vertical'
    $details.Location = New-Object System.Drawing.Point(10, 6)
    $count = New-Object System.Windows.Forms.Label; $count.AutoSize = $true
    $bReport = New-Object System.Windows.Forms.Button; $bReport.Text = 'Save report...'; $bReport.AutoSize = $true
    $bApply  = New-Object System.Windows.Forms.Button; $bApply.Text = 'Restore selected'; $bApply.AutoSize = $true
    $bCancel = New-Object System.Windows.Forms.Button; $bCancel.Text = 'Cancel'; $bCancel.AutoSize = $true
    $bApply.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $bottom.Controls.AddRange(@($details, $count, $bReport, $bApply, $bCancel))
    # Lay the bottom bar out from the panel's real size every time it changes (works at any window size / DPI).
    $layoutBottom = {
        $w = $bottom.ClientSize.Width; $h = $bottom.ClientSize.Height
        $bh = [math]::Max($bApply.PreferredSize.Height, 30) + 4
        $y = $h - $bh - 8
        $details.Size = New-Object System.Drawing.Size([math]::Max(100, $w - 20), [math]::Max(30, $y - 14))
        $x = $w - 10
        foreach ($b in @($bCancel, $bApply, $bReport)) {
            $bw = [math]::Max($b.PreferredSize.Width + 16, 110)
            $x -= $bw
            $b.SetBounds($x, $y, $bw, $bh)
            $x -= 8
        }
        $count.Location = New-Object System.Drawing.Point(10, ($y + [int](($bh - $count.PreferredHeight) / 2)))
    }
    $bottom.Add_Resize($layoutBottom)
    $form.Add_Shown($layoutBottom)

    $form.Controls.Add($lv)
    $form.Controls.Add($bottom)
    $form.Controls.Add($tool)
    $form.Controls.Add($header)
    $form.AcceptButton = $null; $form.CancelButton = $bCancel

    $groups = @{}
    foreach ($g in $script:PMGroups) {
        $grp = New-Object System.Windows.Forms.ListViewGroup($g, $g)
        [void]$lv.Groups.Add($grp); $groups[$g] = $grp
    }
    $state = @{ Loading = $false; Result = 'Cancel' }
    $noAction = @('Installed', 'Info', 'Exists')

    $updateCount = {
        $sel = @($plan | Where-Object { $_.Selected })
        $apps = @($sel | Where-Object { $_.Kind -eq 'winget' }).Count
        $count.Text = "$($sel.Count) selected  ($apps app installs, $($sel.Count - $apps) other)"
    }

    $populate = {
        $state.Loading = $true
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $f = $filter.Text.Trim()
        foreach ($it in $plan) {
            if ($hide.Checked -and ($noAction -contains $it.Status) -and $it.Kind -ne 'info') { continue }
            if ($f -and ("$($it.Name) $($it.Label) $($it.Reason)" -notlike "*$f*")) { continue }
            $row = New-Object System.Windows.Forms.ListViewItem($it.Name)
            [void]$row.SubItems.Add($it.Label)
            [void]$row.SubItems.Add("$($it.Reason)")
            [void]$row.SubItems.Add($(if ($it.SizeMB -gt 0) { '{0:N1}' -f $it.SizeMB } else { '' }))
            $row.Group = $groups[$it.Group]
            $row.Tag = $it
            $row.Checked = [bool]$it.Selected
            $row.ForeColor = [System.Drawing.Color]::FromName($script:PMStatus[$it.Status].Color)
            $tip = "$($it.Reason)"
            if ($it.Notes) { $tip += "`n" + (@($it.Notes) -join "`n") }
            $row.ToolTipText = $tip
            [void]$lv.Items.Add($row)
        }
        $lv.EndUpdate()
        $state.Loading = $false
        & $updateCount
    }

    $lv.Add_ItemCheck({
        param($s, $e)
        if ($state.Loading) { return }
        $it = $lv.Items[$e.Index].Tag
        if (-not $script:PMStatus[$it.Status].Selectable) { $e.NewValue = 'Unchecked' }
    })
    $lv.Add_ItemChecked({
        param($s, $e)
        if ($state.Loading) { return }
        $e.Item.Tag.Selected = $e.Item.Checked
        & $updateCount
    })
    $lv.Add_SelectedIndexChanged({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $it = $lv.SelectedItems[0].Tag
        $t = "$($it.Name)   [$($it.Label)]`r`n$($it.Reason)"
        foreach ($n in $it.Notes) { $t += "`r`n- $n" }
        if ($it.Data -and $it.Data.Source) { $t += "`r`nFrom: $($it.Data.Source)" }
        if ($it.Data -and $it.Data.Target) { $t += "`r`nTo:   $($it.Data.Target)" }
        if ($it.Data -and $it.Data.Key)    { $t += "`r`nKey:  $($it.Data.Key)" }
        if ($it.Data -and $it.Data.PathRefs -and $it.Data.PathRefs.Roots.Count) {
            $t += "`r`nSaved paths: " + ((@($it.Data.PathRefs.Roots.Keys) | Sort-Object) -join ', ')
        }
        $details.Text = $t
    })
    $filter.Add_TextChanged({ & $populate })
    $hide.Add_CheckedChanged({ & $populate })
    $bRec.Add_Click({ foreach ($it in $plan) { $it.Selected = $it.Default }; & $populate })
    $bAll.Add_Click({
        foreach ($row in $lv.Items) { if ($script:PMStatus[$row.Tag.Status].Selectable) { $row.Tag.Selected = $true } }
        & $populate
    })
    $bNone.Add_Click({ foreach ($row in $lv.Items) { $row.Tag.Selected = $false }; & $populate })
    $bApply.Add_Click({
        $n = @($plan | Where-Object { $_.Selected }).Count
        if ($n -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Nothing is selected.', 'PCMigrate'); return }
        $r = [System.Windows.Forms.MessageBox]::Show("Restore $n selected item(s)?`n`nEverything that gets replaced is backed up first, and Undo can reverse it.", 'PCMigrate', 'OKCancel', 'Question')
        if ($r -eq 'OK') { $state.Result = 'Apply'; $form.Close() }
    })
    $bReport.Add_Click({ $state.Result = 'Report'; $form.Close() })
    $bCancel.Add_Click({ $state.Result = 'Cancel'; $form.Close() })

    & $populate
    [void]$form.ShowDialog()
    $form.Dispose()
    return $state.Result
}
