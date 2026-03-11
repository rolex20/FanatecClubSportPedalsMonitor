/*
 * Fanatec ClubSport Pedals Monitor (monitoring-only)
 *
 * Goals:
 *   - Keep clutch noise + gas drift monitoring (and optional estimator/auto-adjust).
 *   - Keep VID/PID reconnect support.
 *   - Remove all telemetry/shared-memory/dashboard machinery (--telemetry).
 *   - Remove --tts/--no-tts: program ALWAYS speaks alerts.
 *   - Keep CPU usage extremely low.
 *
 * Build (MSYS2 MINGW64):
 *   gcc -O3 -Wall -Wextra -std=c11 -o fanatecmonitor.exe main.c -lwinmm
 *   in my 14700K E-Cores:
 *   Can Compile with: gcc -O3 -march=gracemont -flto -fwhole-program -mtune=gracemont -Wall -Wextra -std=c11 main.c -o fanatecmonitor.exe -lwinmm
 *   (Added -fwhole-program: Since we only have one translation unit, this lets the linker 
 *   ruthlessly strip and inline code it normally couldn't touch).
 *
 * With NetBeans IDE 18, I had to dd c:\windows\system32\winmm.dll in
 * Run->Set-Project-Configuration->Customize->Build->Linker->Libraries->Add-Library-File
 * according to the required by joyGetPosEx() en https://learn.microsoft.com/en-us/previous-versions/ms709354(v=vs.85)
 * 
 * NetBeans not used (latest version ruined the c plugin), now switched to VsCode, and MSYS2 UCRT64 MINGW64/w gcc 15
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
/* EXTREME PERFORMANCE MACROS                                                */
/* ------------------------------------------------------------------------- */

/*
 * BRANCH PREDICTION HINTS:
 * Before: The CPU instruction prefetcher guessed which branch (if/else) was 
 * most likely to happen. A wrong guess on Gracemont costs 15+ cycles.
 * After: We explicitly tell GCC what is LIKELY (normal driving) and UNLIKELY 
 * (triggering an alert/timeout). GCC physically organizes the compiled machine
 * code so the "hot path" is a straight, uninterrupted line in the L1 I-Cache.
 */
#define LIKELY(x)   __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* 
 * FORCE INLINE: 
 * Ensures the function call overhead (saving registers, jumping, returning)
 * is entirely eliminated by forcing the compiler to embed the code directly.
 */
#define FORCE_INLINE __attribute__((always_inline)) static inline

/*
 * ZERO-RING TICK COUNT BYPASS:
 * Before: Calling GetTickCount() forces an IAT (Import Address Table) lookup
 * and an API syscall overhead (~20 cycles).
 * After: Windows maps a read-only memory page (KUSER_SHARED_DATA) at 0x7FFE0000 
 * into every process. We read the tick count directly from RAM. Takes ~4 cycles.
 * Absolute fastest way to get system ms uptime on Windows.
 */
FORCE_INLINE DWORD GetFastTickCount(void) {
    volatile ULONG64* tickCount = (volatile ULONG64*)0x7FFE0320;
    volatile ULONG* multiplier = (volatile ULONG*)0x7FFE0004;
    return (DWORD)(((*tickCount) * (*multiplier)) >> 24);
}



/* ------------------------------------------------------------------------- */
/* Options and runtime state */

/*
 * CACHE LINE ALIGNMENT (__attribute__((aligned(64))))
 * A standard L1 cache line on Intel is 64 bytes. 
 * Aligning the structs ensures the CPU doesn't have to fetch two separate
 * chunks of memory (cache straddling) just to read a single struct.
 */
typedef struct __attribute__((aligned(64))) Options {
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


/*
 * PERFECT STRUCT PACKING
 * Variables accessed 1000x a second are placed together in the top 48 bytes
 * (The "Hot" Cache Line). Variables accessed only during timeouts/alerts
 * are pushed lower down to the "Cold" Cache Line.
 */
typedef struct __attribute__((aligned(64))) Runtime {
    /* --- HOT CACHE LINE (Read/Written constantly in the loop) --- */
    DWORD peak_gas_in_window; /* Gas drift detector */
    DWORD estimate_window_peak_gas; /* TRACK RAW PEAK: Avoids division in hot path */
    DWORD last_full_throttle_ms; /* Gas drift detector */
    DWORD last_gas_activity_ms; /* Gas drift detector */
    DWORD last_clutch; /* Clutch detector */

    /* Axis scaling */
    DWORD axis_max; /* 1023 in raw mode; else 65535 */
    DWORD axis_margin; /* axis_max * margin% / 100 */

    /* Gas thresholds in normalized space */
    DWORD gas_idle_max; /* axis_max * gas_deadzone_in / 100 */
    DWORD gas_full_min; /* axis_max * gas_deadzone_out_current / 100 */

    DWORD gas_min_usage_raw;        /* PRECALCULATED RAW THRESHOLD: No percentages needed */

    int   clutch_repeat_count; /* Clutch detector */
    BOOL  is_racing; /* Gas drift detector */

    /* --- WARM / COLD CACHE LINE (Checked/Updated rarely) --- */
    DWORD gas_timeout_ms;
    DWORD gas_window_ms;
    DWORD gas_cooldown_ms;
    DWORD last_gas_alert_ms; /* Gas drift detector */

    DWORD estimate_window_start_ms; /* Estimator */
    DWORD last_estimate_print_ms; /* Estimator */

    int   gas_deadzone_out_current;
    unsigned best_estimate_percent; /* Estimator */
    unsigned last_printed_estimate; /* Estimator */
} Runtime;

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

/* Monitoring helpers 
 * The 'restrict' keyword promises the compiler that 'opt' and 'rt' will never overlap
 * in memory. This eliminates Pointer Aliasing, allowing the compiler to keep
 * values in CPU registers instead of constantly fetching them from RAM. */
FORCE_INLINE void handle_clutch(const Options * restrict opt, Runtime * restrict rt, DWORD gas, DWORD clutch);
FORCE_INLINE void handle_gas(const Options * restrict opt, Runtime * restrict rt, DWORD now, DWORD gas);
FORCE_INLINE void handle_gas_estimator(const Options * restrict opt, Runtime * restrict rt, DWORD now, DWORD gas);

/* Device discovery */
static int  find_joystick(int targetVid, int targetPid);

/* Formatting helper (no snprintf) */
static char *append_digits_from_right(uint32_t value, char special_char,
                                      char *last_valid, size_t total_buf_size);

/* Axis normalization */
FORCE_INLINE DWORD normalize_pedal_axis(int enabled, DWORD raw, DWORD axis_max);

/* Runtime init */
static void runtime_recompute_thresholds(const Options *opt, Runtime *rt);
static void runtime_reset_detectors(const Options *opt, Runtime *rt);

/* Alerting (TTS always enabled) */
static void alert_msg(const Options *opt, const char *text, size_t text_len, int log_to_console);
static void speak_ipc(const char *text, size_t text_len);
static void speak_external(const char *text, size_t text_len);

/* ALERT_LIT is for string literals whose length is known at compile time with sizeof */
#define ALERT_LIT(opt, s) alert_msg((opt), (s), sizeof(s) - 1, 1)

/* ALERT_BUF is for char * but we are *carefully* not using that */ 
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
    puts("    --sleep MS              Poll interval in ms (default 1000; must be > 0).");
    puts("    --iterations N          0 => infinite.");
    puts("    --flags N               JOYINFOEX flags; default JOY_RETURNALL.");
    puts("    --no-axis-normalization Use raw axis direction (no inversion).");
    puts("    --debug-raw             In verbose mode, print raw + normalized values.");
    puts("    --no-console-banner     Suppress startup/status banners.\n");

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

            {"help",                      no_argument,       0, 'h'},
            {"no_buffer",                 no_argument,       0, 'n'},
            {"iterations",                required_argument, 0, 'i'},
            {"margin",                    required_argument, 0, 'm'},
            {"flags",                     required_argument, 0, 'f'},
            {"sleep",                     required_argument, 0, 's'},
            {"joystick",                  required_argument, 0, 'j'},

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

        case '?':
            /* getopt_long already printed an error. */
            break;

        default:
            abort();
        }
    }

    /* If neither joystick ID nor VID/PID were provided, show help. */
    if (!joy_id_set && opt->target_vendor_id == 0)
        show_help_and_exit();

    /* Validation (quietly defensive; fail fast). */
    if (opt->joy_id > 15 && opt->target_vendor_id == 0) {
        fprintf(stderr, "Error: Invalid Joystick ID (0-15).\n");
        exit(EXIT_FAILURE);
    }
    if (opt->margin_percent > 100u) {
        fprintf(stderr, "Error: margin must be 0-100.\n");
        exit(EXIT_FAILURE);
    }
    if (opt->sleep_ms == 0u) {
        fprintf(stderr, "Error: sleep must be > 0 ms.\n");
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
/* Main loop */

static void
run_loop(Options *opt, Runtime *rt, JOYINFOEX *info)
{
    /* HOIST CONSTANTS TO REGISTERS
     * Before: The compiler fetched opt->monitor_clutch, opt->monitor_gas, etc.,
     * from RAM every single iteration, worried that handle_gas() might have modified them.
     * After: By explicitly declaring them as local consts, the compiler keeps them
     * in CPU registers forever, skipping RAM entirely. */
    const int monitor_clutch = opt->monitor_clutch;
    const int monitor_gas    = opt->monitor_gas;
    const int do_normalize   = opt->axis_normalization_enabled;
    const int is_verbose     = opt->verbose;
    const int is_debug       = opt->debug_raw;

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

        /* Using our Zero-Ring bypass instead of the Windows API */
        DWORD now = GetFastTickCount();

        DWORD raw_gas    = info->dwYpos;
        DWORD raw_clutch = info->dwRpos;

        /* Normalization is perfectly branchless thanks to GCC cmov optimization */
        DWORD gas = normalize_pedal_axis(do_normalize, raw_gas, rt->axis_max);
        DWORD clutch = normalize_pedal_axis(do_normalize, raw_clutch, rt->axis_max);

        if (UNLIKELY(is_verbose)) {
            if (is_debug) {
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

        /* Bypass the function calls entirely if features are disabled */
        if (monitor_clutch) handle_clutch(opt, rt, gas, clutch);
        if (monitor_gas)    handle_gas(opt, rt, now, gas);

        Sleep(opt->sleep_ms);
    }
}

/* ------------------------------------------------------------------------- */
/* Monitoring: clutch */

FORCE_INLINE void
handle_clutch(const Options * restrict opt, Runtime * restrict rt, DWORD gas, DWORD clutch)
{
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

    if (UNLIKELY(rt->clutch_repeat_count >= opt->clutch_repeat_required)) {
        ALERT_LIT(opt, "Rudder");
        rt->clutch_repeat_count = 0;
    }
}

/* ------------------------------------------------------------------------- */
/* Monitoring: gas drift + estimator */

FORCE_INLINE void
handle_gas(const Options * restrict opt, Runtime * restrict rt, DWORD now, DWORD gas)
{
    /* Activity detection / “is_racing” state */
    if (gas > rt->gas_idle_max) {
        if (UNLIKELY(!rt->is_racing)) {
            rt->last_full_throttle_ms = now;
            rt->peak_gas_in_window = 0;

            if (opt->estimate_gas_deadzone_enabled) {
                rt->estimate_window_start_ms = now;
                rt->estimate_window_peak_gas = 0u; /* Track RAW gas */
            }

            if (UNLIKELY(opt->verbose))
                printf("Gas: Activity Resumed.\n");
        }

        rt->is_racing = TRUE;
        rt->last_gas_activity_ms = now;
    } else {
        if (rt->is_racing && UNLIKELY((now - rt->last_gas_activity_ms > rt->gas_timeout_ms))) {
            if (UNLIKELY(opt->verbose))
                printf("Gas: Auto-Pause (Idle for %d s).\n", opt->gas_timeout_sec);

            rt->is_racing = FALSE;

            if (opt->estimate_gas_deadzone_enabled) {
                rt->estimate_window_start_ms = now;
                rt->estimate_window_peak_gas = 0u;
            }
        }
    }

    if (!rt->is_racing)
        return;

    /* Track peak in the current drift window */
    if (gas > rt->peak_gas_in_window)
        rt->peak_gas_in_window = gas;

    /* Full-throttle observed => reset drift window */
    if (UNLIKELY(gas >= rt->gas_full_min)) {
        rt->last_full_throttle_ms = now;
        rt->peak_gas_in_window = 0;
        if (opt->estimate_gas_deadzone_enabled) {
            handle_gas_estimator(opt, rt, now, gas);
        }
        return;
    }

    /* Drift window expired => maybe alert */
    if (UNLIKELY((now - rt->last_full_throttle_ms) > rt->gas_window_ms)) {

        if (LIKELY((now - rt->last_gas_alert_ms) > rt->gas_cooldown_ms)) {

            /* EXTREME OPTIMIZATION: Compare RAW peak against precalculated RAW threshold.
             * Zero integer division in the hot path. */
            if (rt->peak_gas_in_window > rt->gas_min_usage_raw) {
                
                /* WE ONLY DIVIDE HERE, on the cold path, because we need to print it */
                unsigned percent_reached =
                    (unsigned)((rt->peak_gas_in_window * 100u) / rt->axis_max);

                static char gas_msg[] = "Gas ******* percent.";
                char *end_of_digits = gas_msg + 10; /* end of ******* field */
                append_digits_from_right(percent_reached, ' ', end_of_digits, 11);

                ALERT_LIT(opt, gas_msg);

                rt->last_gas_alert_ms = now;
            }
        }
    }

    if (opt->estimate_gas_deadzone_enabled) {
        handle_gas_estimator(opt, rt, now, gas);
    }
}

FORCE_INLINE void
handle_gas_estimator(const Options * restrict opt, Runtime * restrict rt, DWORD now, DWORD gas)
{
    /* TRACK RAW GAS. Avoids doing percentage division on every loop iteration. */
    if (gas > rt->gas_idle_max) {
        if (gas > rt->estimate_window_peak_gas)
            rt->estimate_window_peak_gas = gas;
    }

    /* If cooldown window is not met, exit immediately */
    if (LIKELY((now - rt->estimate_window_start_ms) < rt->gas_cooldown_ms))
        return;

    /* WE ONLY DIVIDE HERE, once every few seconds/minutes (Cold path) */
    unsigned peak_percent = (unsigned)((rt->estimate_window_peak_gas * 100u) / rt->axis_max);

    if (peak_percent >= (unsigned)opt->gas_min_usage_percent) {

        if (peak_percent < rt->best_estimate_percent) {
            rt->best_estimate_percent = peak_percent;

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

                ALERT_LIT(opt, speak_buf);

                rt->last_printed_estimate = rt->best_estimate_percent;
                rt->last_estimate_print_ms = now;
            }

            if (opt->auto_gas_deadzone_enabled &&
                (int)rt->best_estimate_percent < rt->gas_deadzone_out_current &&
                (int)rt->best_estimate_percent >= opt->auto_gas_deadzone_minimum) {

                rt->gas_deadzone_out_current = (int)rt->best_estimate_percent;
                runtime_recompute_thresholds(opt, rt);

                printf("[AutoAdjust] gas-deadzone-out updated to %d (min=%d)\n",
                       rt->gas_deadzone_out_current, opt->auto_gas_deadzone_minimum);
            }
        }
    }

    rt->estimate_window_start_ms = now;
    rt->estimate_window_peak_gas = 0u; /* Reset raw tracker */
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

/*
 * BRANCHLESS NORMALIZATION:
 * You might look at this ternary operator (enabled ? X : Y) and worry about branch 
 * prediction penalties. However, because 'enabled' never changes during the run, 
 * modern GCC converts this into a 'cmov' (Conditional Move) assembly instruction.
 * A cmov evaluates both sides mathematically in registers and commits the result 
 * without ever branching the CPU pipeline. It takes exactly 1 cycle on Gracemont,
 * making it faster than trying to write it mathematically with multiplication.
 */
FORCE_INLINE DWORD
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

    /* PRECALCULATED THRESHOLD: 
     * We calculate the absolute raw minimum usage here ONCE. This eradicates the 
     * need to run integer division inside the handle_gas hot loop! */
    rt->gas_min_usage_raw = (DWORD)((rt->axis_max * (DWORD)opt->gas_min_usage_percent) / 100u);

    rt->gas_timeout_ms  = (DWORD)opt->gas_timeout_sec  * 1000u;
    rt->gas_window_ms   = (DWORD)opt->gas_window_sec   * 1000u;
    rt->gas_cooldown_ms = (DWORD)opt->gas_cooldown_sec * 1000u;
}

static void
runtime_reset_detectors(const Options *opt, Runtime *rt)
{
    DWORD now = GetFastTickCount();

    rt->last_clutch = 0;
    rt->clutch_repeat_count = 0;

    rt->is_racing = FALSE;
    rt->peak_gas_in_window = 0;
    rt->last_full_throttle_ms = now;
    rt->last_gas_activity_ms  = now;
    rt->last_gas_alert_ms     = 0;

    rt->best_estimate_percent = 100u;
    rt->last_printed_estimate = 100u;
    rt->estimate_window_peak_gas = 0u; /* Tracker uses RAW instead of percent */
    rt->estimate_window_start_ms = now;
    rt->last_estimate_print_ms  = 0;

    runtime_recompute_thresholds(opt, rt);
}

/* ------------------------------------------------------------------------- */
/* Alerts (TTS always enabled) */

static void
alert_msg(const Options *opt, const char *text, size_t text_len, int log_to_console)
{
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
    
    DWORD to_write = (DWORD)(prefix_len + text_len + 1);
    DWORD written;

    /*  PIPE: Cannot Only open it once: The server only accepts 1 client and needs to be responsive for other clients */
    HANDLE hIpcPipe = CreateFileA(pipe_name, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);

    /* Fire and forget */
    if (hIpcPipe != INVALID_HANDLE_VALUE) {
        WriteFile(hIpcPipe, buffer, to_write, &written, NULL);
        CloseHandle(hIpcPipe);
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
