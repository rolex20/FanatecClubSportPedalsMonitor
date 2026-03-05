/*
================================================================================
Deterministic Microbenchmark Mode (--bench) — User Guide (Windows / MSYS2 GCC)
================================================================================

Why this exists
---------------
This program is primarily a Windows monitor for Fanatec ClubSport pedals (gas/clutch
logic, drift detection, optional estimator/auto-adjust).

The --bench mode turns it into a deterministic microbenchmark so you can compare
different compiler optimization flags (e.g., -O3 vs -O2 vs -Os, with/without
-march/-mtune) on the *same* machine in a repeatable way.

Key goals:
  - No joystick I/O (no joyGetPosEx in bench).
  - Deterministic synthetic inputs so every run does the same work.
  - High-resolution measurement with multiple clocks:
      * Thread cycles (QueryThreadCycleTime) — best signal for “compiler efficiency”
      * Thread CPU time (GetThreadTimes) — time-in-ns the thread actually ran
      * QPC wall time (QueryPerformanceCounter) — active wall time excluding Sleep
  - Alerts are “cheap” in bench mode (only counted, not spoken/printed/spawned).
  - Per-iteration wall-time deltas can be 0 QPC ticks on very fast machines when
    active work is shorter than timer resolution.
  - --bench-alert-work adds deterministic CPU-only alert-formatting payload work
    so single-iteration QPC deltas are easier to measure.

Quick start (recommended commands)
----------------------------------
A good baseline run (exercise the actual monitoring logic, minimize noise):
  fanatecmonitor.exe --bench --monitor-gas --monitor-clutch --sleep 1 --affinitymask 0x4000000

Notes:
  - --sleep 0 yields; --sleep 1 gives the scheduler a tiny break. Try both.
  - Pin to a single E-core using --affinitymask (example above is just a mask sample;
    pick the correct bit for your target core).
  - Use Windows “Ultra / High Performance” power plan and keep background load stable.

If you want less console spam, increase report interval:
  fanatecmonitor.exe --bench --monitor-gas --monitor-clutch --sleep 1 --bench-report-every 10000

If you want longer runs (more stable medians), increase iters:
  fanatecmonitor.exe --bench --monitor-gas --monitor-clutch --sleep 1 --bench-iters 5000000

Benchmark configuration knobs
-----------------------------
--bench
  Enables benchmark mode. Joystick selection is not required.

--bench-warmup N   (default 200000)
  Warmup iterations (no reporting). Stabilizes caches / branch predictors / frequency.

--bench-iters N    (default 1000000)
  Measured iterations.

--bench-dt-ms MS   (default 1)
  Virtual time step in milliseconds fed into the monitoring logic. This keeps timing-
  based detector logic deterministic without calling GetTickCount() each iteration.

--bench-report-every N (default 1000)
  Print a report every N measured iterations. The last partial block prints too.

--bench-alert-work N (default 1 in --bench mode)
  Per benchmark iteration, runs N repetitions of a deterministic CPU-only
  “alert formatting payload” (template memcpy + fixed-width digit patch + tiny mix).
  This does not call OS/I/O alert paths and does not increment alert-trigger counters.
  Set N=0 to benchmark pure detector workload with no forced alert-formatting work.

--sleep MS
  Bench still calls Sleep(MS) each iteration so you can test yield behavior:
    Sleep(0)  => yield
    Sleep(1)  => minimum sleep quantum (depends on timer resolution)
  IMPORTANT: Sleep time is *excluded* from the wall-time metric described below.

How the benchmark workload is generated
---------------------------------------
Each iteration generates deterministic gas/clutch values:
  - A fixed-seed LCG RNG + a phase pattern that forces the state machine through
    useful “scenarios” (idle-ish, racing-ish, full throttle bursts, etc.).
This ensures each run exercises the same code paths in a repeatable pattern.

Bench mode still calls:
  handle_clutch(...)
  handle_gas(...)
so you should pass:
  --monitor-clutch --monitor-gas
if you want to benchmark the real detector logic rather than just the harness.

How timing is measured (three clocks)
-------------------------------------

1) cycles/iter  (QueryThreadCycleTime)
   - What it is:
       CPU cycles consumed by THIS THREAD during the measured work.
   - Why it’s useful:
       Usually the best “compiler optimization” signal (less affected by preemption
       and wall-clock jitter).
   - Source:
       QueryThreadCycleTime(GetCurrentThread(), &cycles)
   - Computation:
       block_cycles/iter = delta_cycles_in_block / iterations_in_block
       cumulative cycles/iter uses sum of block deltas / measured_done
   - Notes:
       This measures “how much CPU work” in cycles the thread used.

2) cpu_ns/iter  (GetThreadTimes)
   - What it is:
       CPU time actually consumed by THIS THREAD (kernel+user), expressed in ns.
       This excludes time when your thread wasn’t scheduled.
   - Source:
       GetThreadTimes(GetCurrentThread(), ..., &kernel, &user)
       FILETIME units are 100ns => ns = cpu100ns * 100
   - Computation:
       block_cpu_ns/iter = (delta_cpu_100ns * 100) / iters_in_block
       cumulative cpu_ns/iter uses sum of block deltas / measured_done
   - Notes:
       This is sensitive to CPU frequency changes (turbo / power management).

3) wall_us/iter  (QPC active wall time)
   - What it is:
       High-resolution wall time of ONLY the “active work” section.
       It intentionally excludes:
         - Sleep time
         - report printing time
   - Source:
       QueryPerformanceCounter / QueryPerformanceFrequency
   - IMPORTANT timing semantics:
       The QPC timer is “pausable”.
       Each iteration:
         - Timer is RUNNING during the active work region
         - Timer PAUSES before Sleep
         - Sleep happens while paused
         - Report printing happens while paused
         - Timer RESUMES after Sleep
   - Computation:
       block_wall_us/iter = (block_ticks * 1e6 / freq) / iters_in_block
       cumulative wall_us/iter = (total_ticks * 1e6 / freq) / measured_done
   - Notes:
       This can still reflect preemption/interrupts that happen DURING the active work,
       because wall time can’t distinguish “running” vs “ready-but-not-scheduled”.
       That’s why cycles/iter and cpu_ns/iter also exist.

Derived metric: eff_GHz
-----------------------
eff_GHz is an estimate of the effective CPU frequency while running this thread:

  eff_GHz ≈ (delta_cycles) / (delta_cpu_seconds) / 1e9

We compute it from cycles + thread CPU time:
  cpu_seconds = cpu_100ns * 1e-7
  eff_GHz = cycles / cpu_seconds / 1e9
  (implemented as cycles / (cpu_100ns * 100.0))

Interpretation:
  - It is NOT a “performance score”.
  - It’s a diagnostic to see if frequency is stable across runs/blocks.
  - If eff_GHz varies a lot, cpu_ns/iter will vary too; cycles/iter is usually more stable.

Report output: block vs cumulative
----------------------------------

Every report prints two lines:

[Bench] iter=...  block: ... best: ... alerts=... checksum=...
        cumulative: ...

BLOCK line (rolling window of the last report interval):
  cycles/iter      Average thread cycles per iteration in this block
  cpu_ns/iter      Average thread CPU nanoseconds per iteration in this block
  wall_us/iter     Average active wall microseconds per iteration in this block
  eff_GHz          Effective GHz estimate for this block (diagnostic)
  best:            “best so far” tracking (see below)
  alerts           Count of alerts triggered during this block (alerts are suppressed in bench)
  checksum         Rolling checksum to prevent the compiler optimizing away the workload

BEST fields (best-so-far):
  min_block_cycles   Minimum observed block-average cycles/iter so far
  min_block_cpu_ns   Minimum observed block-average cpu_ns/iter so far
  min_block_wall_us  Minimum observed block-average wall_us/iter so far
  min_iter_wall_us   Minimum observed SINGLE-iteration wall time so far (QPC active delta)
  Notes:
    - min_iter_wall_us is a “best-case hint” (least interference moment).
    - min_block_* is a better “best sustained performance” indicator than a single min.

CUMULATIVE line (from the start of measured phase):
  cycles/iter      Computed from sum of clean block deltas / total measured iterations
  cpu_ns/iter      Same (sum of block cpu deltas / total measured iterations)
  wall_us/iter     QPC total active ticks / total measured iterations
  eff_GHz          Computed from cumulative cycles + cumulative cpu time
  alerts           Total alerts so far
  checksum         Current checksum

IMPORTANT:
  - Cumulative cycles/iter and cpu_ns/iter are derived from summed block deltas,
    so report printing overhead does not contaminate them.

Why min_iter_wall_ticks can be 0 (and why --bench-alert-work exists)
---------------------------------------------------------------
On fast CPUs, a single benchmark iteration can finish before one QPC tick elapses,
so raw per-iteration wall deltas may frequently be 0 ticks. This is expected and is
now explicitly tracked by min_iter_wall_ticks and its count/percent fields.

The --bench-alert-work knob exists to make single-iteration wall timing more
meaningful while keeping runs deterministic: it adds a tiny CPU-only payload
(buffer copy + digit patching + deterministic mixing) inside the measured region,
without GetLocalTime/printing/IPC/CreateProcess/Wait activity and without changing
real detector-triggered alert counter semantics.

Final summary footer ([BenchSummary])
-------------------------------------
At the end of the run, the program prints summary stats:

[BenchSummary] iters=... blocks=... sleep_ms=... dt_ms=... report_every=...

Then per metric:
  mean     = cumulative average over the entire measured run
  median   = median of the *block averages* (Option A; robust vs outliers)
  min_block= best sustained block average seen

Plus:
  wall_us/iter includes min_iter_wall_us
  alerts / checksum / sink (sink is volatile to defeat dead-code elimination)

How to choose the “best” compiler flags
---------------------------------------
Recommended selection order:
1) Primary winner metric: median cycles/iter
   - Usually the cleanest signal for compiler/flags differences.

2) Secondary: median wall_us/iter (active wall time)
   - Useful sanity check; can show scheduler noise. Expect more jitter than cycles.

3) cpu_ns/iter depends on frequency stability:
   - If eff_GHz is stable across runs, cpu_ns/iter can also be a good “real time” metric.
   - If eff_GHz varies, prefer cycles/iter.

Use “min_*” carefully:
  - min_iter_wall_us is a best-case hint, not the final truth.
  - min_block_* is more meaningful than a single-iteration minimum.

Practical run discipline (for enthusiasts)
------------------------------------------
To make comparisons fair:
  - Use the same OS power plan for all runs (High/Ultra performance).
  - Keep background load stable (close browsers, updates, RGB tools, etc).
  - Pin to one core (affinity mask) so you don’t hop across cores.
  - Run each build 3–5 times and compare medians (not just one run).
  - Keep --sleep consistent across builds when comparing (-O3 vs -O2 etc).
  - If you change --sleep, you’re testing a different scheduler/yield behavior.

Understanding your GCC flag matrix
----------------------------------
You can compile multiple binaries (or one binary at a time) using combinations like:
  -O3 -march=gracemont -mtune=gracemont
  -O2 -march=gracemont -mtune=gracemont
  -Os -march=gracemont -mtune=gracemont
  -O2
  -Os

For each binary:
  - Run the same benchmark command line (same iters, report_every, sleep, dt).
  - Record median cycles/iter and median wall_us/iter.
  - Choose the lowest median cycles/iter as the primary “best optimization” result.

================================================================================
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

#include <windows.h>
#include <mmsystem.h>
#include <getopt.h>

#include <assert.h>

#ifndef JOY_RETURNRAWDATA
#define JOY_RETURNRAWDATA 256
#endif

/* ------------------------------------------------------------------------- */
/* Options and runtime state */

typedef struct Options {
    /* Logging */
    int verbose;
    int debug_raw;
    int no_console_banner;

    /* Features */
    int monitor_clutch;
    int monitor_gas;

    /* Axis semantics */
    int axis_normalization_enabled;

    /* Device selection */
    UINT  joy_id;                /* 17 means “unset” sentinel (historical behavior) */
    DWORD joy_flags;             /* JOYINFOEX.dwFlags */

    int   target_vendor_id;      /* optional VID/PID for auto-reconnect */
    int   target_product_id;

    /* Loop control */
    unsigned iterations;         /* 0 => infinite */
    unsigned sleep_ms;           /* must be > 0 */

    /* Deterministic microbenchmark */
    int      bench_mode;
    unsigned bench_iters;
    unsigned bench_warmup;
    unsigned bench_dt_ms;
    unsigned bench_report_every;
    unsigned bench_alert_work;

    /* Clutch tuning */
    unsigned margin_percent;     /* 0..100 */
    int      clutch_repeat_required;

    /* Gas tuning */
    int gas_deadzone_in;         /* 0..100 */
    int gas_deadzone_out;        /* 0..100 initial */
    int gas_window_sec;          /* > 0 */
    int gas_timeout_sec;         /* > 0 */
    int gas_cooldown_sec;        /* > 0 */
    int gas_min_usage_percent;   /* 0..100 */

    /* Estimator / auto-adjust */
    int estimate_gas_deadzone_enabled;
    int auto_gas_deadzone_enabled;
    int auto_gas_deadzone_minimum;

    /* TTS delivery: TTS is always enabled; this chooses how */
    int ipc_enabled;             /* 0 => spawn PowerShell, 1 => SPEAK over pipe */

    /* Process tuning (applied after parse) */
    int set_idle_priority;
    int set_below_normal_priority;
    int set_affinity;
    DWORD_PTR affinity_mask;
} Options;

typedef struct Runtime {
    /* Axis scaling */
    DWORD axis_max;              /* 1023 in raw mode; else 65535 */
    DWORD axis_margin;           /* axis_max * margin% / 100 */

    /* Gas thresholds in normalized space */
    DWORD gas_idle_max;          /* axis_max * gas_deadzone_in / 100 */
    DWORD gas_full_min;          /* axis_max * gas_deadzone_out_current / 100 */

    DWORD gas_timeout_ms;
    DWORD gas_window_ms;
    DWORD gas_cooldown_ms;

    int gas_deadzone_out_current;

    /* Clutch detector */
    DWORD last_clutch;
    int   clutch_repeat_count;

    /* Gas drift detector */
    BOOL  is_racing;
    DWORD peak_gas_in_window;
    DWORD last_full_throttle_ms;
    DWORD last_gas_activity_ms;
    DWORD last_gas_alert_ms;

    /* Estimator */
    unsigned best_estimate_percent;
    unsigned last_printed_estimate;
    unsigned estimate_window_peak_percent;
    DWORD    estimate_window_start_ms;
    DWORD    last_estimate_print_ms;
} Runtime;

static volatile ULONGLONG g_bench_alert_count = 0;
static volatile ULONGLONG g_bench_checksum_sink = 0;

/* ------------------------------------------------------------------------- */
/* Forward declarations (keeps the file “literate”: story first, detail later) */

static void options_set_defaults(Options *opt);

static void show_help_and_exit(void);
static void parse_args(int argc, char **argv, Options *opt);

static int  acquire_single_instance(const Options *opt, const char *name, HANDLE *out_mutex);
static void cleanup_single_instance(HANDLE hMutex);

static void apply_process_tuning(const Options *opt);

static int  select_joystick(Options *opt);
static int  init_monitor(const Options *opt, Runtime *rt, JOYINFOEX *info);

static void run_loop(Options *opt, Runtime *rt, JOYINFOEX *info);
static void run_bench_loop(Options *opt);

/* Monitoring helpers */
static void handle_clutch(const Options *opt, Runtime *rt, DWORD gas, DWORD clutch);
static void handle_gas(const Options *opt, Runtime *rt, DWORD now, DWORD gas);
static void handle_gas_estimator(const Options *opt, Runtime *rt, DWORD now, DWORD gas);

/* Device discovery */
static int  find_joystick(int targetVid, int targetPid);

/* Formatting helper (no snprintf) */
static char *append_digits_from_right(uint32_t value, char special_char,
                                      char *last_valid, size_t total_buf_size);

/* Axis normalization */
static inline DWORD normalize_pedal_axis(int enabled, DWORD raw, DWORD axis_max);

/* Runtime init */
static void runtime_recompute_thresholds(const Options *opt, Runtime *rt);
static void runtime_reset_detectors(const Options *opt, Runtime *rt);

static uint32_t bench_lcg_next(uint32_t *state);
static void bench_alert_payload(uint32_t iter_index, unsigned work_index, uint64_t *checksum);
static void bench_step(const Options *opt, Runtime *rt, DWORD now, uint32_t iter_index,
                       uint32_t *rng_state, uint64_t *checksum);
static ULONGLONG filetime_to_u64(const FILETIME *ft);
static int get_thread_cpu_100ns(HANDLE thread, ULONGLONG *out_cpu_100ns);

/* Alerting (TTS always enabled) */
static void alert_msg(const Options *opt, const char *text, size_t text_len, int log_to_console);
static void speak_ipc(const char *text, size_t text_len);
static void speak_external(const char *text, size_t text_len);

#define ALERT_LIT(opt, s) alert_msg((opt), (s), sizeof(s) - 1, 1)
#define ALERT_BUF(opt, s) alert_msg((opt), (s), strlen(s), 1)

/* ------------------------------------------------------------------------- */
/* Main “story” */

int
main(int argc, char **argv)
{
    Options opt;
    Runtime rt;
    JOYINFOEX info;
    HANDLE hMutex = NULL;

    options_set_defaults(&opt);

    parse_args(argc, argv, &opt);

    if (opt.bench_mode) {
        apply_process_tuning(&opt);
        run_bench_loop(&opt);
        return EXIT_SUCCESS;
    }

    if (!acquire_single_instance(&opt, "fanatec_monitor_single_instance_mutex", &hMutex))
        return EXIT_FAILURE;

    apply_process_tuning(&opt);

    if (!select_joystick(&opt)) {
        cleanup_single_instance(hMutex);
        return EXIT_FAILURE;
    }

    if (!init_monitor(&opt, &rt, &info)) {
        cleanup_single_instance(hMutex);
        return EXIT_FAILURE;
    }

    run_loop(&opt, &rt, &info);

    cleanup_single_instance(hMutex);
    return EXIT_SUCCESS;
}

/* ------------------------------------------------------------------------- */
/* Defaults */

static void
options_set_defaults(Options *opt)
{
    memset(opt, 0, sizeof(*opt));

    opt->verbose = 0;
    opt->debug_raw = 0;
    opt->no_console_banner = 0;

    opt->monitor_clutch = 0;
    opt->monitor_gas = 0;

    opt->axis_normalization_enabled = 1;

    opt->joy_id = 17;                 /* unset sentinel */
    opt->joy_flags = JOY_RETURNALL;

    opt->iterations = 1;              /* 0 => infinite */
    opt->sleep_ms = 1000;

    opt->bench_mode = 0;
    opt->bench_iters = 1000000u;
    opt->bench_warmup = 200000u;
    opt->bench_dt_ms = 1u;
    opt->bench_report_every = 1000u;
    opt->bench_alert_work = 1u;

    opt->margin_percent = 5;
    opt->clutch_repeat_required = 4;

    opt->gas_deadzone_in = 5;
    opt->gas_deadzone_out = 93;
    opt->gas_window_sec = 30;
    opt->gas_timeout_sec = 10;
    opt->gas_cooldown_sec = 60;
    opt->gas_min_usage_percent = 20;

    opt->estimate_gas_deadzone_enabled = 0;
    opt->auto_gas_deadzone_enabled = 0;
    opt->auto_gas_deadzone_minimum = 0;

    opt->ipc_enabled = 0;

    opt->set_idle_priority = 0;
    opt->set_below_normal_priority = 0;
    opt->set_affinity = 0;
    opt->affinity_mask = 0;
}

/* ------------------------------------------------------------------------- */
/* Help + CLI parsing */

static void
show_help_and_exit(void)
{
    puts("Usage: fanatecmonitor.exe [--monitor-clutch] [--monitor-gas] [options]\n");
    puts("  Removed: --telemetry, --tts, --no-tts (TTS is always enabled)\n");

    puts("  Controller selection:");
    puts("    --joystick ID           Joystick ID (0-15).");
    puts("    --vendor-id HEX         VID for auto-reconnect.");
    puts("    --product-id HEX        PID for auto-reconnect.\n");

    puts("  Monitoring:");
    puts("    --monitor-clutch        Enable clutch noise monitoring.");
    puts("    --monitor-gas           Enable gas drift monitoring.\n");

    puts("  TTS delivery:");
    puts("    --ipc                   Use IPC SPEAK pipe instead of spawning PowerShell.\n");

    puts("  General:");
    puts("    --verbose / --brief     Verbose logging on/off.");
    puts("    --sleep MS              Poll interval in ms (default 1000; must be > 0 outside --bench).");
    puts("    --iterations N          0 => infinite.");
    puts("    --flags N               JOYINFOEX flags; default JOY_RETURNALL.");
    puts("    --no-axis-normalization Use raw axis direction (no inversion).");
    puts("    --debug-raw             In verbose mode, print raw + normalized values.");
    puts("    --no-console-banner     Suppress startup/status banners.\n");

    puts("  Benchmark:");
    puts("    --bench                 Run deterministic microbenchmark mode.");
    puts("    --bench-iters N         Measured iterations; default 1000000.");
    puts("    --bench-warmup N        Warmup iterations; default 200000.");
    puts("    --bench-dt-ms N         Virtual dt in ms; default 1.");
    puts("    --bench-report-every N  Report interval; default 1000.\n");
    puts("    --bench-alert-work N    Per-iteration alert-format payload reps; default 1 in --bench.\n");

    puts("  Priority/Affinity:");
    puts("    --idle                  Set IDLE priority.");
    puts("    --belownormal           Set BELOW_NORMAL priority.");
    puts("    --affinitymask N        Decimal or 0x... CPU affinity mask.\n");

    puts("  Clutch tuning:");
    puts("    --margin N              0..100 percent, default 5.");
    puts("    --clutch-repeat N       default 4.\n");

    puts("  Gas tuning:");
    puts("    --gas-deadzone-in N     default 5.");
    puts("    --gas-deadzone-out N    default 93.");
    puts("    --gas-window N          seconds, default 30.");
    puts("    --gas-timeout N         seconds, default 10.");
    puts("    --gas-cooldown N        seconds, default 60.");
    puts("    --gas-min-usage N       percent, default 20.");
    puts("    --estimate-gas-deadzone-out");
    puts("    --adjust-deadzone-out-with-minimum N\n");

    exit(EXIT_SUCCESS);
}

static void
parse_args(int argc, char **argv, Options *opt)
{
    int c;
    int joy_id_set = 0;
    enum {
        OPT_BENCH = 1000,
        OPT_BENCH_ITERS,
        OPT_BENCH_WARMUP,
        OPT_BENCH_DT_MS,
        OPT_BENCH_REPORT_EVERY,
        OPT_BENCH_ALERT_WORK
    };

    while (1) {
        struct option long_options[] = {
            {"verbose",                   no_argument,       &opt->verbose, 1},
            {"brief",                     no_argument,       &opt->verbose, 0},
            {"monitor-clutch",            no_argument,       &opt->monitor_clutch, 1},
            {"monitor-gas",               no_argument,       &opt->monitor_gas, 1},
            {"estimate-gas-deadzone-out", no_argument,       &opt->estimate_gas_deadzone_enabled, 1},
            {"no-axis-normalization",     no_argument,       &opt->axis_normalization_enabled, 0},
            {"debug-raw",                 no_argument,       &opt->debug_raw, 1},

            {"ipc",                       no_argument,       &opt->ipc_enabled, 1},
            {"no-console-banner",         no_argument,       &opt->no_console_banner, 1},
            {"bench",                     no_argument,       &opt->bench_mode, 1},

            {"help",                      no_argument,       0, 'h'},
            {"no_buffer",                 no_argument,       0, 'n'},
            {"iterations",                required_argument, 0, 'i'},
            {"margin",                    required_argument, 0, 'm'},
            {"flags",                     required_argument, 0, 'f'},
            {"sleep",                     required_argument, 0, 's'},
            {"joystick",                  required_argument, 0, 'j'},
            {"bench-iters",               required_argument, 0, OPT_BENCH_ITERS},
            {"bench-warmup",              required_argument, 0, OPT_BENCH_WARMUP},
            {"bench-dt-ms",               required_argument, 0, OPT_BENCH_DT_MS},
            {"bench-report-every",        required_argument, 0, OPT_BENCH_REPORT_EVERY},
            {"bench-alert-work",          required_argument, 0, OPT_BENCH_ALERT_WORK},

            {"idle",                      no_argument,       0, 'd'},
            {"belownormal",               no_argument,       0, 'b'},
            {"affinitymask",              required_argument, 0, 'a'},

            {"gas-deadzone-in",           required_argument, 0, '1'},
            {"gas-deadzone-out",          required_argument, 0, '2'},
            {"gas-window",                required_argument, 0, '3'},
            {"gas-cooldown",              required_argument, 0, '4'},
            {"gas-timeout",               required_argument, 0, '5'},
            {"gas-min-usage",             required_argument, 0, '6'},
            {"adjust-deadzone-out-with-minimum", required_argument, 0, '8'},

            {"clutch-repeat",             required_argument, 0, '7'},

            {"vendor-id",                 required_argument, 0, 'v'},
            {"product-id",                required_argument, 0, 'p'},

            {0, 0, 0, 0}
        };

        int option_index = 0;

        c = getopt_long(argc, argv, "hnf:i:j:m:s:", long_options, &option_index);
        if (c == -1)
            break;

        switch (c) {
        case 0:
            break;

        case 'h':
            show_help_and_exit();
            break;

        case 'n':
            setvbuf(stdout, NULL, _IONBF, 0);
            break;

        case 'm':
            opt->margin_percent = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case 'f':
            opt->joy_flags = (DWORD)strtoul(optarg, NULL, 10);
            break;

        case 's':
            opt->sleep_ms = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case 'i':
            opt->iterations = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case 'j':
            opt->joy_id = (UINT)strtoul(optarg, NULL, 10);
            joy_id_set = 1;
            break;

        case 'd':
            opt->set_idle_priority = 1;
            break;

        case 'b':
            opt->set_below_normal_priority = 1;
            break;

        case 'a':
            opt->set_affinity = 1;
            opt->affinity_mask = (DWORD_PTR)strtoull(optarg, NULL, 0);
            break;

        case '1':
            opt->gas_deadzone_in = (int)strtol(optarg, NULL, 10);
            break;

        case '2':
            opt->gas_deadzone_out = (int)strtol(optarg, NULL, 10);
            break;

        case '3':
            opt->gas_window_sec = (int)strtol(optarg, NULL, 10);
            break;

        case '4':
            opt->gas_cooldown_sec = (int)strtol(optarg, NULL, 10);
            break;

        case '5':
            opt->gas_timeout_sec = (int)strtol(optarg, NULL, 10);
            break;

        case '6':
            opt->gas_min_usage_percent = (int)strtol(optarg, NULL, 10);
            break;

        case '8':
            opt->auto_gas_deadzone_minimum = (int)strtol(optarg, NULL, 10);
            opt->auto_gas_deadzone_enabled = 1;
            break;

        case '7':
            opt->clutch_repeat_required = (int)strtol(optarg, NULL, 10);
            break;

        case 'v':
            opt->target_vendor_id = (int)strtol(optarg, NULL, 16);
            break;

        case 'p':
            opt->target_product_id = (int)strtol(optarg, NULL, 16);
            break;

        case OPT_BENCH_ITERS:
            opt->bench_iters = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case OPT_BENCH_WARMUP:
            opt->bench_warmup = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case OPT_BENCH_DT_MS:
            opt->bench_dt_ms = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case OPT_BENCH_REPORT_EVERY:
            opt->bench_report_every = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case OPT_BENCH_ALERT_WORK:
            if (optarg[0] == '-') {
                fprintf(stderr, "Error: bench-alert-work must be >= 0.\n");
                exit(EXIT_FAILURE);
            }
            opt->bench_alert_work = (unsigned)strtoul(optarg, NULL, 10);
            break;

        case '?':
            /* getopt_long already printed an error. */
            break;

        default:
            abort();
        }
    }

    /* If neither joystick ID nor VID/PID were provided, show help. */
    if (!opt->bench_mode && !joy_id_set && opt->target_vendor_id == 0)
        show_help_and_exit();

    /* Validation (quietly defensive; fail fast). */
    if (!opt->bench_mode && opt->joy_id > 15 && opt->target_vendor_id == 0) {
        fprintf(stderr, "Error: Invalid Joystick ID (0-15).\n");
        exit(EXIT_FAILURE);
    }
    if (opt->margin_percent > 100u) {
        fprintf(stderr, "Error: margin must be 0-100.\n");
        exit(EXIT_FAILURE);
    }
    if (!opt->bench_mode && opt->sleep_ms == 0u) {
        fprintf(stderr, "Error: sleep must be > 0 ms.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->bench_mode && opt->bench_iters == 0u) {
        fprintf(stderr, "Error: bench-iters must be > 0.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->bench_mode && opt->bench_dt_ms == 0u) {
        fprintf(stderr, "Error: bench-dt-ms must be > 0.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->bench_mode && opt->bench_report_every == 0u) {
        fprintf(stderr, "Error: bench-report-every must be > 0.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->gas_deadzone_in < 0 || opt->gas_deadzone_in > 100 ||
        opt->gas_deadzone_out < 0 || opt->gas_deadzone_out > 100) {
        fprintf(stderr, "Error: gas deadzones must be 0-100.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->gas_window_sec <= 0 || opt->gas_timeout_sec <= 0 || opt->gas_cooldown_sec <= 0) {
        fprintf(stderr, "Error: gas-window / gas-timeout / gas-cooldown must be > 0.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->gas_min_usage_percent < 0 || opt->gas_min_usage_percent > 100) {
        fprintf(stderr, "Error: gas-min-usage must be 0-100.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->clutch_repeat_required <= 0) {
        fprintf(stderr, "Error: clutch-repeat must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (opt->estimate_gas_deadzone_enabled && !opt->monitor_gas) {
        fprintf(stderr, "Error: --estimate-gas-deadzone-out requires --monitor-gas.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->auto_gas_deadzone_enabled && !opt->monitor_gas) {
        fprintf(stderr, "Error: --adjust-deadzone-out-with-minimum requires --monitor-gas.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->auto_gas_deadzone_enabled && !opt->estimate_gas_deadzone_enabled) {
        fprintf(stderr,
                "Error: --adjust-deadzone-out-with-minimum also requires --estimate-gas-deadzone-out.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->auto_gas_deadzone_enabled &&
        opt->auto_gas_deadzone_minimum > opt->gas_deadzone_out) {
        fprintf(stderr,
                "Error: adjust-deadzone-out-with-minimum (%d) must be <= gas-deadzone-out (%d).\n",
                opt->auto_gas_deadzone_minimum, opt->gas_deadzone_out);
        exit(EXIT_FAILURE);
    }
}

/* ------------------------------------------------------------------------- */
/* Single-instance guard */

static int
acquire_single_instance(const Options *opt, const char *name, HANDLE *out_mutex)
{
    HANDLE hMutex = CreateMutexA(NULL, TRUE, name);
    if (hMutex == NULL) {
        fprintf(stderr, "CreateMutex failed (%lu)\n", GetLastError());
        return 0;
    }

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        ALERT_LIT(opt, "Error. Another instance of Fanatec Monitor is already running.");
        CloseHandle(hMutex);
        return 0;
    }

    *out_mutex = hMutex;
    return 1;
}

static void
cleanup_single_instance(HANDLE hMutex)
{
    if (!hMutex)
        return;

    ReleaseMutex(hMutex);
    CloseHandle(hMutex);
}

/* ------------------------------------------------------------------------- */
/* Process tuning */

static void
apply_process_tuning(const Options *opt)
{
    HANDLE hProcess = GetCurrentProcess();

    if (opt->set_idle_priority)
        SetPriorityClass(hProcess, IDLE_PRIORITY_CLASS);

    if (opt->set_below_normal_priority)
        SetPriorityClass(hProcess, BELOW_NORMAL_PRIORITY_CLASS);

    if (opt->set_affinity)
        SetProcessAffinityMask(hProcess, opt->affinity_mask);
}

/* ------------------------------------------------------------------------- */
/* Device selection and monitor init */

static int
select_joystick(Options *opt)
{
    if (opt->target_vendor_id != 0 && opt->target_product_id != 0) {
        if (opt->verbose)
            printf("Looking for Controller VID:%X PID:%X...\n",
                   opt->target_vendor_id, opt->target_product_id);

        int found = find_joystick(opt->target_vendor_id, opt->target_product_id);
        if (found != -1) {
            opt->joy_id = (UINT)found;
            if (opt->verbose)
                printf("Found at ID: %u\n", opt->joy_id);
        } else if (opt->verbose) {
            printf("Not found at startup. Will use ID %u until error.\n", opt->joy_id);
        }
    }

    return 1;
}

static int
init_monitor(const Options *opt, Runtime *rt, JOYINFOEX *info)
{
    memset(rt, 0, sizeof(*rt));
    rt->gas_deadzone_out_current = opt->gas_deadzone_out;
    runtime_reset_detectors(opt, rt);

    info->dwSize  = sizeof(*info);
    info->dwFlags = opt->joy_flags;

    if (opt->verbose) {
        JOYCAPS jc;
        MMRESULT mr = joyGetDevCaps(opt->joy_id, &jc, sizeof(jc));
        if (mr == JOYERR_NOERROR) {
            printf("Monitoring ID=[%u] VID=[%hX] PID=[%hX]\n",
                   opt->joy_id, jc.wMid, jc.wPid);
        }
        printf("Axis Max: [%lu]\n", (unsigned long)rt->axis_max);
        printf("Axis normalization: %s\n",
               opt->axis_normalization_enabled ? "enabled (normalize inverted -> 0..max)"
                                              : "disabled (use raw 0..max)");
    }

    if (!opt->no_console_banner)
        printf("Fanatec Pedals Monitor started.\n");

    return 1;
}

/* ------------------------------------------------------------------------- */
/* Deterministic benchmark loop */

static uint32_t
bench_lcg_next(uint32_t *state)
{
    *state = (*state * 1664525u) + 1013904223u;
    return *state;
}

static void
bench_alert_payload(uint32_t iter_index, unsigned work_index, uint64_t *checksum)
{
    static const char template_msg[] = "Bench alert payload #**********";
    char msg[sizeof(template_msg)];
    char *last_digit;
    size_t digit_span;
    uint32_t deterministic_value;

    memcpy(msg, template_msg, sizeof(template_msg));

    deterministic_value =
        (uint32_t)(((uint64_t)iter_index * 2654435761u) +
                   ((uint64_t)work_index * 2246822519u) +
                   0x9E3779B9u);

    last_digit = &msg[sizeof(msg) - 2u];
    digit_span = (size_t)((last_digit - msg) + 1u);
    append_digits_from_right(deterministic_value, '#', last_digit, digit_span);

    {
        uint64_t mix = *checksum ^ 0xA0761D6478BD642FULL;
        for (size_t i = 0; i + 1u < sizeof(msg); ++i)
            mix = (mix * 1099511628211ULL) ^ (uint64_t)(unsigned char)msg[i];

        *checksum ^= mix + ((*checksum << 7) | (*checksum >> 57));
        g_bench_checksum_sink ^= (ULONGLONG)mix;
    }
}

static void
bench_step(const Options *opt, Runtime *rt, DWORD now, uint32_t iter_index,
           uint32_t *rng_state, uint64_t *checksum)
{
    DWORD gas_norm;
    DWORD clutch_norm;
    DWORD raw_gas;
    DWORD raw_clutch;
    DWORD gas;
    DWORD clutch;

    const DWORD axis_max = rt->axis_max;
    const DWORD axis_span = axis_max + 1u;
    const uint32_t phase = iter_index % 50000u;

    DWORD r_gas = (DWORD)(bench_lcg_next(rng_state) & axis_max);
    DWORD r_clutch = (DWORD)(bench_lcg_next(rng_state) & axis_max);

    if (phase < 512u) {
        gas_norm = 0u;
        clutch_norm = axis_max / 2u;
    } else if (phase < 35512u) {
        DWORD floor = (DWORD)((axis_max * 25u) / 100u);
        DWORD span = (DWORD)((axis_max * 60u) / 100u);
        gas_norm = floor + (DWORD)(((uint64_t)r_gas * (uint64_t)(span + 1u)) / (uint64_t)axis_span);
        clutch_norm = r_clutch;
    } else if (phase < 36512u) {
        gas_norm = axis_max;
        clutch_norm = axis_max;
    } else {
        gas_norm = r_gas;
        clutch_norm = r_clutch;
    }

    raw_gas = opt->axis_normalization_enabled ? (axis_max - gas_norm) : gas_norm;
    raw_clutch = opt->axis_normalization_enabled ? (axis_max - clutch_norm) : clutch_norm;

    gas = normalize_pedal_axis(opt->axis_normalization_enabled, raw_gas, axis_max);
    clutch = normalize_pedal_axis(opt->axis_normalization_enabled, raw_clutch, axis_max);

    handle_clutch(opt, rt, gas, clutch);
    handle_gas(opt, rt, now, gas);

    {
        uint64_t mix = 0u;
        mix ^= (uint64_t)gas;
        mix ^= ((uint64_t)clutch << 16);
        mix ^= ((uint64_t)(rt->clutch_repeat_count & 0xFFFF) << 32);
        mix ^= ((uint64_t)(rt->is_racing ? 1u : 0u) << 48);
        mix ^= ((uint64_t)rt->best_estimate_percent << 56);
        mix ^= ((uint64_t)rt->peak_gas_in_window << 8);
        mix ^= ((uint64_t)rt->last_full_throttle_ms << 1);
        mix ^= ((uint64_t)rt->last_gas_alert_ms << 3);
        mix ^= ((uint64_t)(unsigned)rt->gas_deadzone_out_current << 40);
        *checksum ^= mix + 0x9e3779b97f4a7c15ULL + ((*checksum << 6) + (*checksum >> 2));
    }
}

static ULONGLONG
filetime_to_u64(const FILETIME *ft)
{
    ULARGE_INTEGER ui;
    ui.LowPart = ft->dwLowDateTime;
    ui.HighPart = ft->dwHighDateTime;
    return ui.QuadPart;
}

static int
get_thread_cpu_100ns(HANDLE thread, ULONGLONG *out_cpu_100ns)
{
    FILETIME creation;
    FILETIME exit_time;
    FILETIME kernel;
    FILETIME user;

    if (!GetThreadTimes(thread, &creation, &exit_time, &kernel, &user))
        return 0;

    *out_cpu_100ns = filetime_to_u64(&kernel) + filetime_to_u64(&user);
    return 1;
}

typedef struct BenchQpcTimer {
    LARGE_INTEGER freq;
    LARGE_INTEGER active_start;
    LONGLONG block_ticks;
    LONGLONG total_ticks;
    int have_qpc;
    int running;
} BenchQpcTimer;

static void
bench_qpc_timer_init(BenchQpcTimer *timer)
{
    memset(timer, 0, sizeof(*timer));
    timer->have_qpc = QueryPerformanceFrequency(&timer->freq) ? 1 : 0;
}

static void
bench_qpc_timer_start(BenchQpcTimer *timer)
{
    if (!timer->have_qpc)
        return;

    if (QueryPerformanceCounter(&timer->active_start))
        timer->running = 1;
    else
        timer->have_qpc = 0;
}

static LONGLONG
bench_qpc_timer_pause(BenchQpcTimer *timer)
{
    LARGE_INTEGER now;
    LONGLONG delta = 0;

    if (!timer->have_qpc || !timer->running)
        return 0;

    if (!QueryPerformanceCounter(&now)) {
        timer->have_qpc = 0;
        timer->running = 0;
        return 0;
    }

    delta = now.QuadPart - timer->active_start.QuadPart;
    if (delta < 0)
        delta = 0;

    timer->block_ticks += delta;
    timer->total_ticks += delta;
    timer->running = 0;
    return delta;
}

static void
bench_qpc_timer_resume(BenchQpcTimer *timer)
{
    if (!timer->have_qpc || timer->running)
        return;

    if (QueryPerformanceCounter(&timer->active_start))
        timer->running = 1;
    else
        timer->have_qpc = 0;
}

static void
bench_qpc_timer_reset_block(BenchQpcTimer *timer)
{
    timer->block_ticks = 0;
}

static void
bench_store_metric(double *values, size_t capacity, size_t *count, double value)
{
    if (values == NULL || count == NULL)
        return;
    if (*count >= capacity)
        return;

    values[*count] = value;
    (*count)++;
}

static int
bench_compare_double_asc(const void *a, const void *b)
{
    const double da = *(const double *)a;
    const double db = *(const double *)b;

    if (da < db)
        return -1;
    if (da > db)
        return 1;
    return 0;
}

static int
bench_median_of_block_avgs(double *values, size_t count, double *out_median)
{
    if (values == NULL || out_median == NULL || count == 0u)
        return 0;

    qsort(values, count, sizeof(values[0]), bench_compare_double_asc);

    if ((count & 1u) != 0u) {
        *out_median = values[count / 2u];
    } else {
        const size_t hi = count / 2u;
        const size_t lo = hi - 1u;
        *out_median = (values[lo] + values[hi]) * 0.5;
    }

    return 1;
}

static void
run_bench_loop(Options *opt)
{
    Runtime rt;
    BenchQpcTimer wall_timer;
    DWORD virtual_now = 0u;
    uint32_t iter_index = 0u;
    uint32_t rng_state = 0x13579BDFu;
    uint64_t checksum = 0u;

    HANDLE current_thread = GetCurrentThread();
    ULONGLONG cycles_start = 0u;
    ULONGLONG cycles_block_base = 0u;
    int have_cycles = 0;
    ULONGLONG cpu_start_100ns = 0u;
    ULONGLONG cpu_block_base_100ns = 0u;
    int have_cpu = 0;
    ULONGLONG cum_cycles = 0u;
    ULONGLONG cum_cpu_100ns = 0u;
    int have_cum_cycles = 0;
    int have_cum_cpu = 0;

    ULONGLONG block_alert_prev = 0u;
    unsigned long long measured_done = 0u;
    unsigned long long block_iters = 0u;
    unsigned long long blocks_done = 0u;

    int have_min_block_cycles = 0;
    int have_min_block_cpu_ns = 0;
    int have_min_block_wall_us = 0;
    int have_min_block_eff_ghz = 0;
    int have_min_iter_wall_ticks = 0;
    double min_block_cycles_per_iter_so_far = 0.0;
    double min_block_cpu_ns_per_iter_so_far = 0.0;
    double min_block_wall_us_per_iter_so_far = 0.0;
    double min_block_eff_ghz_so_far = 0.0;
    LONGLONG min_iter_wall_ticks = 0;
    unsigned long long min_iter_wall_ticks_count = 0u;

    unsigned long long block_capacity_ull;
    size_t block_capacity = 0u;
    double *block_cycles_samples = NULL;
    double *block_cpu_ns_samples = NULL;
    double *block_wall_us_samples = NULL;
    double *block_eff_ghz_samples = NULL;
    size_t block_cycles_count = 0u;
    size_t block_cpu_ns_count = 0u;
    size_t block_wall_us_count = 0u;
    size_t block_eff_ghz_count = 0u;

    memset(&rt, 0, sizeof(rt));
    rt.gas_deadzone_out_current = opt->gas_deadzone_out;
    rt.best_estimate_percent = 100u;
    rt.last_printed_estimate = 100u;
    runtime_recompute_thresholds(opt, &rt);
    bench_qpc_timer_init(&wall_timer);

    block_capacity_ull =
        ((unsigned long long)opt->bench_iters +
         (unsigned long long)opt->bench_report_every - 1ull) /
        (unsigned long long)opt->bench_report_every;

    if (block_capacity_ull <= (unsigned long long)SIZE_MAX)
        block_capacity = (size_t)block_capacity_ull;

    if (block_capacity > 0u) {
        block_cycles_samples = (double *)malloc(block_capacity * sizeof(double));
        block_cpu_ns_samples = (double *)malloc(block_capacity * sizeof(double));
        block_wall_us_samples = (double *)malloc(block_capacity * sizeof(double));
        block_eff_ghz_samples = (double *)malloc(block_capacity * sizeof(double));

        if (block_cycles_samples == NULL ||
            block_cpu_ns_samples == NULL ||
            block_wall_us_samples == NULL ||
            block_eff_ghz_samples == NULL) {
            free(block_cycles_samples);
            free(block_cpu_ns_samples);
            free(block_wall_us_samples);
            free(block_eff_ghz_samples);
            block_cycles_samples = NULL;
            block_cpu_ns_samples = NULL;
            block_wall_us_samples = NULL;
            block_eff_ghz_samples = NULL;
            block_capacity = 0u;
        }
    }

    g_bench_alert_count = 0u;
    g_bench_checksum_sink = 0u;

    printf("[Bench] warmup=%u measure=%u dt_ms=%u report_every=%u sleep_ms=%u bench_alert_work=%u\n",
           opt->bench_warmup, opt->bench_iters, opt->bench_dt_ms,
           opt->bench_report_every, opt->sleep_ms, opt->bench_alert_work);

    for (unsigned i = 0; i < opt->bench_warmup; ++i) {
        bench_step(opt, &rt, virtual_now, iter_index, &rng_state, &checksum);
        for (unsigned w = 0; w < opt->bench_alert_work; ++w)
            bench_alert_payload(iter_index, w, &checksum);
        iter_index++;
        virtual_now += (DWORD)opt->bench_dt_ms;
        Sleep(opt->sleep_ms);
    }

    checksum = 0u;
    g_bench_alert_count = 0u;

    have_cycles = QueryThreadCycleTime(current_thread, &cycles_start) ? 1 : 0;
    cycles_block_base = cycles_start;

    have_cpu = get_thread_cpu_100ns(current_thread, &cpu_start_100ns);
    cpu_block_base_100ns = cpu_start_100ns;

    bench_qpc_timer_start(&wall_timer);

    for (unsigned i = 0; i < opt->bench_iters; ++i) {
        bench_step(opt, &rt, virtual_now, iter_index, &rng_state, &checksum);
        for (unsigned w = 0; w < opt->bench_alert_work; ++w)
            bench_alert_payload(iter_index, w, &checksum);
        iter_index++;

        virtual_now += (DWORD)opt->bench_dt_ms;

        measured_done++;
        block_iters++;
        {
            int should_report =
                (block_iters == opt->bench_report_every || measured_done == opt->bench_iters);
            int refresh_baselines_after_report = 0;

            LONGLONG iter_wall_ticks = bench_qpc_timer_pause(&wall_timer);
            if (iter_wall_ticks < 0)
                iter_wall_ticks = 0;

            if (wall_timer.have_qpc) {
                if (!have_min_iter_wall_ticks) {
                    min_iter_wall_ticks = iter_wall_ticks;
                    min_iter_wall_ticks_count = 1u;
                    have_min_iter_wall_ticks = 1;
                } else if (iter_wall_ticks < min_iter_wall_ticks) {
                    min_iter_wall_ticks = iter_wall_ticks;
                    min_iter_wall_ticks_count = 1u;
                } else if (iter_wall_ticks == min_iter_wall_ticks) {
                    min_iter_wall_ticks_count++;
                }
            }

            if (should_report) {
                ULONGLONG block_alerts;
                ULONGLONG total_alerts;
                ULONGLONG block_cycles = 0u;
                ULONGLONG block_cpu_100ns = 0u;
                int have_block_cycles = 0;
                int have_block_cpu = 0;
                int have_block_eff_ghz = 0;
                double block_cycles_per_iter = 0.0;
                double block_cpu_ns_per_iter = 0.0;
                double block_wall_us_per_iter = 0.0;
                double block_eff_ghz = 0.0;
                double cum_eff_ghz = 0.0;

                if (have_cycles) {
                    ULONGLONG cycles_now = 0u;
                    if (QueryThreadCycleTime(current_thread, &cycles_now)) {
                        block_cycles = cycles_now - cycles_block_base;
                        have_block_cycles = 1;
                    } else {
                        have_cycles = 0;
                    }
                }

                if (have_cpu) {
                    ULONGLONG cpu_now_100ns = 0u;
                    if (get_thread_cpu_100ns(current_thread, &cpu_now_100ns)) {
                        block_cpu_100ns = cpu_now_100ns - cpu_block_base_100ns;
                        have_block_cpu = 1;
                    } else {
                        have_cpu = 0;
                    }
                }

                total_alerts = g_bench_alert_count;
                block_alerts = total_alerts - block_alert_prev;
                block_alert_prev = total_alerts;

                if (have_block_cycles) {
                    block_cycles_per_iter = (double)block_cycles / (double)block_iters;
                    cum_cycles += block_cycles;
                    have_cum_cycles = 1;
                    if (!have_min_block_cycles ||
                        block_cycles_per_iter < min_block_cycles_per_iter_so_far) {
                        min_block_cycles_per_iter_so_far = block_cycles_per_iter;
                        have_min_block_cycles = 1;
                    }
                    bench_store_metric(block_cycles_samples, block_capacity,
                                       &block_cycles_count, block_cycles_per_iter);
                }

                if (have_block_cpu) {
                    block_cpu_ns_per_iter =
                        ((double)block_cpu_100ns * 100.0) / (double)block_iters;
                    cum_cpu_100ns += block_cpu_100ns;
                    have_cum_cpu = 1;
                    if (!have_min_block_cpu_ns ||
                        block_cpu_ns_per_iter < min_block_cpu_ns_per_iter_so_far) {
                        min_block_cpu_ns_per_iter_so_far = block_cpu_ns_per_iter;
                        have_min_block_cpu_ns = 1;
                    }
                    bench_store_metric(block_cpu_ns_samples, block_capacity,
                                       &block_cpu_ns_count, block_cpu_ns_per_iter);
                }

                if (wall_timer.have_qpc) {
                    block_wall_us_per_iter =
                        ((double)wall_timer.block_ticks * 1000000.0) /
                        ((double)wall_timer.freq.QuadPart * (double)block_iters);
                    if (!have_min_block_wall_us ||
                        block_wall_us_per_iter < min_block_wall_us_per_iter_so_far) {
                        min_block_wall_us_per_iter_so_far = block_wall_us_per_iter;
                        have_min_block_wall_us = 1;
                    }
                    bench_store_metric(block_wall_us_samples, block_capacity,
                                       &block_wall_us_count, block_wall_us_per_iter);
                }

                if (have_block_cycles && have_block_cpu && block_cpu_100ns > 0u) {
                    block_eff_ghz = (double)block_cycles / ((double)block_cpu_100ns * 100.0);
                    have_block_eff_ghz = 1;

                    if (!have_min_block_eff_ghz || block_eff_ghz < min_block_eff_ghz_so_far) {
                        min_block_eff_ghz_so_far = block_eff_ghz;
                        have_min_block_eff_ghz = 1;
                    }

                    bench_store_metric(block_eff_ghz_samples, block_capacity,
                                       &block_eff_ghz_count, block_eff_ghz);
                }

                if (have_cum_cycles && have_cum_cpu && cum_cpu_100ns > 0u) {
                    cum_eff_ghz = (double)cum_cycles / ((double)cum_cpu_100ns * 100.0);
                }

                printf("[Bench] iter=%llu  block:",
                       measured_done);
                if (have_block_cycles)
                    printf(" cycles/iter=%.2f", block_cycles_per_iter);
                else
                    printf(" cycles/iter=N/A");

                if (have_block_cpu)
                    printf(" cpu_ns/iter=%.2f", block_cpu_ns_per_iter);
                else
                    printf(" cpu_ns/iter=N/A");

                if (wall_timer.have_qpc)
                    printf(" wall_us/iter=%.3f", block_wall_us_per_iter);
                else
                    printf(" wall_us/iter=N/A");

                if (have_block_eff_ghz) {
                    printf(" eff_GHz=%.3f", block_eff_ghz);
                } else {
                    printf(" eff_GHz=N/A");
                }

                printf(" best:");
                if (have_min_block_cycles)
                    printf(" min_block_cycles=%.2f", min_block_cycles_per_iter_so_far);
                else
                    printf(" min_block_cycles=N/A");

                if (have_min_block_cpu_ns)
                    printf(" min_block_cpu_ns=%.2f", min_block_cpu_ns_per_iter_so_far);
                else
                    printf(" min_block_cpu_ns=N/A");

                if (have_min_block_wall_us)
                    printf(" min_block_wall_us=%.3f", min_block_wall_us_per_iter_so_far);
                else
                    printf(" min_block_wall_us=N/A");

                if (have_min_iter_wall_ticks)
                    printf(" min_iter_wall_us=%.6f",
                           ((double)min_iter_wall_ticks * 1000000.0) /
                           (double)wall_timer.freq.QuadPart);
                else
                    printf(" min_iter_wall_us=N/A");

                printf(" alerts=%llu checksum=%llu\n", block_alerts, (unsigned long long)checksum);

                printf("        cumulative:");
                if (have_cum_cycles)
                    printf(" cycles/iter=%.2f", (double)cum_cycles / (double)measured_done);
                else
                    printf(" cycles/iter=N/A");

                if (have_cum_cpu)
                    printf(" cpu_ns/iter=%.2f",
                           ((double)cum_cpu_100ns * 100.0) / (double)measured_done);
                else
                    printf(" cpu_ns/iter=N/A");

                if (wall_timer.have_qpc)
                    printf(" wall_us/iter=%.3f",
                           ((double)wall_timer.total_ticks * 1000000.0) /
                           ((double)wall_timer.freq.QuadPart * (double)measured_done));
                else
                    printf(" wall_us/iter=N/A");

                if (have_cum_cycles && have_cum_cpu && cum_cpu_100ns > 0u) {
                    printf(" eff_GHz=%.3f", cum_eff_ghz);
                } else {
                    printf(" eff_GHz=N/A");
                }

                printf(" alerts=%llu checksum=%llu\n", total_alerts, (unsigned long long)checksum);

                blocks_done++;
                block_iters = 0u;
                bench_qpc_timer_reset_block(&wall_timer);
                refresh_baselines_after_report = 1;
            }

            Sleep(opt->sleep_ms);

            if (refresh_baselines_after_report) {
                if (have_cycles) {
                    ULONGLONG cycles_after_pause = 0u;
                    if (QueryThreadCycleTime(current_thread, &cycles_after_pause))
                        cycles_block_base = cycles_after_pause;
                    else
                        have_cycles = 0;
                }

                if (have_cpu) {
                    ULONGLONG cpu_after_pause_100ns = 0u;
                    if (get_thread_cpu_100ns(current_thread, &cpu_after_pause_100ns))
                        cpu_block_base_100ns = cpu_after_pause_100ns;
                    else
                        have_cpu = 0;
                }
            }
        }

        bench_qpc_timer_resume(&wall_timer);
    }

    g_bench_checksum_sink = checksum;
    printf("[Bench] final checksum=%llu sink=%llu alerts=%llu\n",
           (unsigned long long)checksum,
           (unsigned long long)g_bench_checksum_sink,
           (unsigned long long)g_bench_alert_count);

    {
        double cycles_mean = 0.0;
        double cpu_mean_ns = 0.0;
        double wall_mean_us = 0.0;
        double eff_mean_ghz = 0.0;
        double cycles_median = 0.0;
        double cpu_median_ns = 0.0;
        double wall_median_us = 0.0;
        double eff_median_ghz = 0.0;
        int have_cycles_mean = 0;
        int have_cpu_mean = 0;
        int have_wall_mean = 0;
        int have_eff_mean = 0;
        int have_cycles_median = 0;
        int have_cpu_median = 0;
        int have_wall_median = 0;
        int have_eff_median = 0;

        if (have_cum_cycles && measured_done > 0u) {
            cycles_mean = (double)cum_cycles / (double)measured_done;
            have_cycles_mean = 1;
        }
        if (have_cum_cpu && measured_done > 0u) {
            cpu_mean_ns = ((double)cum_cpu_100ns * 100.0) / (double)measured_done;
            have_cpu_mean = 1;
        }
        if (wall_timer.have_qpc && measured_done > 0u) {
            wall_mean_us =
                ((double)wall_timer.total_ticks * 1000000.0) /
                ((double)wall_timer.freq.QuadPart * (double)measured_done);
            have_wall_mean = 1;
        }
        if (have_cum_cycles && have_cum_cpu && cum_cpu_100ns > 0u) {
            eff_mean_ghz = (double)cum_cycles / ((double)cum_cpu_100ns * 100.0);
            have_eff_mean = 1;
        }

        have_cycles_median =
            bench_median_of_block_avgs(block_cycles_samples, block_cycles_count, &cycles_median);
        have_cpu_median =
            bench_median_of_block_avgs(block_cpu_ns_samples, block_cpu_ns_count, &cpu_median_ns);
        have_wall_median =
            bench_median_of_block_avgs(block_wall_us_samples, block_wall_us_count, &wall_median_us);
        have_eff_median =
            bench_median_of_block_avgs(block_eff_ghz_samples, block_eff_ghz_count, &eff_median_ghz);

        printf("[BenchSummary] iters=%u blocks=%llu sleep_ms=%u dt_ms=%u report_every=%u\n",
               opt->bench_iters, blocks_done, opt->sleep_ms, opt->bench_dt_ms, opt->bench_report_every);

        printf("[BenchSummary] cycles/iter: mean=");
        if (have_cycles_mean)
            printf("%.2f", cycles_mean);
        else
            printf("N/A");
        printf(" median=");
        if (have_cycles_median)
            printf("%.2f", cycles_median);
        else
            printf("N/A");
        printf(" min_block=");
        if (have_min_block_cycles)
            printf("%.2f\n", min_block_cycles_per_iter_so_far);
        else
            printf("N/A\n");

        printf("[BenchSummary] cpu_ns/iter: mean=");
        if (have_cpu_mean)
            printf("%.2f", cpu_mean_ns);
        else
            printf("N/A");
        printf(" median=");
        if (have_cpu_median)
            printf("%.2f", cpu_median_ns);
        else
            printf("N/A");
        printf(" min_block=");
        if (have_min_block_cpu_ns)
            printf("%.2f\n", min_block_cpu_ns_per_iter_so_far);
        else
            printf("N/A\n");

        printf("[BenchSummary] wall_us/iter: mean=");
        if (have_wall_mean)
            printf("%.3f", wall_mean_us);
        else
            printf("N/A");
        printf(" median=");
        if (have_wall_median)
            printf("%.3f", wall_median_us);
        else
            printf("N/A");
        printf(" min_block=");
        if (have_min_block_wall_us)
            printf("%.3f", min_block_wall_us_per_iter_so_far);
        else
            printf("N/A");
        printf(" min_iter_wall_us=");
        if (have_min_iter_wall_ticks)
            printf("%.6f\n",
                   ((double)min_iter_wall_ticks * 1000000.0) /
                   (double)wall_timer.freq.QuadPart);
        else
            printf("N/A\n");

        printf("[BenchSummary] wall_iter_min: min_iter_wall_ticks=");
        if (have_min_iter_wall_ticks)
            printf("%lld", (long long)min_iter_wall_ticks);
        else
            printf("N/A");

        printf(" min_iter_wall_ticks_count=");
        if (have_min_iter_wall_ticks)
            printf("%llu", min_iter_wall_ticks_count);
        else
            printf("N/A");

        printf(" min_iter_wall_ticks_pct=");
        if (have_min_iter_wall_ticks && measured_done > 0u) {
            printf("%.6f", (100.0 * (double)min_iter_wall_ticks_count) / (double)measured_done);
        } else {
            printf("N/A");
        }

        printf(" qpc_freq=");
        if (wall_timer.have_qpc)
            printf("%lld\n", (long long)wall_timer.freq.QuadPart);
        else
            printf("N/A\n");

        printf("[BenchSummary] eff_GHz: mean=");
        if (have_eff_mean)
            printf("%.3f", eff_mean_ghz);
        else
            printf("N/A");
        printf(" median=");
        if (have_eff_median)
            printf("%.3f", eff_median_ghz);
        else
            printf("N/A");
        printf(" min_block=");
        if (have_min_block_eff_ghz)
            printf("%.3f\n", min_block_eff_ghz_so_far);
        else
            printf("N/A\n");

        printf("[BenchSummary] alerts=%llu checksum=%llu sink=%llu\n",
               (unsigned long long)g_bench_alert_count,
               (unsigned long long)checksum,
               (unsigned long long)g_bench_checksum_sink);
    }

    free(block_cycles_samples);
    free(block_cpu_ns_samples);
    free(block_wall_us_samples);
    free(block_eff_ghz_samples);
}

/* ------------------------------------------------------------------------- */
/* Main loop */

static void
run_loop(Options *opt, Runtime *rt, JOYINFOEX *info)
{
    for (unsigned loop = 0; opt->iterations == 0 || loop < opt->iterations; ++loop) {

        MMRESULT mr = joyGetPosEx(opt->joy_id, info);

        if (mr != JOYERR_NOERROR) {
            printf("Error reading joystick (Code %u)\n", (unsigned)mr);

            if (opt->target_vendor_id != 0 && opt->target_product_id != 0) {
                ALERT_LIT(opt, "Controller disconnected. Waiting 60 seconds.");

                for (;;) {
                    Sleep(60000);

                    int new_id = find_joystick(opt->target_vendor_id, opt->target_product_id);
                    if (new_id != -1) {
                        opt->joy_id = (UINT)new_id;

                        ALERT_LIT(opt, "Controller found. Resuming monitoring.");

                        info->dwSize  = sizeof(*info);
                        info->dwFlags = opt->joy_flags;

                        rt->gas_deadzone_out_current = opt->gas_deadzone_out;
                        runtime_reset_detectors(opt, rt);

                        break;
                    }

                    ALERT_LIT(opt, "Controller not found. Retrying.");
                    if (opt->verbose)
                        printf("Scan failed. Retrying in 60s...\n");
                }

                continue;
            }

            Sleep(opt->sleep_ms);
            continue;
        }

        DWORD now = GetTickCount();

        DWORD raw_gas    = info->dwYpos;
        DWORD raw_clutch = info->dwRpos;

        DWORD gas = normalize_pedal_axis(opt->axis_normalization_enabled, raw_gas, rt->axis_max);
        DWORD clutch = normalize_pedal_axis(opt->axis_normalization_enabled, raw_clutch, rt->axis_max);

        if (opt->verbose) {
            if (opt->debug_raw) {
                printf("%lu, gas_raw=%lu gas_norm=%lu, clutch_raw=%lu clutch_norm=%lu\n",
                       (unsigned long)now,
                       (unsigned long)raw_gas, (unsigned long)gas,
                       (unsigned long)raw_clutch, (unsigned long)clutch);
            } else {
                printf("%lu, gas=%lu, clutch=%lu\n",
                       (unsigned long)now,
                       (unsigned long)gas,
                       (unsigned long)clutch);
            }
        }

        handle_clutch(opt, rt, gas, clutch);
        handle_gas(opt, rt, now, gas);

        Sleep(opt->sleep_ms);
    }
}

/* ------------------------------------------------------------------------- */
/* Monitoring: clutch */

static void
handle_clutch(const Options *opt, Runtime *rt, DWORD gas, DWORD clutch)
{
    if (!opt->monitor_clutch)
        return;

    if (gas <= rt->gas_idle_max && clutch > 0) {
        DWORD delta = (clutch >= rt->last_clutch) ? (clutch - rt->last_clutch)
                                                  : (rt->last_clutch - clutch);

        if (delta <= rt->axis_margin)
            rt->clutch_repeat_count++;
        else
            rt->clutch_repeat_count = 0;
    } else {
        rt->clutch_repeat_count = 0;
    }

    rt->last_clutch = clutch;

    if (rt->clutch_repeat_count >= opt->clutch_repeat_required) {
        ALERT_LIT(opt, "Rudder");
        rt->clutch_repeat_count = 0;
    }
}

/* ------------------------------------------------------------------------- */
/* Monitoring: gas drift + estimator */

static void
handle_gas(const Options *opt, Runtime *rt, DWORD now, DWORD gas)
{
    if (!opt->monitor_gas)
        return;

    /* Activity detection / “is_racing” state */
    if (gas > rt->gas_idle_max) {
        if (!rt->is_racing) {
            rt->last_full_throttle_ms = now;
            rt->peak_gas_in_window = 0;

            if (opt->estimate_gas_deadzone_enabled) {
                rt->estimate_window_start_ms = now;
                rt->estimate_window_peak_percent = 0u;
            }

            if (opt->verbose && !opt->bench_mode)
                printf("Gas: Activity Resumed.\n");
        }

        rt->is_racing = TRUE;
        rt->last_gas_activity_ms = now;
    } else {
        if (rt->is_racing && (now - rt->last_gas_activity_ms > rt->gas_timeout_ms)) {
            if (opt->verbose && !opt->bench_mode)
                printf("Gas: Auto-Pause (Idle for %d s).\n", opt->gas_timeout_sec);

            rt->is_racing = FALSE;

            if (opt->estimate_gas_deadzone_enabled) {
                rt->estimate_window_start_ms = now;
                rt->estimate_window_peak_percent = 0u;
            }
        }
    }

    if (!rt->is_racing)
        return;

    /* Track peak in the current drift window */
    if (gas > rt->peak_gas_in_window)
        rt->peak_gas_in_window = gas;

    /* Full-throttle observed => reset drift window */
    if (gas >= rt->gas_full_min) {
        rt->last_full_throttle_ms = now;
        rt->peak_gas_in_window = 0;
        handle_gas_estimator(opt, rt, now, gas);
        return;
    }

    /* Drift window expired => maybe alert */
    if ((now - rt->last_full_throttle_ms) > rt->gas_window_ms) {

        if ((now - rt->last_gas_alert_ms) > rt->gas_cooldown_ms) {

            unsigned percent_reached =
                (unsigned)((rt->peak_gas_in_window * 100u) / rt->axis_max);

            if (percent_reached > (unsigned)opt->gas_min_usage_percent) {
                static char gas_msg[] = "Gas ******* percent.";
                char *end_of_digits = gas_msg + 10; /* end of ******* field */
                append_digits_from_right(percent_reached, ' ', end_of_digits, 11);

                ALERT_BUF(opt, gas_msg);

                rt->last_gas_alert_ms = now;
            }
        }
    }

    handle_gas_estimator(opt, rt, now, gas);
}

static void
handle_gas_estimator(const Options *opt, Runtime *rt, DWORD now, DWORD gas)
{
    if (!opt->estimate_gas_deadzone_enabled)
        return;

    if (gas > rt->gas_idle_max) {
        unsigned current_percent = (unsigned)((gas * 100u) / rt->axis_max);
        if (current_percent > rt->estimate_window_peak_percent)
            rt->estimate_window_peak_percent = current_percent;
    }

    if ((now - rt->estimate_window_start_ms) < rt->gas_cooldown_ms)
        return;

    if (rt->estimate_window_peak_percent >= (unsigned)opt->gas_min_usage_percent) {
        unsigned candidate = rt->estimate_window_peak_percent;

        if (candidate < rt->best_estimate_percent) {
            rt->best_estimate_percent = candidate;

            if (rt->best_estimate_percent < rt->last_printed_estimate &&
                (now - rt->last_estimate_print_ms) >= rt->gas_cooldown_ms) {

                /* We patch the "***" field in-place without snprintf for speed and simplicity.
                *
                * IMPORTANT:
                *   append_digits_from_right() expects `total_buf_size` to describe the *prefix region*
                *   that ends at `last_valid` (inclusive). In other words, it assumes:
                *
                *       buf_start == last_valid - (total_buf_size - 1)
                *
                *   If we pass sizeof(speak_buf) while last_valid points to the '*' field in the
                *   middle of the string, that formula would produce a pointer *before* speak_buf,
                *   which GCC correctly warns about (undefined behavior).
                *
                *   So we pass `span` = number of bytes from speak_buf[0] up through last_valid.
                *   This keeps all pointer math within the array and silences -Warray-bounds.
                */                    

                static char speak_buf[] = "New deadzone estimation:*** percent.";
                char *last_valid = speak_buf + 26; /* last '*' in "...:*** ..." (or compute via strrchr) */

                /* total_buf_size must describe the region that ends at last_valid */
                size_t span = (size_t)(last_valid - speak_buf + 1);
                append_digits_from_right(rt->best_estimate_percent, ':', last_valid, span);

                ALERT_BUF(opt, speak_buf);

                rt->last_printed_estimate = rt->best_estimate_percent;
                rt->last_estimate_print_ms = now;
            }

            if (opt->auto_gas_deadzone_enabled &&
                (int)rt->best_estimate_percent < rt->gas_deadzone_out_current &&
                (int)rt->best_estimate_percent >= opt->auto_gas_deadzone_minimum) {

                rt->gas_deadzone_out_current = (int)rt->best_estimate_percent;
                runtime_recompute_thresholds(opt, rt);

                if (!opt->bench_mode) {
                    printf("[AutoAdjust] gas-deadzone-out updated to %d (min=%d)\n",
                           rt->gas_deadzone_out_current, opt->auto_gas_deadzone_minimum);
                }
            }
        }
    }

    rt->estimate_window_start_ms = now;
    rt->estimate_window_peak_percent = 0u;
}

/* ------------------------------------------------------------------------- */
/* Device discovery */

static int
find_joystick(int targetVid, int targetPid)
{
    JOYCAPS jc;
    int numDevs = (int)joyGetNumDevs();

    for (int i = 0; i < numDevs; i++) {
        if (joyGetDevCaps(i, &jc, sizeof(jc)) == JOYERR_NOERROR) {
            if (jc.wMid == targetVid && jc.wPid == targetPid)
                return i;
        }
    }
    return -1;
}

/* ------------------------------------------------------------------------- */

/*
 * append_digits_from_right()
 *
 * Patch a small decimal number into a fixed-width field inside an existing C string,
 * without snprintf/printf and without allocations.
 *
 * What it does:
 *   - Starting at `last_valid`, writes the decimal digits of `value` right-to-left.
 *   - Then pads any remaining space on the left with ' ' until it reaches either:
 *       a) the start of the caller-provided region, or
 *       b) a sentinel character already present in the string (`special_char`).
 *
 * Typical use:
 *   - You have a template like: "Gas ******* percent."
 *     and you want to replace the ******* area with a number.
 *
 * IMPORTANT CONTRACT (this is the subtle part):
 *   `total_buf_size` is NOT necessarily sizeof(the whole string).
 *   It must describe the size of the region that ENDS at `last_valid` (inclusive):
 *
 *       region_start = last_valid - (total_buf_size - 1)
 *
 *   This lets you safely patch a field that sits in the middle of a larger string.
 *   If you pass sizeof(full_string) while `last_valid` points to an interior '*'
 *   field, region_start would point before the array, which is undefined behavior
 *   and can trigger -Warray-bounds under -O3.
 *
 * Returns:
 *   Pointer to the first digit written (start of the number inside the field).
 *
 * Assumptions:
 *   - `last_valid` points to a writable character within the target region.
 *   - The region is large enough for the number you will write.
 *   - The string already contains `special_char` somewhere to the left if you want
 *     padding to stop early; otherwise padding stops at the region start.
 */
static char *
append_digits_from_right(uint32_t value, char special_char,
                         char *last_valid, size_t total_buf_size)
{
    char *buf_start = last_valid - (ptrdiff_t)(total_buf_size - 1);
    char *cursor = last_valid;

    assert(last_valid != NULL);
    assert(total_buf_size >= 11);
  
    do {
        *cursor-- = (char)('0' + (value % 10u));
        value /= 10u;
    } while (value != 0u);

    char *digits_start = cursor + 1;

    while (cursor >= buf_start && *cursor != special_char)
        *cursor-- = ' ';

    return digits_start;
}

/* ------------------------------------------------------------------------- */
/* Axis normalization + runtime init */

static inline DWORD
normalize_pedal_axis(int enabled, DWORD raw, DWORD axis_max)
{
    return enabled ? (axis_max - raw) : raw;
}

static void
runtime_recompute_thresholds(const Options *opt, Runtime *rt)
{
    rt->axis_max    = (opt->joy_flags & JOY_RETURNRAWDATA) ? 1023u : 65535u;
    rt->axis_margin = (DWORD)((rt->axis_max * (DWORD)opt->margin_percent) / 100u);

    rt->gas_idle_max = (DWORD)((rt->axis_max * (DWORD)opt->gas_deadzone_in) / 100u);
    rt->gas_full_min = (DWORD)((rt->axis_max * (DWORD)rt->gas_deadzone_out_current) / 100u);

    rt->gas_timeout_ms  = (DWORD)opt->gas_timeout_sec  * 1000u;
    rt->gas_window_ms   = (DWORD)opt->gas_window_sec   * 1000u;
    rt->gas_cooldown_ms = (DWORD)opt->gas_cooldown_sec * 1000u;
}

static void
runtime_reset_detectors(const Options *opt, Runtime *rt)
{
    DWORD now = GetTickCount();

    rt->last_clutch = 0;
    rt->clutch_repeat_count = 0;

    rt->is_racing = FALSE;
    rt->peak_gas_in_window = 0;
    rt->last_full_throttle_ms = now;
    rt->last_gas_activity_ms  = now;
    rt->last_gas_alert_ms     = 0;

    rt->best_estimate_percent = 100u;
    rt->last_printed_estimate = 100u;
    rt->estimate_window_peak_percent = 0u;
    rt->estimate_window_start_ms = now;
    rt->last_estimate_print_ms  = 0;

    runtime_recompute_thresholds(opt, rt);
}

/* ------------------------------------------------------------------------- */
/* Alerts (TTS always enabled) */

static void
alert_msg(const Options *opt, const char *text, size_t text_len, int log_to_console)
{
    if (opt->bench_mode) {
        g_bench_alert_count++;
        return;
    }

    if (log_to_console) {
        SYSTEMTIME t;
        GetLocalTime(&t);
        printf("[%.4d-%.2d-%.2d %.2d:%.2d:%.2d] %.*s\n",
               t.wYear, t.wMonth, t.wDay,
               t.wHour, t.wMinute, t.wSecond,
               (int)text_len, text);
    }

    if (opt->ipc_enabled)
        speak_ipc(text, text_len);
    else
        speak_external(text, text_len);
}

static void
speak_ipc(const char *text, size_t text_len)
{
    static const char pipe_name[] = "\\\\.\\pipe\\ipc_pipe_vr_server_commands";
    static const char prefix[]    = "SPEAK ";

    char buffer[512];
    size_t prefix_len = sizeof(prefix) - 1;

    assert(prefix_len + text_len + 1 < sizeof(buffer));

    memcpy(buffer, prefix, prefix_len);
    memcpy(buffer + prefix_len, text, text_len);
    buffer[prefix_len + text_len] = '\n';

    HANDLE hPipe = CreateFileA(pipe_name, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (hPipe != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(hPipe, buffer, (DWORD)(prefix_len + text_len + 1), &written, NULL);
        CloseHandle(hPipe);
    }
}

static void
speak_external(const char *text, size_t text_len)
{
    static const char exe[] =
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

    static const char arg_prefix[] =
        "dummy1stArg -NoProfile -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden "
        "-File .\\saySomething.ps1 \"";

    char cmdline[512];
    const size_t prefix_len = sizeof(arg_prefix) - 1;
    size_t len = prefix_len + text_len;

    assert(len + 2 < sizeof(cmdline));

    memcpy(cmdline, arg_prefix, prefix_len);
    memcpy(cmdline + prefix_len, text, text_len);
    cmdline[len++] = '"';
    cmdline[len]   = '\0';

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (CreateProcessA(
            exe,
            cmdline,
            NULL, NULL,
            FALSE,
            CREATE_NO_WINDOW,
            NULL, NULL,
            &si, &pi))
    {
        WaitForSingleObject(pi.hProcess, INFINITE);  /* CRITICAL: Intentionally block the C thread until PowerShell finishes speaking. */      
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}