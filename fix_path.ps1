# ===== CONFIG =====
$MaxLength = 2000                  # Max safe length for master PATH before overflow into PB4
$PBvars    = "PB1","PB2","PB3","PB4"

# ===== Helpers =====
function Normalize-PathLike([string]$s) {
    if (-not $s) { return "" }
    return ($s.Trim().Trim('"').TrimEnd('\')).ToLower()
}

function Get-EnvVariableMap {
    # Map of normalized expanded path -> %VARNAME%
    $map = @{}
    Get-ChildItem Env: | ForEach-Object {
        $name  = $_.Name
        $value = $_.Value
        if ($value -and $value -notmatch ";") {
            $norm = Normalize-PathLike $value
            if ($norm -and -not $map.ContainsKey($norm)) {
                $map[$norm] = "%$name%"
            }
        }
    }
    return $map
}

function Is-VarRef { param([string]$s)
    # treat %NAME% and %NAME%\sub\path (optionally quoted) as protected
    $t = $s.Trim() -replace '^"+|"+$',''
    return $t -match '^%[0-9A-Za-z_()]+%(\\.*)?$'
}

function Clean-PathString {
    param([string]$pathString)
    if (-not $pathString) { return "" }

    $varMap = Get-EnvVariableMap
    $seen   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $out    = New-Object System.Collections.Generic.List[string]

    foreach ($raw in ($pathString -split ';')) {
        $piece = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($piece)) { continue }

        $norm = Normalize-PathLike $piece

        # replace exact expansions with %VAR% if we have a map
        if ($varMap.ContainsKey($norm)) {
            $piece = $varMap[$norm]
        }

        # stable de-dupe
        if ($seen.Add($piece)) {
            [void]$out.Add($piece)
        }
    }

    return ($out -join ';')
}

function Distribute-ToPB {
    param(
        [string[]]$items,
        [string[]]$pbNames
    )
    # Greedy length balancing while preserving relative order
    $buckets = @{}
    $lens    = @{}
    foreach ($pb in $pbNames) {
        $buckets[$pb] = New-Object System.Collections.Generic.List[string]
        $lens[$pb] = 0
    }

    foreach ($it in $items) {
        $target = $pbNames | Sort-Object { $lens[$_] } | Select-Object -First 1
        $b = $buckets[$target]
        $sep = ($b.Count -gt 0) ? 1 : 0
        [void]$b.Add($it)
        $lens[$target] += $it.Length + $sep
    }
    return $buckets
}

# ===== STEP 1: Ensure PB vars exist =====
foreach ($pb in $PBvars) {
    $val = [Environment]::GetEnvironmentVariable($pb, "User")
    if ($null -eq $val) {
        [Environment]::SetEnvironmentVariable($pb, "", "User")
        Write-Host "Created missing $pb (empty)"
    }
}

# ===== STEP 2: Clean each PB var and strip PB placeholders =====
$pbRefPattern = '^\s*%PB[1-4]%(\\.*)?\s*$'  # drop %PBx% & %PBx%\sub\path
foreach ($pb in $PBvars) {
    $val = [Environment]::GetEnvironmentVariable($pb, "User")
    $cleaned = Clean-PathString $val
    $entries =
        $cleaned -split ';' |
        Where-Object { $_ -and $_.Trim() -ne "" } |
        Where-Object { $_ -notmatch $pbRefPattern }
    $final = ($entries -join ';').Trim(';')
    [Environment]::SetEnvironmentVariable($pb, $final, "User")
    Write-Host "$pb cleaned: $final`n"
}

# ===== STEP 3: Clean master PATH (stable order) =====
$origPath  = [Environment]::GetEnvironmentVariable("Path", "User")
$cleanPath = Clean-PathString $origPath

# ===== STEP 4: Inject PB block, removing entries already housed in PBs =====
# Build set of normalized entries currently in PBs
$pbEntries = New-Object 'System.Collections.Generic.List[string]'
foreach ($pb in $PBvars) {
    $v = [Environment]::GetEnvironmentVariable($pb, "User")
    if ($v) {
        $parts = $v -split ';' | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { [string]$_ }
        [void]$pbEntries.AddRange([string[]]$parts)
    }
}
$pbSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $pbEntries) {
    $n = Normalize-PathLike $e
    if ($n) { [void]$pbSet.Add($n) }
}

$pbPlaceholders   = $PBvars | ForEach-Object { "%$_%" }
$placeholderRegex = [string]::Join('|', ($pbPlaceholders | ForEach-Object { [Regex]::Escape($_) }))

$baseEntries =
    $cleanPath -split ';' |
    Where-Object { $_ -and $_.Trim() -ne "" } |
    Where-Object {
        $n = Normalize-PathLike $_
        (-not $pbSet.Contains($n)) -and ($_ -notmatch $placeholderRegex)
    }

$pbBlock = ($pbPlaceholders -join ';')
$newPath = (($baseEntries -join ';') + ';' + $pbBlock).Trim(';')

# Sanity note if protected-only > MaxLength
$entriesForCheck = $newPath -split ';' | Where-Object { $_ -and $_.Trim() -ne "" }
$protectedOnly = $entriesForCheck | Where-Object { Is-VarRef $_ }
$minProtectedLen = ($protectedOnly -join ';').Length
if ($minProtectedLen -gt $MaxLength) {
    Write-Host "NOTE: Protected entries alone are $minProtectedLen chars (> $MaxLength). Consider increasing \$MaxLength (e.g. 4096)."
}

# ===== STEP 5: Overflow handling (right-to-left), protect var-based =====
$overflowList = New-Object System.Collections.Generic.List[string]
if ($newPath.Length -gt $MaxLength) {
    Write-Host "PATH exceeds $MaxLength chars, moving only non-variable, lower-priority items into PB pool until under limit..."
    $entries = $newPath -split ';' | Where-Object { $_ -and $_.Trim() -ne "" }

    $keep = New-Object System.Collections.Generic.List[string]
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i].Trim()
        if (Is-VarRef $e) {
            $keep.Insert(0, $entries[$i]);  continue
        }
        $candidate = if ($keep.Count -gt 0) { ($keep -join ';') + ';' + $entries[$i] } else { $entries[$i] }
        if ($candidate.Length -le $MaxLength) {
            $keep.Insert(0, $entries[$i])
        } else {
            $overflowList.Insert(0, $entries[$i])
        }
    }

    $newPath = ($keep -join ';')
}

# ===== STEP 5B: Build PB pool (PBs ∪ overflow), substitute, de-dupe, rebalance =====
# Collect entries currently in PBs
$poolRaw = New-Object 'System.Collections.Generic.List[string]'
foreach ($pb in $PBvars) {
    $v = [Environment]::GetEnvironmentVariable($pb,'User')
    if ($v) {
        $parts = $v -split ';' | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { [string]$_ }
        [void]$poolRaw.AddRange([string[]]$parts)
    }
}
# Add overflow from PATH (if any)
if ($overflowList.Count -gt 0) {
    [void]$poolRaw.AddRange([string[]]$overflowList)
}

# Drop %PBx% refs, stable unique by normalized value, and run substitution on each
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$pool = New-Object System.Collections.Generic.List[string]
foreach ($e in $poolRaw) {
    $t = $e.Trim()
    if ($t -match '^\s*%PB[1-4]%(\\.*)?\s*$') { continue }
    $n = Normalize-PathLike $t
    if ($n -and $seen.Add($n)) {
        $subbed = Clean-PathString $t
        if ($subbed -match ';') {
            $parts = $subbed -split ';' | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { [string]$_ }
            [void]$pool.AddRange([string[]]$parts)
        } elseif ($subbed) {
            [void]$pool.Add([string]$subbed)
        }
    }
}

# Rebalance into PB1..PB4
$buckets = Distribute-ToPB -items ([string[]]$pool) -pbNames $PBvars
foreach ($pb in $PBvars) {
    $val = ($buckets[$pb] -join ';').Trim(';')
    $final = Clean-PathString $val
    [Environment]::SetEnvironmentVariable($pb, $final, 'User')
    Write-Host "$pb packed: $final"
}
Write-Host ""

# ===== STEP 6: Save master PATH =====
$newPath = Clean-PathString $newPath
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")
Write-Host "Master PATH updated:`n$newPath`n"
Write-Host "Done! You can run this anytime to restore order."
