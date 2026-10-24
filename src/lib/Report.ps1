# ==============================================================================
# PCMigrate - Report.ps1
# Writes a self-contained HTML report of the plan (and the results, if run).
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

function ConvertTo-PMHtml([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function New-PMReport($plan, $pkg, $target, [string[]]$diffs, [string]$path, $result) {
    $css = @'
:root { --bg:#fff; --fg:#1d1d1f; --muted:#6b6b70; --line:#e3e3e8; --head:#f5f5f7;
        --ok:#1b7f3b; --info:#2a5db0; --warn:#b35c00; --bad:#b3261e; --dim:#8a8a8f; }
@media (prefers-color-scheme: dark) { :root { --bg:#161618; --fg:#ececf0; --muted:#a0a0a8; --line:#2c2c30; --head:#1f1f22;
        --ok:#4cc26d; --info:#7aa7ff; --warn:#ffa34d; --bad:#ff6b5e; --dim:#8a8a90; } }
body { font: 14px/1.45 "Segoe UI", system-ui, sans-serif; background: var(--bg); color: var(--fg); margin: 0; padding: 24px; }
main { max-width: 1200px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 17px; margin: 28px 0 8px; }
.sub { color: var(--muted); margin-bottom: 18px; }
table { width: 100%; border-collapse: collapse; margin-bottom: 8px; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th { background: var(--head); font-weight: 600; }
.k { width: 140px; color: var(--muted); }
.sel { width: 26px; text-align: center; }
.s-ok { color: var(--ok); } .s-info { color: var(--info); } .s-warn { color: var(--warn); } .s-bad { color: var(--bad); } .s-dim { color: var(--dim); }
.note { color: var(--muted); font-size: 12.5px; }
.pill { display:inline-block; padding: 1px 8px; border-radius: 10px; background: var(--head); border: 1px solid var(--line); margin: 2px 4px 2px 0; }
footer { color: var(--muted); font-size: 12px; margin-top: 32px; }
@media (max-width: 700px) { body { padding: 12px; } td, th { padding: 5px; } .hide-sm { display: none; } }
'@
    $cls = @{
        Install = 's-ok'; Ready = 's-ok'; WithInstall = 's-ok'; Shared = 's-ok'; Recommended = 's-ok'
        Suggest = 's-info'; Manual = 's-info'; Info = 's-info'; Option = ''
        Check = 's-warn'; Hardware = 's-bad'; Skip = 's-bad'
        Installed = 's-dim'; Exists = 's-dim'; NotInstalled = 's-dim'; Leftover = 's-dim'; Retired = 's-dim'
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>PCMigrate Report</title><style>$css</style></head><body><main>")
    [void]$sb.Append("<h1>PCMigrate restore plan</h1><div class='sub'>" + (ConvertTo-PMHtml "$($pkg.Computer) -> $env:COMPUTERNAME  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  package $($pkg.Name)") + "</div>")

    [void]$sb.Append('<table>')
    [void]$sb.Append("<tr><td class='k'>Old PC</td><td>" + (ConvertTo-PMHtml (Format-PMProfileSummary $pkg.Source)) + '</td></tr>')
    [void]$sb.Append("<tr><td class='k'>This PC</td><td>" + (ConvertTo-PMHtml (Format-PMProfileSummary $target)) + '</td></tr>')
    [void]$sb.Append("<tr><td class='k'>Differences</td><td>" + ((@($diffs) | ForEach-Object { "<span class='pill'>" + (ConvertTo-PMHtml $_) + '</span>' }) -join '') + '</td></tr>')
    $sel = @($plan | Where-Object { $_.Selected })
    [void]$sb.Append("<tr><td class='k'>Selected</td><td>$($sel.Count) of $(@($plan).Count) items</td></tr>")
    if ($result) {
        $failedText = if ($result.Failed.Count) { (ConvertTo-PMHtml ($result.Failed -join '; ')) } else { 'none' }
        [void]$sb.Append("<tr><td class='k'>Result</td><td>Restored. Problems: $failedText<br><span class='note'>Undo data: " + (ConvertTo-PMHtml $result.Session) + '</span></td></tr>')
    }
    [void]$sb.Append('</table>')

    foreach ($g in $script:PMGroups) {
        $rows = @($plan | Where-Object { $_.Group -eq $g })
        if (-not $rows.Count) { continue }
        $n = @($rows | Where-Object { $_.Selected }).Count
        [void]$sb.Append("<h2>" + (ConvertTo-PMHtml $g) + " <span class='note'>($n of $($rows.Count) selected)</span></h2><table><tr><th class='sel'></th><th>Item</th><th>Status</th><th class='hide-sm'>Why</th></tr>")
        foreach ($it in $rows) {
            $mark = if ($it.Selected) { '&#10003;' } else { '' }
            $why = ConvertTo-PMHtml "$($it.Reason)"
            foreach ($note in $it.Notes) { $why += "<div class='note'>" + (ConvertTo-PMHtml $note) + '</div>' }
            if ($it.Data -and $it.Data.PathRefs -and $it.Data.PathRefs.Binary.Count) {
                $why += "<div class='note'>Binary files with old paths (not changed): " + (ConvertTo-PMHtml ((@($it.Data.PathRefs.Binary) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) + '</div>'
            }
            [void]$sb.Append("<tr><td class='sel'>$mark</td><td>" + (ConvertTo-PMHtml $it.Name) + "</td><td class='$($cls[$it.Status])'>" + (ConvertTo-PMHtml $it.Label) + "</td><td class='hide-sm'>$why</td></tr>")
        }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append("<footer>Generated by PCMigrate $script:PMVersion - by Brad Schrunk with Claude (Anthropic). MIT licence.</footer></main></body></html>")
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    return $path
}
