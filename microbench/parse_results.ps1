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

function ToInt64([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = $s.Trim()
    if ($v -eq 'N/A') { return $null }
    try { return [int64]$v } catch { return $null }
}

function ToUInt64([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = $s.Trim()
    if ($v -eq 'N/A') { return $null }
    try { return [uint64]$v } catch { return $null }
}

function GetMedian($values) {
    $arr = @()
    foreach ($v in @($values)) {
        if ($null -ne $v) { $arr += [double]$v }
    }
    if ($arr.Count -eq 0) { return $null }
    $sorted = $arr | Sort-Object
    $n = $sorted.Count
    if (($n % 2) -eq 1) { return $sorted[[int]($n/2)] }
    $hi = [int]($n/2); $lo = $hi - 1
    return ($sorted[$lo] + $sorted[$hi]) / 2.0
}

function GetMin($values) {
    $arr = @()
    foreach ($v in @($values)) {
        if ($null -ne $v) { $arr += [double]$v }
    }
    if ($arr.Count -eq 0) { return $null }
    return ($arr | Measure-Object -Minimum).Minimum
}

function GetArch([string]$march, [string]$mtune) {
    $m = if ([string]::IsNullOrWhiteSpace($march)) { 'none' } else { $march }
    $t = if ([string]::IsNullOrWhiteSpace($mtune)) { 'none' } else { $mtune }
    if ($m -eq 'none' -and $t -eq 'none') { return 'none' }
    if ($m -eq $t) { return $m }
    return "$m/$t"
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}

# Markers + summary lines
$rxRun   = '^===RUN===\s+exe=(\S+)\s+O=(\S+)\s+march=(\S+)\s+mtune=(\S+)\s+run=(\S+)'
$rxHdr   = '^\[BenchSummary\]\s+iters=(\d+)\s+blocks=(\d+)\s+sleep_ms=(\d+)\s+dt_ms=(\d+)\s+report_every=(\d+)'
$rxCyc   = '^\[BenchSummary\]\s+cycles/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxCpu   = '^\[BenchSummary\]\s+cpu_ns/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
$rxWall  = '^\[BenchSummary\]\s+wall_us/iter:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)\s+min_iter_wall_us=(\S+)'
$rxEff   = '^\[BenchSummary\]\s+eff_GHz:\s+mean=(\S+)\s+median=(\S+)\s+min_block=(\S+)'
# NEW: raw min-tick stats line
$rxWallIterMin = '^\[BenchSummary\]\s+wall_iter_min:\s+min_iter_wall_ticks=(\S+)\s+min_iter_wall_ticks_count=(\S+)\s+min_iter_wall_ticks_pct=(\S+)\s+qpc_freq=(\S+)'

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

            CyclesMean=$null;   CyclesMedian=$null;   CyclesMinBlock=$null
            CpuMeanNs=$null;    CpuMedianNs=$null;    CpuMinBlockNs=$null
            WallMeanUs=$null;   WallMedianUs=$null;   WallMinBlockUs=$null; WallMinIterUs=$null
            EffMeanGhz=$null;   EffMedianGhz=$null;   EffMinBlockGhz=$null

            # NEW: per-run min-iteration tick diagnostics
            MinIterWallTicks=$null
            MinIterWallTicksCount=$null
            MinIterWallTicksPct=$null
            QpcFreq=$null
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
        $current.CyclesMean     = ToNumber $matches[1]
        $current.CyclesMedian   = ToNumber $matches[2]
        $current.CyclesMinBlock = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxCpu) {
        $current.CpuMeanNs      = ToNumber $matches[1]
        $current.CpuMedianNs    = ToNumber $matches[2]
        $current.CpuMinBlockNs  = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxWall) {
        $current.WallMeanUs     = ToNumber $matches[1]
        $current.WallMedianUs   = ToNumber $matches[2]
        $current.WallMinBlockUs = ToNumber $matches[3]
        $current.WallMinIterUs  = ToNumber $matches[4]
        continue
    }

    if ($line -match $rxEff) {
        $current.EffMeanGhz     = ToNumber $matches[1]
        $current.EffMedianGhz   = ToNumber $matches[2]
        $current.EffMinBlockGhz = ToNumber $matches[3]
        continue
    }

    if ($line -match $rxWallIterMin) {
        $current.MinIterWallTicks      = ToInt64  $matches[1]
        $current.MinIterWallTicksCount = ToUInt64 $matches[2]
        $current.MinIterWallTicksPct   = ToNumber $matches[3]
        $current.QpcFreq               = ToInt64  $matches[4]
        continue
    }
}

if ($null -ne $current) { $runs += $current }

Write-Host ("Parsed runs: {0}" -f $runs.Count)
if ($runs.Count -eq 0) { exit 1 }

# Group by O + Arch
$groups = $runs | Group-Object -Property @{Expression={ "{0}|{1}" -f $_.O, $_.Arch }}

$agg = @()
foreach ($g in $groups) {
    $items = @($g.Group)
    $first = $items[0]

    # Median-of-medians across runs (robust)
    $cyclesMed = GetMedian ($items | ForEach-Object { $_.CyclesMedian })
    $wallMed   = GetMedian ($items | ForEach-Object { $_.WallMedianUs })
    $cpuMed    = GetMedian ($items | ForEach-Object { $_.CpuMedianNs })
    $effMed    = GetMedian ($items | ForEach-Object { $_.EffMedianGhz })

    # Best sustained block across runs
    $minBlockCycles = GetMin ($items | ForEach-Object { $_.CyclesMinBlock })
    $minBlockWall   = GetMin ($items | ForEach-Object { $_.WallMinBlockUs })
    $minBlockCpu    = GetMin ($items | ForEach-Object { $_.CpuMinBlockNs })

    # NEW: tie-breaker stats (median across runs)
    $minIterTicksMed = GetMedian ($items | ForEach-Object { $_.MinIterWallTicks })
    $minIterPctMed   = GetMedian ($items | ForEach-Object { $_.MinIterWallTicksPct })

    $agg += [pscustomobject]@{
        O=$first.O
        Arch=$first.Arch
        Runs=$items.Count

        CyclesMedian=$cyclesMed
        WallMedianUs=$wallMed
        CpuMedianNs=$cpuMed
        EffMedianGhz=$effMed

        MinBlockCycles=$minBlockCycles
        MinBlockWallUs=$minBlockWall
        MinBlockCpuNs=$minBlockCpu

        MinIterWallTicksMedian=$minIterTicksMed
        MinIterWallTicksPctMedian=$minIterPctMed
    }
}

function PickWinner($items, $prop, [switch]$RequirePositive) {
    $cand = @()
    foreach ($x in $items) {
        $v = $x.$prop
        if ($null -eq $v) { continue }
        if ($RequirePositive -and ($v -le 0)) { continue }
        $cand += $x
    }
    if ($cand.Count -eq 0) { return $null }
    return @($cand | Sort-Object -Property $prop, O, Arch)[0]
}

# Primary winners (medians)
$wCycles = PickWinner $agg 'CyclesMedian'
$wWall   = PickWinner $agg 'WallMedianUs'
$wCpu    = PickWinner $agg 'CpuMedianNs' -RequirePositive

# Best sustained block winners
$wMinBlkCycles = PickWinner $agg 'MinBlockCycles'
$wMinBlkWall   = PickWinner $agg 'MinBlockWallUs'
$wMinBlkCpu    = PickWinner $agg 'MinBlockCpuNs' -RequirePositive

Write-Host ""
Write-Host "Top by median cycles/iter (primary):"
$agg | Where-Object { $null -ne $_.CyclesMedian } | Sort-Object CyclesMedian |
    Format-Table O, Arch, Runs, CyclesMedian, WallMedianUs, CpuMedianNs, EffMedianGhz -AutoSize

Write-Host ""
Write-Host "Winners (median-based):"
if ($wCycles) { Write-Host ("  * Lowest median cycles/iter : O={0} arch={1} cycles_med={2}" -f $wCycles.O, $wCycles.Arch, $wCycles.CyclesMedian) }
if ($wWall)   { Write-Host ("  * Lowest median wall_us/iter: O={0} arch={1} wall_med={2}"   -f $wWall.O,   $wWall.Arch,   $wWall.WallMedianUs) }
if ($wCpu)    { Write-Host ("  * Lowest median cpu_ns/iter : O={0} arch={1} cpu_med={2}"    -f $wCpu.O,    $wCpu.Arch,    $wCpu.CpuMedianNs) }
else          { Write-Host ("  * cpu_ns/iter winner: N/A (GetThreadTimes too coarse; medians are 0)") }

Write-Host ""
Write-Host "Winners (best sustained block = min of min_block_* across runs):"
if ($wMinBlkCycles) { Write-Host ("  * Best sustained block cycles : O={0} arch={1} min_block_cycles={2}" -f $wMinBlkCycles.O, $wMinBlkCycles.Arch, $wMinBlkCycles.MinBlockCycles) }
if ($wMinBlkWall)   { Write-Host ("  * Best sustained block wall_us : O={0} arch={1} min_block_wall_us={2}" -f $wMinBlkWall.O,   $wMinBlkWall.Arch,   $wMinBlkWall.MinBlockWallUs) }
if ($wMinBlkCpu)    { Write-Host ("  * Best sustained block cpu_ns  : O={0} arch={1} min_block_cpu_ns={2}" -f $wMinBlkCpu.O,    $wMinBlkCpu.Arch,    $wMinBlkCpu.MinBlockCpuNs) }
else                { Write-Host ("  * min_block_cpu_ns winner: N/A (often 0 unless REPORT_EVERY is much larger)") }

# Tie-breaker category: "floor then frequency"
Write-Host ""
Write-Host "Tie-breaker stats (per-build medians): min_iter_wall_ticks (lower better), then min_iter_wall_ticks_pct (higher better)"
$agg |
    Where-Object { $null -ne $_.MinIterWallTicksMedian -and $null -ne $_.MinIterWallTicksPctMedian } |
    Sort-Object MinIterWallTicksMedian, @{Expression='MinIterWallTicksPctMedian';Descending=$true}, O, Arch |
    Format-Table O, Arch, Runs, MinIterWallTicksMedian, MinIterWallTicksPctMedian -AutoSize

# Tie-breaker winner: smallest floor, then highest pct among those at that floor
$tbCandidates = @(
    $agg | Where-Object { $null -ne $_.MinIterWallTicksMedian -and $null -ne $_.MinIterWallTicksPctMedian }
)
if ($tbCandidates.Count -gt 0) {
    $minFloor = ($tbCandidates | Measure-Object -Property MinIterWallTicksMedian -Minimum).Minimum
    $floorGroup = @($tbCandidates | Where-Object { $_.MinIterWallTicksMedian -eq $minFloor })
    $tbWinner = @($floorGroup | Sort-Object -Property @{Expression='MinIterWallTicksPctMedian';Descending=$true}, O, Arch)[0]
    Write-Host ""
    Write-Host ("Tie-breaker winner (lowest floor then highest pct): O={0} arch={1} floor_ticks_med={2} floor_pct_med={3}" -f `
        $tbWinner.O, $tbWinner.Arch, $tbWinner.MinIterWallTicksMedian, $tbWinner.MinIterWallTicksPctMedian)
} else {
    Write-Host ""
    Write-Host "Tie-breaker winner: N/A (no wall_iter_min lines parsed)"
}

Write-Host ""
Write-Host "Notes:"
Write-Host "  - Prefer median cycles/iter as the main compiler/flags winner."
Write-Host "  - Use tie-breaker only when cycles medians are effectively tied."
Write-Host "  - If floor_ticks is 0 for many builds, per-iteration QPC is below resolution; rely on cycles/iter + block metrics."
exit 0