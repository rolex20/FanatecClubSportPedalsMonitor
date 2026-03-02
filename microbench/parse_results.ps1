#requires -version 5.1
<#
Parses results.txt created by:
  runall.bat > results.txt

Because march/mtune are paired (both none OR both same), we aggregate by:
  O + Arch

Winners reported by:
  - lowest median cycles/iter  (primary)
  - lowest median wall_us/iter (secondary)
  - lowest median cpu_ns/iter  (only meaningful if eff_GHz stable)

Usage:
  powershell -ExecutionPolicy Bypass -File .\Parse-Results.ps1 -Path .\results.txt
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$Path = 'results.txt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ToNumber([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = $s.Trim()
    if ($v -eq 'N/A') { return $null }
    $v = $v -replace ',', '.'
    return [double]$v
}

function GetMedian([double[]]$values) {
    if (-not $values -or $values.Count -eq 0) { return $null }
    $sorted = $values | Sort-Object
    $n = $sorted.Count
    if (($n % 2) -eq 1) {
        return $sorted[[int]($n/2)]
    } else {
        $hi = [int]($n/2)
        $lo = $hi - 1
        return ($sorted[$lo] + $sorted[$hi]) / 2.0
    }
}

function GetArch([string]$march, [string]$mtune) {
    $m = if ($march) { $march } else { 'none' }
    $t = if ($mtune) { $mtune } else { 'none' }

    if ($m -eq 'none' -and $t -eq 'none') { return 'none' }
    if ($m -eq $t) { return $m }
    return "$m/$t"  # should not happen with your rules, but keeps parser robust
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}

$runs = New-Object System.Collections.Generic.List[object]
$current = $null

$rxRun   = '^===RUN===\s+exe=(\S+)\s+O=(\S+)\s+march=(\S+)\s+mtune=(\S+)\s+run=(\S+)'
$rxHdr   = '^\[BenchSummary\]\s+iters=(\d+)\s+blocks=(\d+)\s+sleep_ms=(\d+)\s+dt_ms=(\d+)\s+report_every=(\d+)'
$rxCyc   = '^\[BenchSummary\]\s+cycles/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxCpu   = '^\[BenchSummary\]\s+cpu_ns/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxWall  = '^\[BenchSummary\]\s+wall_us/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)\s+min_iter_wall_us=(\S+)'
$rxEff   = '^\[BenchSummary\]\s+eff_GHz:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxEnd   = '^===ENDRUN==='

foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match $rxRun) {
        if ($current) { $runs.Add($current) }

        $march = $matches[3]
        $mtune = $matches[4]
        $arch = GetArch $march $mtune

        $current = [ordered]@{
            Exe        = $matches[1]
            O          = $matches[2]
            March      = $march
            Mtune      = $mtune
            Arch       = $arch
            RunIndex   = $matches[5]

            Iters      = $null
            Blocks     = $null
            SleepMs    = $null
            DtMs       = $null
            ReportEvery= $null

            CyclesMean = $null
            CyclesMedian = $null
            CyclesMinBlock = $null

            CpuMeanNs  = $null
            CpuMedianNs = $null
            CpuMinBlockNs = $null

            WallMeanUs = $null
            WallMedianUs = $null
            WallMinBlockUs = $null
            WallMinIterUs = $null

            EffMeanGhz = $null
            EffMedianGhz = $null
            EffMinBlockGhz = $null
        } | ForEach-Object { [pscustomobject]$_ }

        continue
    }

    if (-not $current) { continue }

    if ($line -match $rxHdr) {
        $current.Iters = [int]$matches[1]
        $current.Blocks = [int]$matches[2]
        $current.SleepMs = [int]$matches[3]
        $current.DtMs = [int]$matches[4]
        $current.ReportEvery = [int]$matches[5]
        continue
    }

    if ($line -match $rxCyc) {
        $current.CyclesMean = ToNumber $matches[1]
        $current.CyclesMedian = ToNumber $matches[2]
        $current.CyclesMinBlock = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxCpu) {
        $current.CpuMeanNs = ToNumber $matches[1]
        $current.CpuMedianNs = ToNumber $matches[2]
        $current.CpuMinBlockNs = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxWall) {
        $current.WallMeanUs = ToNumber $matches[1]
        $current.WallMedianUs = ToNumber $matches[2]
        $current.WallMinBlockUs = ToNumber $matches[3]
        $current.WallMinIterUs = ToNumber $matches[4]
        continue
    }

    if ($line -match $rxEff) {
        $current.EffMeanGhz = ToNumber $matches[1]
        $current.EffMedianGhz = ToNumber $matches[2]
        $current.EffMinBlockGhz = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxEnd) {
        continue
    }
}

if ($current) { $runs.Add($current) }

if ($runs.Count -eq 0) {
    Write-Host "No runs found in $Path"
    exit 1
}

Write-Host ("Parsed runs: {0}" -f $runs.Count)

# Group by O + Arch (march/mtune are paired)
$groups = $runs | Group-Object -Property @{Expression={ "{0}|{1}" -f $_.O, $_.Arch }}

$agg = foreach ($g in $groups) {
    $items = $g.Group
    $first = $items | Select-Object -First 1

    $cyclesMed = GetMedian ([double[]]($items | Where-Object { $_.CyclesMedian -ne $null } | ForEach-Object { $_.CyclesMedian }))
    $wallMed   = GetMedian ([double[]]($items | Where-Object { $_.WallMedianUs -ne $null } | ForEach-Object { $_.WallMedianUs }))
    $cpuMed    = GetMedian ([double[]]($items | Where-Object { $_.CpuMedianNs -ne $null } | ForEach-Object { $_.CpuMedianNs }))
    $effMed    = GetMedian ([double[]]($items | Where-Object { $_.EffMedianGhz -ne $null } | ForEach-Object { $_.EffMedianGhz }))

    [pscustomobject]@{
        Key   = $g.Name
        O     = $first.O
        Arch  = $first.Arch
        Runs  = $items.Count

        CyclesMedian = $cyclesMed
        WallMedianUs = $wallMed
        CpuMedianNs  = $cpuMed
        EffMedianGhz = $effMed
    }
}

function PickWinner($items, $propName) {
    $cand = $items | Where-Object { $_.$propName -ne $null } | Sort-Object -Property $propName, O, Arch
    return $cand | Select-Object -First 1
}

$wCycles = PickWinner $agg 'CyclesMedian'
$wWall   = PickWinner $agg 'WallMedianUs'
$wCpu    = PickWinner $agg 'CpuMedianNs'

Write-Host ""
Write-Host "Top 10 by median cycles/iter (primary):"
$agg | Where-Object { $_.CyclesMedian -ne $null } | Sort-Object CyclesMedian | Select-Object -First 10 |
    Format-Table O, Arch, Runs, CyclesMedian, WallMedianUs, CpuMedianNs, EffMedianGhz -AutoSize

Write-Host ""
Write-Host "Winners:"
if ($wCycles) { Write-Host ("  * Lowest median cycles/iter : O={0} arch={1}  cycles_med={2}" -f $wCycles.O, $wCycles.Arch, $wCycles.CyclesMedian) }
if ($wWall)   { Write-Host ("  * Lowest median wall_us/iter: O={0} arch={1}  wall_med={2}"   -f $wWall.O,   $wWall.Arch,   $wWall.WallMedianUs) }
if ($wCpu)    { Write-Host ("  * Lowest median cpu_ns/iter : O={0} arch={1}  cpu_med={2}"    -f $wCpu.O,    $wCpu.Arch,    $wCpu.CpuMedianNs) }

Write-Host ""
Write-Host "Note:"
Write-Host "  - Prefer cycles median as the main optimization winner."
Write-Host "  - wall_us median is a useful sanity check (scheduler noise)."
Write-Host "  - cpu_ns median is most meaningful if eff_GHz is stable across runs."

exit 0
