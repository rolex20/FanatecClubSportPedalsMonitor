#requires -version 5.1
param(
    [Parameter(Mandatory=$false)]
    [string]$Path = 'results.txt'
)
$ErrorActionPreference = 'Stop'
function ToNumber([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = $s.Trim()
    if ($v -eq 'N/A') { return $null }
    $v = $v -replace ',', '.'
    try { return [double]$v } catch { return $null }
}

function GetMedian($values) {
    # Build a real array (never scalar), ignore nulls
    $arr = @()
    foreach ($v in @($values)) {
        if ($null -ne $v) { $arr += [double]$v }
    }
    if ($arr.Count -eq 0) { return $null }

    $sorted = $arr | Sort-Object
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
    $m = if ([string]::IsNullOrWhiteSpace($march)) { 'none' } else { $march }
    $t = if ([string]::IsNullOrWhiteSpace($mtune)) { 'none' } else { $mtune }
    if ($m -eq 'none' -and $t -eq 'none') { return 'none' }
    if ($m -eq $t) { return $m }
    return "$m/$t"  # shouldn't happen with your paired rule, but stays robust
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}

# Regexes (match your output)
$rxRun   = '^===RUN===\s+exe=(\S+)\s+O=(\S+)\s+march=(\S+)\s+mtune=(\S+)\s+run=(\S+)'
$rxHdr   = '^\[BenchSummary\]\s+iters=(\d+)\s+blocks=(\d+)\s+sleep_ms=(\d+)\s+dt_ms=(\d+)\s+report_every=(\d+)'
$rxCyc   = '^\[BenchSummary\]\s+cycles/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxCpu   = '^\[BenchSummary\]\s+cpu_ns/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxWall  = '^\[BenchSummary\]\s+wall_us/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)\s+min_iter_wall_us=(\S+)'
$rxEff   = '^\[BenchSummary\]\s+eff_GHz:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'

$runs = @()
$current = $null

foreach ($line in Get-Content -LiteralPath $Path) {

    if ($line -match $rxRun) {
        if ($null -ne $current) { $runs += $current }

        $exe   = $matches[1]
        $o     = $matches[2]
        $march = $matches[3]
        $mtune = $matches[4]
        $runIx = $matches[5]
        $arch  = GetArch $march $mtune

        $current = [pscustomobject]@{
            Exe=$exe; O=$o; March=$march; Mtune=$mtune; Arch=$arch; RunIndex=$runIx

            Iters=$null; Blocks=$null; SleepMs=$null; DtMs=$null; ReportEvery=$null

            CyclesMean=$null; CyclesMedian=$null; CyclesMinBlock=$null
            CpuMeanNs=$null;  CpuMedianNs=$null;  CpuMinBlockNs=$null
            WallMeanUs=$null; WallMedianUs=$null; WallMinBlockUs=$null; WallMinIterUs=$null
            EffMeanGhz=$null; EffMedianGhz=$null; EffMinBlockGhz=$null
        }
        continue
    }

    if ($null -eq $current) { continue }

    if ($line -match $rxHdr) {
        $current.Iters = [int]$matches[1]
        $current.Blocks = [int]$matches[2]
        $current.SleepMs = [int]$matches[3]
        $current.DtMs = [int]$matches[4]
        $current.ReportEvery = [int]$matches[5]
        continue
    }

    if ($line -match $rxCyc) {
        $current.CyclesMean    = ToNumber $matches[1]
        $current.CyclesMedian  = ToNumber $matches[2]
        $current.CyclesMinBlock= ToNumber $matches[3]
        continue
    }

    if ($line -match $rxCpu) {
        $current.CpuMeanNs     = ToNumber $matches[1]
        $current.CpuMedianNs   = ToNumber $matches[2]
        $current.CpuMinBlockNs = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxWall) {
        $current.WallMeanUs    = ToNumber $matches[1]
        $current.WallMedianUs  = ToNumber $matches[2]
        $current.WallMinBlockUs= ToNumber $matches[3]
        $current.WallMinIterUs = ToNumber $matches[4]
        continue
    }

    if ($line -match $rxEff) {
        $current.EffMeanGhz    = ToNumber $matches[1]
        $current.EffMedianGhz  = ToNumber $matches[2]
        $current.EffMinBlockGhz= ToNumber $matches[3]
        continue
    }
}

if ($null -ne $current) { $runs += $current }

Write-Host ("Parsed runs: {0}" -f $runs.Count)
if ($runs.Count -eq 0) { exit 1 }

# Group by O + Arch (paired march/mtune)
$groups = $runs | Group-Object -Property @{Expression={ "{0}|{1}" -f $_.O, $_.Arch }}

$agg = @()
foreach ($g in $groups) {
    $items = @($g.Group)
    $first = $items[0]

    $cyclesMed = GetMedian ($items | ForEach-Object { $_.CyclesMedian })
    $wallMed   = GetMedian ($items | ForEach-Object { $_.WallMedianUs })
    $cpuMed    = GetMedian ($items | ForEach-Object { $_.CpuMedianNs })
    $effMed    = GetMedian ($items | ForEach-Object { $_.EffMedianGhz })

    $agg += [pscustomobject]@{
        O=$first.O
        Arch=$first.Arch
        Runs=$items.Count
        CyclesMedian=$cyclesMed
        WallMedianUs=$wallMed
        CpuMedianNs=$cpuMed
        EffMedianGhz=$effMed
    }
}

function PickWinner($items, $prop) {
    $cand = @($items | Where-Object { $null -ne $_.$prop } | Sort-Object -Property $prop, O, Arch)
    if ($cand.Count -eq 0) { return $null }
    return $cand[0]
}

$wCycles = PickWinner $agg 'CyclesMedian'
$wWall   = PickWinner $agg 'WallMedianUs'
$wCpu    = PickWinner $agg 'CpuMedianNs'

Write-Host ""
Write-Host "Top by median cycles/iter (primary):"
$agg | Where-Object { $null -ne $_.CyclesMedian } | Sort-Object CyclesMedian |
    Format-Table O, Arch, Runs, CyclesMedian, WallMedianUs, CpuMedianNs, EffMedianGhz -AutoSize

Write-Host ""
Write-Host "Winners:"
if ($wCycles) { Write-Host ("  * Lowest median cycles/iter : O={0} arch={1} cycles_med={2}" -f $wCycles.O, $wCycles.Arch, $wCycles.CyclesMedian) }
if ($wWall)   { Write-Host ("  * Lowest median wall_us/iter: O={0} arch={1} wall_med={2}"   -f $wWall.O,   $wWall.Arch,   $wWall.WallMedianUs) }
if ($wCpu)    { Write-Host ("  * Lowest median cpu_ns/iter : O={0} arch={1} cpu_med={2}"    -f $wCpu.O,    $wCpu.Arch,    $wCpu.CpuMedianNs) }

Write-Host ""
Write-Host "Note:"
Write-Host "  - Prefer cycles median as the main optimization winner."
Write-Host "  - wall_us median is a useful sanity check (scheduler noise)."
Write-Host "  - cpu_ns median may be 0.00 for small blocks due to GetThreadTimes granularity; increase report_every if needed."

exit 0
