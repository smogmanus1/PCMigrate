# ==============================================================================
# PCMigrate - PathScan.ps1
# Finds absolute paths saved inside app settings (F:\Dropbox\..., S:\Backups,
# C:\Users\olduser\...), works out what each one means on THIS PC, and fixes them:
#   - Map a missing drive letter back (junction + DOS device, no files moved)
#   - Rewrite paths inside text settings files and .reg files
# Handles plain, JSON-escaped (\\) and forward-slash forms, in UTF-8 / UTF-16.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

$script:PMSkipExt = '\.(exe|dll|sys|ocx|cab|msi|png|jpe?g|gif|ico|bmp|webp|tiff?|svg|mp[34]|m4a|wav|flac|ogg|avi|mkv|mov|zip|7z|rar|gz|pak|bin|woff2?|ttf|otf|pdf|docx?|xlsx?|pptx?|jar|pyc|node|wasm|asar)$'
$script:PMDriveRx = [regex]'(?i)(?<![A-Za-z0-9.])(?<!(?<!/)/)([A-Z]):(?:\\\\|\\|/)+([^\\/:*?"<>|\x00-\x1F]{1,64}?)(?=\\|/|["''\r\n<]|$)'

# Scans one settings item (a folder or a single file).
# Returns @{ Roots = @{ 'F:\Dropbox' = n }; User = n; Files = [list of @{ Path; Enc; Hit }]; Binary = [list of paths] }
function Find-PMPathRefs([string]$itemPath, [string]$oldProfile) {
    $result = @{
        Roots  = @{}
        User   = 0
        Files  = New-Object System.Collections.Generic.List[object]
        Binary = New-Object System.Collections.Generic.List[string]
    }
    if (-not (Test-Path -LiteralPath $itemPath)) { return $result }
    $userRx = $null
    if ($oldProfile) { $userRx = New-PMPathRegex $oldProfile }

    $item = Get-Item -LiteralPath $itemPath -Force
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $itemPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                 Where-Object { $_.Length -gt 0 -and $_.Length -lt 5MB -and $_.Name -notmatch $script:PMSkipExt }
    } else { $files = @($item) }

    foreach ($f in $files) {
        try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { continue }
        $enc = Get-PMTextEncoding $bytes
        if ($enc) {
            $text = Read-PMText $bytes $enc
        } else {
            if ($bytes.Length -gt 1MB) { continue }
            # binary: look for paths in both 8-bit and UTF-16 form, report only
            $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes) + "`n" + [Text.Encoding]::Unicode.GetString($bytes)
        }
        $hit = $false
        foreach ($m in $script:PMDriveRx.Matches($text)) {
            $letter = $m.Groups[1].Value.ToUpperInvariant()
            if ($letter -eq 'C') { continue }
            $top = $m.Groups[2].Value.Trim()
            if (-not $top -or $top.Contains('%') -or $top.StartsWith('.')) { continue }
            if ($top.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
            # in binary files random bytes can look like 'D:\...' - accept only plain, readable folder names there
            if (-not $enc -and $top -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.()&+,!#$@~''-]*$') { continue }
            # a file at the root of the drive (nothing follows it) - only the letter matters
            $end = $m.Index + $m.Length
            $next = if ($end -lt $text.Length) { $text[$end] } else { '' }
            if ($next -ne '\' -and $next -ne '/' -and $top -match '\.[A-Za-z0-9]{2,5}$') { $top = '' }
            $root = "${letter}:\$top"
            if ($result.Roots.ContainsKey($root)) { $result.Roots[$root]++ } else { $result.Roots[$root] = 1 }
            $hit = $true
        }
        if ($userRx) {
            $n = $userRx.Matches($text).Count
            if ($n) { $result.User += $n; $hit = $true }
        }
        if ($hit) {
            if ($enc) { $result.Files.Add(@{ Path = $f.FullName; Enc = $enc }) }
            else      { $result.Binary.Add($f.FullName) }
        }
    }
    return $result
}

# Works out what an old-PC path root (e.g. 'F:\Dropbox') means on this PC.
# State: OK | Mappable | Rewrite | Missing | DriveMissing
function Resolve-PMPathRoot([string]$root, $target, $source, [string[]]$reserved, [string[]]$netLetters) {
    $letter = $root.Substring(0, 1).ToUpperInvariant()
    $top    = $root.Substring(3)   # empty = the drive root itself
    $res = [ordered]@{ Root = $root; Letter = $letter; Top = $top; State = ''; Target = ''; Note = ''; Certain = $false }

    if (Test-PMPathSafe $root) { $res.State = 'OK'; $res.Target = $root; return [pscustomobject]$res }
    if ($netLetters -contains $letter) {
        $res.State = 'Network'
        $res.Note  = "Drive ${letter}: is a network drive - these paths work once that network drive is connected (see the 'Network drive ${letter}:' item)."
        return [pscustomobject]$res
    }

    $letterExists = $false
    foreach ($d in @($target.Drives)) { if ("$($d.Letter)".ToUpperInvariant() -eq "${letter}:") { $letterExists = $true } }
    if (-not $letterExists -and (Test-PMPathSafe "${letter}:\")) { $letterExists = $true }
    # letters mapped to network shares or DOS devices count as taken (an elevated process can't see them)
    if (-not $letterExists -and ($reserved -contains $letter)) { $letterExists = $true }

    if (-not $top) {
        $res.State = if ($letterExists) { 'Missing' } else { 'DriveMissing' }
        $res.Note  = if ($letterExists) { "Files saved at the root of ${letter}: - check they exist here." } else { "Drive ${letter}: is not on this PC - only recent-file entries point there." }
        return [pscustomobject]$res
    }

    # Same disk under another letter on the old PC (e.g. E: and F: were one drive)? Map the letter to that drive.
    if (-not $letterExists -and $source) {
        $sd = @($source.Drives | Where-Object { "$($_.Letter)".ToUpperInvariant() -eq "${letter}:" }) | Select-Object -First 1
        if ($sd -and $sd.SizeGB) {
            # Same volume serial = certainly the same disk. Without serials (older captures) fall back to a
            # non-empty label + size match, which is only a guess - the plan then leaves it unticked.
            $twins = @($source.Drives | Where-Object { $_.Letter -ne $sd.Letter -and (
                ($sd.Serial -and $_.Serial -eq $sd.Serial) -or
                (-not $sd.Serial -and $sd.Label -and $_.Label -eq $sd.Label -and $_.SizeGB -eq $sd.SizeGB -and $_.Type -eq $sd.Type) ) })
            $res.Certain = [bool]$sd.Serial
            foreach ($tw in $twins) {
                $k = "$($tw.Letter)".Substring(0, 1).ToUpperInvariant()
                if (Test-PMPathSafe "${k}:\$top") {
                    $res.State = 'Alias'; $res.Target = "${k}:\"
                    $res.Note = "On the old PC ${letter}: and ${k}: were the same disk - ${letter}: becomes another name for ${k}: here."
                    return [pscustomobject]$res
                }
            }
        }
    }

    # Find the equivalent folder on this PC
    $cands = @()
    if ($source -and $source.Dropbox -and ($source.Dropbox.TrimEnd('\') -ieq $root) -and $target.Dropbox) { $cands += $target.Dropbox }
    if ($source -and $source.OneDrive -and ($source.OneDrive.TrimEnd('\') -ieq $root) -and $target.OneDrive) { $cands += $target.OneDrive }
    if ($target.Dropbox  -and ((Split-Path $target.Dropbox  -Leaf) -ieq $top)) { $cands += $target.Dropbox }
    if ($target.OneDrive -and ((Split-Path $target.OneDrive -Leaf) -ieq $top)) { $cands += $target.OneDrive }
    $cands += (Join-Path $target.UserProfile $top)
    foreach ($d in @($target.Drives | Where-Object { $_.Type -eq 'Fixed' })) { $cands += "$($d.Letter)\$top" }

    $found = $null
    foreach ($c in $cands) { if ($c -and (Test-PMPathSafe $c)) { $found = $c; break } }

    if ($found) {
        $res.Target = $found
        if ($letterExists) {
            $res.State = 'Rewrite'
            $res.Note  = "Drive ${letter}: is used for something else here - paths will be rewritten to $found."
        } else {
            $res.State = 'Mappable'
            $res.Note  = "Found here as $found."
        }
    } else {
        if ($letterExists) {
            $res.State = 'Missing'
            $res.Note  = "Drive ${letter}: exists here but has no '$top' folder."
        } else {
            $label = ''
            if ($source) {
                $sd = @($source.Drives | Where-Object { "$($_.Letter)".ToUpperInvariant() -eq "${letter}:" }) | Select-Object -First 1
                if ($sd) { $label = " (on the old PC: $($sd.Type) drive '$($sd.Label)', $($sd.SizeGB) GB)" }
            }
            $res.State = 'DriveMissing'
            $res.Note  = "Drive ${letter}: is not on this PC$label - fine if it is an external drive you will plug in."
        }
    }
    return [pscustomobject]$res
}

# Exists check that never throws (odd characters just mean 'no').
function Test-PMPathSafe([string]$p) {
    if (-not $p) { return $false }
    try { return ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) } catch { return $false }
}

# ----------------------------- Rewriting --------------------------------------
# Builds a regex for an old path that tolerates \  \\  and / separators.
function New-PMPathRegex([string]$from) {
    $parts = $from.TrimEnd('\') -split '\\'
    $first = [regex]::Escape($parts[0])
    $rest  = @($parts | Select-Object -Skip 1 | ForEach-Object { [regex]::Escape($_) })
    $pattern = '(?i)(?<![A-Za-z0-9])' + $first
    if ($rest.Count -gt 0) {
        $pattern += '(\\\\|\\|/)' + ($rest -join '(?:\\\\|\\|/)')
    }
    $pattern += '(?![A-Za-z0-9._-])'
    return [regex]$pattern
}

# Applies a list of @{ From; To } translations to text, keeping the separator style.
function Convert-PMPathText([string]$text, $translations) {
    $changed = 0
    foreach ($t in @($translations)) {
        $rx = New-PMPathRegex $t.From
        $to = $t.To.TrimEnd('\')
        $text = $rx.Replace($text, [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            $sep = '\'
            if ($m.Groups.Count -gt 1 -and $m.Groups[1].Success) { $sep = $m.Groups[1].Value }
            $script:PMRewriteCount++
            return $to.Replace('\', $sep)
        })
    }
    return $text
}

# Rewrites one text file in place (same encoding). Returns number of replacements.
function Update-PMFilePaths([string]$path, [string]$enc, $translations) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $bytes = [IO.File]::ReadAllBytes($path)
    if (-not $enc) { $enc = Get-PMTextEncoding $bytes }
    if (-not $enc) { return 0 }
    # ANSI files can only take new paths made of Latin-1 characters; otherwise leave the file alone
    if ($enc -eq 'ansi' -and (@($translations) | Where-Object { $_.To -match '[^\x00-\xFF]' })) { return 0 }
    $text = Read-PMText $bytes $enc
    $script:PMRewriteCount = 0
    $new = Convert-PMPathText $text $translations
    if ($script:PMRewriteCount -gt 0) { Write-PMText $path $new $enc }
    return $script:PMRewriteCount
}
