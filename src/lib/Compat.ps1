# ==============================================================================
# PCMigrate - Compat.ps1
# The compatibility engine. Decides, for each app or settings item, whether it
# makes sense on THIS PC:
#   - Is the app installed here? (fuzzy name matching + aliases)
#   - Does it need hardware this PC lacks? (rules: GPU, CPU, maker, chassis,
#     connected devices, printers)
#   - Is it something that should never be copied? (machine identity, adware)
#   - Notes worth knowing (licensed software, browser sync)
# Rules live in rules/compat-rules.json so anyone can extend them.
# Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
# ==============================================================================

# ----------------------------- Rules ------------------------------------------
function Read-PMRules([string]$Path) {
    $j = Read-PMJson $Path
    if (-not $j) { throw "Rules file not found or empty: $Path" }
    $aliases = @{}
    if ($j.aliases) {
        foreach ($p in $j.aliases.PSObject.Properties) { $aliases[$p.Name] = @($p.Value) }
    }
    $shared = @()
    if ($j.shared -and $j.shared.names) { $shared = @($j.shared.names) }
    return [pscustomobject]@{
        Aliases      = $aliases
        Shared       = $shared
        Rules        = @($j.rules)
        Suggest      = @($j.suggest)
        Alternatives = @($j.alternatives)
    }
}

# winget ID that can install an app the old PC had installed by hand (or $null).
function Get-PMWingetAlternative($rules, [string]$name) {
    foreach ($a in $rules.Alternatives) {
        if ($a -and (Test-PMLike $name $a.match)) { return "$($a.winget)" }
    }
    return $null
}

# Flattens a hardware profile into searchable text per requirement type.
function New-PMHardwareText($p) {
    $printers = @($p.Printers | ForEach-Object { "$($_.Name) $($_.Driver)" }) -join "`n"
    return @{
        gpu          = (@($p.Gpu) -join "`n")
        cpu          = ((@($p.Cpu) -join "`n") + "`n" + $p.CpuVendor)
        manufacturer = ("$($p.Manufacturer)`n$($p.Board)`n$($p.Model)")
        model        = "$($p.Model)"
        chassis      = "$($p.Chassis)"
        arch         = "$($p.Arch)"
        device       = (@($p.Devices) -join "`n")
        printer      = $printers
        os           = "$($p.OS) $($p.OSBuild)"
    }
}

# Evaluates a requirement object (regex values) against the hardware text.
# Supports { "anyOf": [ {...}, {...} ] } for alternatives.
function Test-PMRequirement($req, $hw) {
    if (-not $req) { return $true }
    foreach ($prop in $req.PSObject.Properties) {
        $k = $prop.Name; $v = $prop.Value
        if ($k -eq 'anyOf') {
            $ok = $false
            foreach ($alt in @($v)) { if (Test-PMRequirement $alt $hw) { $ok = $true; break } }
            if (-not $ok) { return $false }
            continue
        }
        if (-not $hw.ContainsKey($k)) { continue }
        if ($k -eq 'chassis') {
            # unknown chassis never blocks
            if ($hw.chassis -eq 'unknown') { continue }
            if ($hw.chassis -notmatch "^($v)$") { return $false }
            continue
        }
        if ($hw[$k] -notmatch "(?i)$v") { return $false }
    }
    return $true
}

# Runs every rule against the candidate names of one item.
# Kind: install | settings | checklist
# Returns @{ Status; Reason; Notes; RuleId } - Status is $null when no rule decided.
function Get-PMRuleVerdict($rules, [string[]]$candidates, [string]$kind, $hw, [string[]]$retired) {
    $notes = New-Object System.Collections.Generic.List[string]
    $status = $null; $reason = $null; $ruleId = $null
    $cands = @($candidates | Where-Object { $_ } | Select-Object -Unique)

    foreach ($c in $cands) {
        if (Test-PMLike $c $retired) {
            return @{ Status = 'Retired'; Reason = 'On your Retired list in PCMigrate.ini.'; Notes = @(); RuleId = 'retired' }
        }
    }

    foreach ($r in $rules.Rules) {
        if ($r.appliesTo -and (@($r.appliesTo) -notcontains $kind)) { continue }
        $hit = $false
        foreach ($c in $cands) {
            if ((Test-PMLike $c $r.match) -and -not (Test-PMLike $c $r.except)) { $hit = $true; break }
        }
        if (-not $hit) { continue }

        $action = if ($r.action) { "$($r.action)" } else { 'requires' }
        $verdict = $null
        switch ($action) {
            'note'     { if ($r.note -and -not $notes.Contains($r.note)) { $notes.Add($r.note) } }
            'skip'     { $verdict = 'Skip' }
            'optional' { $verdict = 'Option' }
            default {
                if (-not (Test-PMRequirement $r.requires $hw)) {
                    $verdict = if ($r.soft) { 'Check' } else { 'Hardware' }
                    if ($r.note -and -not $notes.Contains($r.note)) { $notes.Add($r.note) }
                }
            }
        }
        # Strongest verdict wins: Skip > Hardware > Check > Option
        if ($verdict -and ((-not $status) -or ($script:PMVerdictRank[$verdict] -lt $script:PMVerdictRank[$status]))) {
            $status = $verdict; $reason = $r.reason; $ruleId = $r.id
        }
    }
    return @{ Status = $status; Reason = $reason; Notes = @($notes); RuleId = $ruleId }
}
$script:PMVerdictRank = @{ Skip = 1; Hardware = 2; Check = 3; Option = 4 }

# ----------------------------- Program index ----------------------------------
# Builds a searchable index from uninstall entries (+ optional winget inventory).
function New-PMProgramIndex($programs, $wingetInventory) {
    $idByName = @{}
    foreach ($w in @($wingetInventory)) {
        if ($w.Name -and $w.Id -and $w.Source) { $idByName[(ConvertTo-PMKey $w.Name)] = $w.Id }
    }
    $index = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($programs)) {
        if (-not $p.Name) { continue }
        $loc = ''
        if ($p.InstallLocation) { $loc = Split-Path ("$($p.InstallLocation)".TrimEnd('\')) -Leaf }
        $key = ConvertTo-PMKey $p.Name
        $index.Add([pscustomobject]@{
            Name      = $p.Name
            Publisher = "$($p.Publisher)"
            Key       = $key
            PubKey    = ConvertTo-PMKey "$($p.Publisher)"
            LocKey    = ConvertTo-PMKey $loc
            NameLower = $p.Name.ToLowerInvariant()
            PubLower  = "$($p.Publisher)".ToLowerInvariant()
            WingetId  = $idByName[$key]
        })
    }
    return $index
}

# Finds programs in the index that a settings item (folder or vendor name) belongs to.
function Find-PMProgram($index, [string]$name, $aliases) {
    $found = New-Object System.Collections.Generic.List[object]
    if (-not $name) { return @() }

    if ($aliases -and $aliases.ContainsKey($name)) {
        foreach ($e in $index) { if (Test-PMLike $e.Name $aliases[$name]) { $found.Add($e) } }
        return $found.ToArray()
    }

    $key = ConvertTo-PMKey $name
    if ($key.Length -lt 2) { return @() }
    $word = [regex]('(?i)(^|[^a-z0-9])' + [regex]::Escape($name.ToLowerInvariant().Trim()) + '($|[^a-z0-9])')

    foreach ($e in $index) {
        $hit = $false
        if ($key.Length -le 4) {
            # short names: whole-word match only (avoids 'git' matching 'digiKam')
            if ($e.Key -eq $key -or $word.IsMatch($e.NameLower) -or $e.PubKey -eq $key -or $e.LocKey -eq $key) { $hit = $true }
        } else {
            if ($e.Key -and $e.Key.Contains($key))                        { $hit = $true }
            elseif ($e.Key.Length -ge 5 -and $key.Contains($e.Key))         { $hit = $true }
            elseif ($e.PubKey -and ($e.PubKey -eq $key))                    { $hit = $true }
            elseif ($e.PubKey.Length -ge 5 -and $e.PubKey.Contains($key))   { $hit = $true }
            elseif ($e.LocKey -and $e.LocKey -eq $key)                      { $hit = $true }
        }
        if ($hit) { $found.Add($e) }
    }
    return $found.ToArray()
}

# Is a named program (from the old PC) installed on this PC?
function Test-PMProgramInstalled($targetIndex, [string]$programName) {
    $key = ConvertTo-PMKey $programName
    if (-not $key) { return $null }
    foreach ($e in $targetIndex) {
        if ($e.Key -eq $key) { return $e }
        if ($key.Length -ge 5 -and $e.Key.Length -ge 5 -and ($e.Key.StartsWith($key) -or $key.StartsWith($e.Key))) { return $e }
    }
    return $null
}

# ----------------------------- Suggestions ------------------------------------
function Get-PMSuggestions($rules, $hw, $installedIds, $targetIndex) {
    $out = @()
    foreach ($s in $rules.Suggest) {
        if (-not (Test-PMRequirement $s.when $hw)) { continue }
        $have = $false
        if ($s.winget -and $installedIds -and $installedIds.Contains($s.winget)) { $have = $true }
        if (-not $have -and (Test-PMProgramInstalled $targetIndex $s.name)) { $have = $true }
        $out += [pscustomobject]@{ Name = $s.name; Winget = $s.winget; Note = $s.note; Installed = $have }
    }
    return $out
}
