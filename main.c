/*
 * File:   main.c
 * Author: rolex20
 *
 * Purpose:
 *   Monitor Fanatec ClubSport Pedals V2 (or similar devices) for:
 *     - Clutch Hall sensor noise (rudder spikes in flight sims).
 *     - Gas pedal drift (potentiometer failing to reach full travel).
 *
 * Design goals:
 *   - Extremely low CPU usage (safe alongside heavy sims like DCS / MSFS).
 *   - Simple, human-friendly axis semantics:
 *        0       = pedal at rest (idle)
 *        axisMax = pedal fully pressed
 *   - Robust to device disconnect/reconnect (optional VID/PID-based auto-detection).
 *
 * Notes:
 *   - Fanatec pedals report inverted values in raw mode (idle near axisMax, pressed near 0).
 *   - By default we normalize axes into the 0..axisMax space above.
 *     If your controller already uses 0..axisMax with 0 = idle, use:
 *         --no-axis-normalization
 *   - Not intended to run for more than 24 hours (no need for overflow checks with GetTickCount)
 * 
 * With NetBeans IDE 18, I had to dd c:\windows\system32\winmm.dll in
 * Run->Set-Project-Configuration->Customize->Build->Linker->Libraries->Add-Library-File
 * according to the required by joyGetPosEx() en https://learn.microsoft.com/en-us/previous-versions/ms709354(v=vs.85)
 * 
 * Used samples from:
 * https://social.msdn.microsoft.com/forums/vstudio/en-US/af28b35b-d756-4d87-94c6-ced882ab20a5/reading-input-data-from-joystick-in-visual-basic
 * lwan_uint32_to_str: https://tia.mat.br/posts/2014/06/23/integer_to_string_conversion.html 
 * 
 * License: https://github.com/rolex20/FanatecClubSportPedalsMonitor/blob/main/LICENSE
 * 
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windows.h"
#include <mmsystem.h>

#include <getopt.h>
#include <stdint.h>

#include <sddl.h>  /* Required for ConvertStringSecurityDescriptorToSecurityDescriptor */

#include <assert.h>

/*
 * PedalMonState:
 * Central structure holding all configuration flags, command-line parameters,
 * runtime state machines, and per-sample telemetry data.
 *
 * This struct is also shared verbatim via shared memory when --telemetry is active.
 * Ideally, it should contain only POD types (ints, DWORDs) and no pointers.
 */
typedef struct PedalMonState {
    /* 
     * Configuration / feature flags (originally static ints). 
     */
    /* Flag set by ‘--verbose’. */
    int verbose_flag;

    /*
     * Feature toggles (set via command line):
     *   monitor_clutch: legacy clutch/rudder noise detection.
     *   monitor_gas:    gas pedal drift detection.
     */
    int monitor_clutch;
    int monitor_gas;

    /*
     * Gas tuning parameters (percentages / seconds).
     *
     * gas_deadzone_in:
     *   Percentage of the total travel treated as "idle band".
     *   Example (axisMax=1023): 5% -> gas <= ~51 is considered idle.
     *
     * gas_deadzone_out:
     *   Percentage of the total travel considered "full throttle".
     *   Example: 93% -> gas >= ~951 is treated as near/full throttle.
     *
     * gas_window:
     *   How long we wait (in seconds) during racing before complaining
     *   that we haven't seen "full throttle".
     *
     * gas_cooldown:
     *   Minimum time (in seconds) between gas drift alerts.
     *
     * gas_timeout:
     *   How long (in seconds) of no gas activity before we assume you're
     *   in a menu/pause and temporarily stop treating the session as racing.
     *
     * gas_min_usage_percent:
     *   Minimum percentage of pedal travel you must have used in a window
     *   before we consider it meaningful for drift detection. This avoids
     *   alerts when creeping along at very low throttle (safety car, taxi, etc.).
     */
    int gas_deadzone_in;
    int gas_deadzone_out;
    int gas_window;
    int gas_cooldown;
    int gas_timeout;
    int gas_min_usage_percent;

    /*
     * Axis normalization:
     *   axis_normalization_enabled != 0:
     *       We assume inverted hardware (e.g. Fanatec raw) and normalize:
     *          normalized = axisMax - raw
     *
     *   axis_normalization_enabled == 0:
     *       We assume controller already reports:
     *          0       = idle
     *          axisMax = full press
     *       and use raw values directly.
     */
    int axis_normalization_enabled;

    /*
     * Debug mode:
     *   debug_raw_mode != 0:
     *       In verbose mode, print both raw and normalized values.
     */
    int debug_raw_mode;

    /*
     * Clutch noise detection:
     *   clutch_repeat_required:
     *       Number of consecutive samples within the "stickiness margin"
     *       before we trigger a clutch noise alert.
     *
     *   Default is 4 samples, which works well for ~1000 ms sleeps.
     *   If you reduce --sleep to e.g. 100 ms and want the same overall
     *   detection time window, you may raise this (e.g. 10+).
     */
    int clutch_repeat_required;

    /*
     * Gas deadzone-out estimation and auto-adjust:
     *
     *   estimate_gas_deadzone_enabled:
     *       When non-zero, the program estimates a suggested value for
     *       --gas-deadzone-out based on observed maximum gas travel over
     *       sliding windows of length gas_cooldown seconds, and prints:
     *
     *           [Estimate] Suggested --gas-deadzone-out: NN
     *
     *       The estimate is monotonically non-increasing for a given device
     *       attachment and is advisory-only.
     *
     *   auto_gas_deadzone_enabled:
     *       When non-zero, the program uses the same estimator to
     *       automatically decrease gas_deadzone_out over time, but never
     *       below auto_gas_deadzone_minimum. This only ever moves the
     *       threshold downward during a session and can be used to keep
     *       the drift detector aligned with a degrading potentiometer.
     */
    int estimate_gas_deadzone_enabled;
    int auto_gas_deadzone_enabled;
    int auto_gas_deadzone_minimum;

    /*
     * Target device for auto-reconnect (0 means "not specified").
     * If both VID and PID are provided, we use them to re-find the device when disconnected.
     */
    int target_vendor_id;
    int target_product_id;

    /*
     * Telemetry and UI Flags
     */
    int telemetry_enabled;   /* 0 = off (default), non-zero = shared-memory telemetry enabled */
    int tts_enabled;         /* 0 = disable TTS, non-zero = allow TTS (default = enabled) */
    int ipc_enabled;         /* 0 = use external process for TTS, non zero = TTS via IPC SPEAK command */
    int no_console_banner;   /* 0 = show banner (default), non-zero = suppress non-essential banners. */

    /*
     * Per-pedal 0..100% indicators for the UI.
     *
     * Physical percentages:
     *   - Computed directly from normalized axis values (0..axisMax).
     *   - 100 == pedal fully physically depressed.
     *
     * Logical (in-game) percentages:
     *   - Apply gas_deadzone_in / gas_deadzone_out thresholds to both gas and clutch.
     *   - 0   == within idle band (below gasIdleMax).
     *   - 100 == within full band (above gasFullMin).
     */
    unsigned int gas_physical_pct;
    unsigned int clutch_physical_pct;

    unsigned int gas_logical_pct;
    unsigned int clutch_logical_pct;

    /* 
     * Command-line parameters (originally locals in main). 
     */
    UINT  joy_ID;
    DWORD joy_Flags;
    UINT  iterations;
    UINT  margin;
    UINT  sleep_Time;

    /* 
     * Axis / clutch state (runtime). 
     */
    DWORD axisMax;
    DWORD axisMargin;  /* Converted % margin to units. */
    DWORD lastClutchValue; /* Normalized clutch value (0..axisMax). */
    int   repeatingClutchCount;

    /* 
     * Gas state machine (runtime). 
     *
     * In normalized space:
     *   gasIdleMax: Maximum value considered "idle".
     *   gasFullMin: Minimum value considered "full throttle".
     */
    BOOL  isRacing;
    DWORD peakGasInWindow;
    DWORD lastFullThrottleTime;
    DWORD lastGasActivityTime;
    DWORD lastGasAlertTime;
    DWORD gasIdleMax;
    DWORD gasFullMin;
    DWORD gas_timeout_ms;
    DWORD gas_window_ms;
    DWORD gas_cooldown_ms;

    /* 
     * Gas deadzone-out estimator state. 
     *
     *   best_estimate_percent:
     *     Best (i.e., lowest) suggested --gas-deadzone-out value observed so far.
     */
    unsigned int best_estimate_percent;
    unsigned int last_printed_estimate;
    unsigned int estimate_window_peak_percent;
    DWORD        estimate_window_start_time;
    DWORD        last_estimate_print_time;

    /* 
     * Per-sample values and helper metrics. 
     */
    DWORD        currentTime;
    DWORD        rawGas;
    DWORD        rawClutch;
    DWORD        gasValue;
    DWORD        clutchValue;
    int          closure;
    unsigned int percentReached;
    unsigned int currentPercent;

    /* 
     * Loop counter. 
     */
    unsigned int iLoop;

    /*
     * Telemetry Producer Timestamps & Metrics
     */
    DWORD producer_loop_start_ms;  /* when the current loop iteration started */
    DWORD producer_notify_ms;      /* when the frame is published to shared memory and event signaled */
    DWORD fullLoopTime_ms;         /* duration of previous loop iteration in ms */
    unsigned int telemetry_sequence;  /* incremented once per published frame */

    /*
     * Event Flags (Per-Iteration One-Shots)
     * These are reset to 0 at the start of each loop.
     */
    int gas_alert_triggered;          /* 1 if a gas drift alert fired this iteration */
    int clutch_alert_triggered;       /* 1 if a clutch noise alert fired this iteration */
    int controller_disconnected;      /* 1 if a disconnect event occurred this iteration: latched state (1 while disconnected) */
    int controller_reconnected;       /* 1 if a reconnect event occurred this iteration */
    int gas_estimate_decreased;       /* 1 if a new (lower) deadzone estimate was spoken this iteration */
    int gas_auto_adjust_applied;      /* 1 if auto deadzone-out adjustment was applied this iteration */

    /*
     * Event Timestamps (Persistent)
     * Last time (in ms) these specific events occurred.
     */
    
    DWORD last_disconnect_time_ms;
    DWORD last_reconnect_time_ms;
    
    
    /* Eliminated 
    DWORD last_gas_alert_time_ms;
    DWORD last_clutch_alert_time_ms;
    DWORD last_estimate_speech_time_ms;
    DWORD last_auto_adjust_time_ms;
    */

} PedalMonState;

/* Shared Memory Resources */
static HANDLE        g_hTelemetryMap   = NULL;
static HANDLE        g_hTelemetryEvent = NULL;
static PedalMonState *g_shared_st      = NULL;

#define PEDMON_TELEMETRY_MAPPING_NAME "PedMonTelemetry"
#define PEDMON_TELEMETRY_EVENT_NAME   "PedMonTelemetryEvent"

/* Some MinGW environments don't define JOY_RETURNRAWDATA. */
#ifndef JOY_RETURNRAWDATA
#define JOY_RETURNRAWDATA 256
#endif

/* 
 * ComputeLogicalPct:
 * Maps a value into a 0..100 range based on idle/full thresholds.
 */
static unsigned int
ComputeLogicalPct(DWORD value, DWORD idleMax, DWORD fullMin)
{
    if (value <= idleMax)
        return 0;

    if (value >= fullMin)
        return 100;

    if (fullMin <= idleMax) {
        /*
         * Defensive guard: if thresholds are misconfigured such that
         * fullMin <= idleMax, treat everything as idle to avoid
         * division by zero or negative ranges.
         */
        return 0;
    }

    /* Standard linear interpolation between thresholds */
    return (unsigned int)(100u * (value - idleMax) / (fullMin - idleMax));
}

/*
 * We use a dedicated buffer size for integer-to-string conversion.
 * 32 bytes is enough for 32-bit values plus a trailing space and NUL.
 */
#define INT_TO_STR_BUFFER_SIZE 32

/*
 * Optimized Integer to String Converter (deprecated, see append_digits_from_right)
 *
 * - Writes digits backwards into the caller-provided buffer, then appends
 *   a trailing space and NUL terminator.
 * - Returns a pointer to the first digit (i.e., into the buffer).
 *
 * The trailing space is important for two reasons:
 *   1) When we overwrite a previous longer number, the extra characters
 *      beyond the new number are blanked, so the PowerShell argument is clean.
 *   2) It naturally separates this argument from any following ones.
 */
static char *
lwan_uint32_to_str(uint32_t value, char buffer[static INT_TO_STR_BUFFER_SIZE])
{
    /* Reserve the last byte for the NUL, and one extra for the space. */
    char *p = buffer + INT_TO_STR_BUFFER_SIZE - 2;

    *p = '\0';

    /* Write digits backwards. */
    do {
        *--p = "0123456789"[value % 10];
    } while (value /= 10);

    /* Compute number of digits written. */
    size_t difference = (size_t)(p - buffer);
    int len = (int)(INT_TO_STR_BUFFER_SIZE - 2 - difference);

    /* Append a space after the digits. */
    p[len++] = ' ';
    p[len]   = '\0';

    return p;
}


/*
 * append_digits_from_right(): optimized, assert-enabled RTL writer.
 *
 * Preconditions (caller must ensure):
 *  - last_valid == buf + total_buf_size - 2
 *  - total_buf_size >= 11 (10 digits for uint32 + terminating NUL)
 *  - The buffer contains the prefix to the left of reserved tail area.
 *
 * Behavior:
 *  - Writes digits right-to-left starting at *last_valid
 *    and backfills spaces (0x20) leftwards up to special_char or buffer start.
 *  - No trailing space is written after the digits.
 *  - Returns pointer to first digit written, or NULL on trivial sanity failure.
 */
static char *
append_digits_from_right(uint32_t value, char special_char, char *last_valid, size_t total_buf_size)
{
    /* Debug-only validation of caller preconditions. */
    assert(last_valid != NULL);
    assert(total_buf_size >= 11); /* 10 digits + NUL */

    /* Compute buffer start. Cast to ptrdiff_t to avoid unsigned arithmetic surprises. */
    char *buf_start = last_valid - (ptrdiff_t)(total_buf_size - 1);

    char *cursor = last_valid;

    /* 
     * Write digits Right to Left (RTL). Use do/while to handle value==0 in one pass.
     * 
     * PERFORMANCE NOTE: 
     * The line below combines integer arithmetic, ASCII conversion, memory store,
     * and pointer decrement into a single concise construct.
     *
     * Original approach: 
     *     *cursor = "0123456789"[value % 10];
     *     cursor--;
     *
     * Why the new approach is faster:
     * 1. No Memory Lookup: The original approach accesses a string literal array 
     *    stored in memory (L1 Data Cache). The new approach uses pure CPU register 
     *    arithmetic ('0' + remainder), avoiding the load latency.
     * 2. Instruction Pipelining: (value % 10) and the pointer decrement can often 
     *    be executed in parallel by the CPU.
     * 3. Compact Assembly: Compiles to a single "Store with Post-Decrement" instruction 
     *    on supported architectures (like ARM or x86 with specific addressing modes).
     */
    
    do {
        *cursor-- = (char)('0' + (value % 10));
        value /= 10;
    } while (value != 0);

    /* cursor now sits left of first digit; digits start at cursor + 1. */
    char *digits_start = cursor + 1;

    /* Fill left-of-digits with spaces until we find special_char or reach buf_start. */
    while (cursor >= buf_start && *cursor != special_char) {
        *cursor-- = ' ';
    }

    return digits_start;
}

/*
 * normalize_pedal_axis:
 *
 *   Map a raw hardware pedal reading into a common "travel space" where:
 *
 *       0       = pedal at rest (idle)
 *       axisMax = pedal fully depressed
 *
 *   For Fanatec ClubSport V2 the hardware reports inverted values
 *   in raw mode (idle near axisMax, pressed near 0). When
 *   axis_normalization_enabled is non-zero we simply mirror the
 *   range around axisMax:
 *
 *       normalized = axisMax - raw
 *
 *   If your hardware already reports 0..axisMax in that order, start
 *   the program with:
 *       --no-axis-normalization
 *   and the raw values will be used directly.
 *
 *   This helper is in the hot path, so we keep it branch-light and inline.
 */
static inline DWORD
normalize_pedal_axis(int axis_normalization_enabled, DWORD raw_value, DWORD axis_max)
{
    /* axis_max is constant per run; this branch is extremely predictable. */
    if (axis_normalization_enabled)
        return axis_max - raw_value;    /* Inverted hardware -> normalize. */

    return raw_value;                   /* Already in 0..axis_max order.   */
}



/*
 * Send Speak Windows Pipe Command via IPC
 * Requires my TelemetryVibShaker/WebScripts/WaitFor-Json-Commands.ps1
 * IPC with optional Timestamped Logging.
 */
static void
SpeakIPC(const char *text, size_t text_len)
{    
    static const char pipe_name[] = "\\\\.\\pipe\\ipc_pipe_vr_server_commands";
    static const char prefix[]    = "SPEAK ";

    char buffer[512];
    size_t prefix_len = sizeof(prefix) - 1;

    /* Safety check: +1 for the newline */
    assert(prefix_len + text_len + 1 < sizeof(buffer)); /* text is not read from config files where it could be too long, debug, verify and go fast */

    /* Copy prefix */
    memcpy(buffer, prefix, prefix_len);
    
    /* Copy text */
    memcpy(buffer + prefix_len, text, text_len);
    
    /* Append Newline (required by StreamReader.ReadLine on the server) */
    buffer[prefix_len + text_len] = '\n'; 
        
    /* Connect and send pipe command */
    HANDLE hPipe = CreateFileA(
        pipe_name,
        GENERIC_WRITE,
        0,              
        NULL,           
        OPEN_EXISTING,  
        0,              
        NULL
    );

    if (hPipe != INVALID_HANDLE_VALUE) {
        DWORD written;
        /* Write the total length: prefix + text + newline */
        WriteFile(hPipe, buffer, (DWORD)(prefix_len + text_len + 1), &written, NULL);
        CloseHandle(hPipe);
    }
}




/* Fire-and-forget text-to-speech helper.
 * Using CreateProcessA (no snprintf, no shell). 
 * Caller passes a NUL-terminated text string (no extra quoting required).
 * Always make sure exe + arg_prefix + text + 2 <= 512.
 */
static void
SpeakExternal(const char *text, size_t text_len)
{
    /* Executable path (constant). Using a static array so sizeof gives literal size if needed. */
    static const char exe[] =
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";

    /* Argument prefix (notice no trailing closing-quote) */
    static const char arg_prefix[] =
        "dummy1stArg -ExecutionPolicy Bypass -File .\\saySomething.ps1 \""; /* convention dictates that argv[0] should be the name of the executable */

    /* Mutable buffer for CreateProcess lpCommandLine; must be writable. */
    char cmdline[512];

    size_t prefix_len = sizeof(arg_prefix) - 1; /* exclude NUL */
    size_t effective_cmdline_len = prefix_len + text_len;

    /* Need space for prefix + text + closing quote + final NUL. */
    assert(effective_cmdline_len + 2 < sizeof(cmdline)); // text is not read from config files where it could be too long, debug and verify 

    /* Copy prefix and text into writable buffer. Use memcpy to avoid formatted I/O. */
    memcpy(cmdline, arg_prefix, prefix_len);
    memcpy(cmdline + prefix_len, text, text_len);

    /* close the quoted argument and NUL-terminate */
    cmdline[effective_cmdline_len++] = '"';
    cmdline[effective_cmdline_len] = '\0';

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    /* CreateProcessA will modify cmdline; that's why we used a writable buffer. 
       We pass exe as lpApplicationName to avoid shell parsing and reduce ambiguity. */
    if (CreateProcessA(
            exe,            /* lpApplicationName */
            cmdline,        /* lpCommandLine (writable) */
            NULL, NULL,     /* process/security attrs */
            TRUE,          /* inherit handles */
            0,              /* dwCreationFlags */
            NULL, NULL,     /* environment, current directory */
            &si,
            &pi)) {
        /* Close handles promptly; we don't need to wait. */
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}


/* 
 * Helper macro to call Report() with the compile-time length.
 * Works for string literals and static char arrays.
 */
#define ALERT(msg) Alert(msg, sizeof(msg) - 1, &st, 1)

/* 
 * Reports important message with print
 * If --tts is enabled then uses TTS to speak the message.
 * Calls external process or IPC listener with SPEAK command
 */
static void
Alert(const char *text, size_t text_len, const PedalMonState *st, int should_log)
{
    assert(st != NULL);
    
    /* Log to console if requested */
    if (should_log) {
        SYSTEMTIME st;
        GetLocalTime(&st); /* Fast Win32 API (no CRT overhead) */

        /* 
         * Format: [yyyy-MM-dd HH:mm:ss] Text
         * "%.*s" prints exactly text_len characters.
         */
        printf("[%.4d-%.2d-%.2d %.2d:%.2d:%.2d] %.*s\n",
               st.wYear, st.wMonth, st.wDay,
               st.wHour, st.wMinute, st.wSecond,
               (int)text_len, text);
    }
    /* --------------------------------------------------------- */
    
    /* call the correct TTS if required*/
    if (st->tts_enabled) 
        st->ipc_enabled?(void)SpeakIPC(text, text_len): (void)SpeakExternal(text, text_len);                
}


/*
 * FindJoystick:
 *   Iterate joystick devices and return the ID whose VID/PID matches.
 *   Returns:
 *     >= 0  -> joystick ID
 *     -1    -> not found
 */
static int
FindJoystick(int targetVid, int targetPid)
{
    JOYCAPS jc;
    int numDevs = joyGetNumDevs();

    for (int i = 0; i < numDevs; i++) {
        if (joyGetDevCaps(i, &jc, sizeof(jc)) == JOYERR_NOERROR) {
            if (jc.wMid == targetVid && jc.wPid == targetPid) {
                return i;
            }
        }
    }
    return -1;
}

/*
 * ParseCommandLine:
 *   Configures:
 *     - joystick ID or VID/PID (for auto-reconnect),
 *     - winmm flags,
 *     - iterations, margin, sleep,
 *     - gas monitoring and tuning parameters,
 *     - axis normalization & debug behavior,
 *     - clutch sample count,
 *     - estimation/auto-adjust flags,
 *     - process priority / affinity.
 *     - telemetry, tts, and console output flags.
 */
static void
ParseCommandLine(int argc,
                 char **argv,
                 PedalMonState *st)
{
    int c;
    int j = 0; /* whether joystick was explicitly set */

    HANDLE hProcess = GetCurrentProcess();

    while (1) {
        /* 
         * We define long_options locally so we can point .flag to st-> fields.
         */
        struct option long_options[] = {
            /* Feature flags */
            {"verbose",                       no_argument,       &st->verbose_flag,               1},
            {"brief",                         no_argument,       &st->verbose_flag,               0},
            {"monitor-clutch",                no_argument,       &st->monitor_clutch,             1},
            {"monitor-gas",                   no_argument,       &st->monitor_gas,                1},
            {"estimate-gas-deadzone-out",     no_argument,       &st->estimate_gas_deadzone_enabled, 1},
            {"no-axis-normalization",         no_argument,       &st->axis_normalization_enabled, 0},
            {"debug-raw",                     no_argument,       &st->debug_raw_mode,             1},

            /* Telemetry and Output Control */
            {"telemetry",                     no_argument,       &st->telemetry_enabled,          1},
            {"tts",                           no_argument,       &st->tts_enabled,                1},
            {"no-tts",                        no_argument,       &st->tts_enabled,                0},
            {"ipc",                           no_argument,       &st->ipc_enabled,                1},                        
            {"no-console-banner",             no_argument,       &st->no_console_banner,          1},

            /* Generic options (use short codes) */
            {"help",                          no_argument,       0, 'h'},
            {"no_buffer",                     no_argument,       0, 'n'},
            {"iterations",                    required_argument, 0, 'i'},
            {"margin",                        required_argument, 0, 'm'},
            {"flags",                         required_argument, 0, 'f'},
            {"sleep",                         required_argument, 0, 's'},
            {"joystick",                      required_argument, 0, 'j'},
            {"idle",                          no_argument,       0, 'd'},
            {"belownormal",                   no_argument,       0, 'b'},
            {"affinitymask",                  required_argument, 0, 'a'},

            /* Gas tuning */
            {"gas-deadzone-in",               required_argument, 0, '1'},
            {"gas-deadzone-out",              required_argument, 0, '2'},
            {"gas-window",                    required_argument, 0, '3'},
            {"gas-cooldown",                  required_argument, 0, '4'},
            {"gas-timeout",                   required_argument, 0, '5'},
            {"gas-min-usage",                 required_argument, 0, '6'},
            {"adjust-deadzone-out-with-minimum", required_argument, 0, '8'},

            /* Clutch tuning */
            {"clutch-repeat",                 required_argument, 0, '7'},

            /* Reconnect via VID/PID */
            {"vendor-id",                     required_argument, 0, 'v'},
            {"product-id",                    required_argument, 0, 'p'},

            {0, 0, 0, 0}
        };

        int option_index = 0;

        c = getopt_long(argc,
                        argv,
                        "hnf:i:j:m:s:",
                        long_options,
                        &option_index);

        if (c == -1)
            break;

        switch (c) {
        case 0:
            /* Flag-only options handled by getopt_long (verbose, monitor, etc.). */
            if (long_options[option_index].flag != 0)
                break;
            break;

        case 'h':
HELP:
            puts("Usage: fanatecmonitor.exe [--monitor-clutch] [--monitor-gas] [options]\n");

            puts("   Auto-Reconnect:");
            puts("       --vendor-id HEX:    Vendor ID (e.g. 0EB7) for auto-reconnection.");
            puts("       --product-id HEX:   Product ID (e.g. 1839) for auto-reconnection.\n");

            puts("   Clutch & Gas:");
            puts("       --monitor-clutch:   Enable Clutch spike monitoring.");
            puts("       --monitor-gas:      Enable Gas drift monitoring.\n");

            puts("   Telemetry & UI:");
            puts("       --telemetry:        Enable shared-memory telemetry for external tools (PedBridge / PedDash).");
            puts("       --tts:              Enable Text-to-Speech alerts (default).");
            puts("       --no-tts:           Disable Text-to-Speech alerts, when telemetry is used instead.");
            puts("       --ipc:              Enable dispatchig tts alerts via IPC SPEAK.");
            puts("       --no-console-banner: Suppress startup/status banners in console.\n");

            puts("   General:");
            puts("       --verbose:          Enable verbose logging (prints axis values, config, etc.).");
            puts("       --brief:            Disable verbose logging (default unless --verbose is used).");
            puts("       --joystick ID:      Initial Joystick ID (0-15).");
            puts("       --iterations N:     Number of iterations. Default=1. Use 0 for infinite loop.");
            puts("       --sleep MS:         Wait time (ms) between iterations. Default=1000. Must be > 0.");
            puts("       --flags N:          dwFlags. Default=JOY_RETURNALL.");
            puts("                           Use 266 for JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY.");
            puts("       --margin N:         Tolerance (0-100) for clutch stickiness. Default=5.");
            puts("       --no_buffer:        Disable standard output buffering.");
            puts("       --no-axis-normalization:");
            puts("                           Do NOT invert pedal axes; use raw 0..axisMax values.");
            puts("                           Default behavior is to normalize so 0=idle, max=full.");
            puts("       --debug-raw:        In verbose mode, print raw and normalized axis values.\n");

            puts("   Performance & Priority:");
            puts("       --idle:             Set process priority to IDLE.");
            puts("       --belownormal:      Set process priority to BELOW_NORMAL.");
            puts("       --affinitymask N:   Decimal mask for CPU core affinity.\n");

            puts("   Gas Tuning Options (monitor-gas only):");
            puts("       --gas-deadzone-in:  % Idle Deadzone (0-100). Default=5.");
            puts("       --gas-deadzone-out: % Full-throttle threshold (0-100). Default=93.");
            puts("       --gas-window:       Seconds to wait for Full Throttle. Default=30.");
            puts("       --gas-timeout:      Seconds idle to assume Menu/Pause. Default=10.");
            puts("       --gas-cooldown:     Seconds between alerts. Default=60.");
            puts("       --gas-min-usage:    % minimum gas usage in a window before drift alert.");
            puts("                           Default=20. Increase if you race gently (no full-throttle).");
            puts("       --estimate-gas-deadzone-out:");
            puts("                           Estimate and print suggested --gas-deadzone-out from observed");
            puts("                           maximum gas travel over time. Requires --monitor-gas.");
            puts("       --adjust-deadzone-out-with-minimum N:");
            puts("                           Auto-decrease gas-deadzone-out to match observed maximum,");
            puts("                           but never below N (0-100). Requires --monitor-gas and");
            puts("                           --estimate-gas-deadzone-out.\n");

            puts("   Clutch Tuning Options (monitor-clutch only):");
            puts("       --clutch-repeat N:  Consecutive samples required for clutch noise alert.");
            puts("                           Default=4. Increase if you lower --sleep.\n");

            exit(EXIT_SUCCESS);
            break;

        case 'n':
            /* Disable stdout buffering if requested (useful for logging). */
            setvbuf(stdout, NULL, _IONBF, 0);
            break;

        case 'm':
            st->margin = (UINT)atoi(optarg);
            break;

        case 'f':
            st->joy_Flags = (DWORD)atoi(optarg);
            break;

        case 's':
            st->sleep_Time = (UINT)atoi(optarg);
            break;

        case 'i':
            st->iterations = (UINT)atoi(optarg);
            break;

        case 'j':
            st->joy_ID = (UINT)atoi(optarg);
            j = 1;
            break;

        case 'd':
            SetPriorityClass(hProcess, IDLE_PRIORITY_CLASS);
            break;

        case 'b':
            SetPriorityClass(hProcess, BELOW_NORMAL_PRIORITY_CLASS);
            break;

        case 'a': {
            DWORD_PTR m = (DWORD_PTR)atoi(optarg);
            SetProcessAffinityMask(hProcess, m);
            break;
        }

        /* Gas tuning */
        case '1':
            st->gas_deadzone_in = atoi(optarg);
            break;
        case '2':
            st->gas_deadzone_out = atoi(optarg);
            break;
        case '3':
            st->gas_window = atoi(optarg);
            break;
        case '4':
            st->gas_cooldown = atoi(optarg);
            break;
        case '5':
            st->gas_timeout = atoi(optarg);
            break;
        case '6':
            st->gas_min_usage_percent = atoi(optarg);
            break;
        case '8':
            st->auto_gas_deadzone_minimum = atoi(optarg);
            st->auto_gas_deadzone_enabled = 1;
            break;

        /* Clutch tuning */
        case '7':
            st->clutch_repeat_required = atoi(optarg);
            break;

        /* VID/PID for reconnect (hex) */
        case 'v':
            st->target_vendor_id = (int)strtol(optarg, NULL, 16);
            break;
        case 'p':
            st->target_product_id = (int)strtol(optarg, NULL, 16);
            break;

        case '?':
            /* getopt_long already printed an error. */
            break;

        default:
            abort();
        }
    }

    /* Minimal validation for obviously bad values. */
    if (st->joy_ID > 15 && st->target_vendor_id == 0) {
        fprintf(stderr, "Error: Invalid Joystick ID (0-15).\n");
        exit(EXIT_FAILURE);
    }

    if (st->margin > 100U) {
        fprintf(stderr, "Error: margin must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_deadzone_in < 0 || st->gas_deadzone_in > 100) {
        fprintf(stderr, "Error: gas-deadzone-in must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_deadzone_out < 0 || st->gas_deadzone_out > 100) {
        fprintf(stderr, "Error: gas-deadzone-out must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_window <= 0) {
        fprintf(stderr, "Error: gas-window must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_timeout <= 0) {
        fprintf(stderr, "Error: gas-timeout must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_cooldown <= 0) {
        fprintf(stderr, "Error: gas-cooldown must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (st->gas_min_usage_percent < 0 || st->gas_min_usage_percent > 100) {
        fprintf(stderr, "Error: gas-min-usage must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (st->clutch_repeat_required <= 0) {
        fprintf(stderr, "Error: clutch-repeat must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (st->auto_gas_deadzone_enabled) {
        if (st->auto_gas_deadzone_minimum < 0 || st->auto_gas_deadzone_minimum > 100) {
            fprintf(stderr, "Error: adjust-deadzone-out-with-minimum must be 0-100.\n");
            exit(EXIT_FAILURE);
        }
    }

    if (st->estimate_gas_deadzone_enabled && !st->monitor_gas) {
        fprintf(stderr, "Error: --estimate-gas-deadzone-out requires --monitor-gas.\n");
        exit(EXIT_FAILURE);
    }

    if (st->auto_gas_deadzone_enabled && !st->monitor_gas) {
        fprintf(stderr, "Error: --adjust-deadzone-out-with-minimum requires --monitor-gas.\n");
        exit(EXIT_FAILURE);
    }

    /*
     * Auto-adjust is implemented on top of the estimator. Requiring both
     * flags keeps behavior explicit and avoids surprising "quiet" auto-adjust.
     */
    if (st->auto_gas_deadzone_enabled && !st->estimate_gas_deadzone_enabled) {
        fprintf(stderr,
                "Error: --adjust-deadzone-out-with-minimum also requires "
                "--estimate-gas-deadzone-out.\n");
        exit(EXIT_FAILURE);
    }

    /*
     * Sanity check: it does not make sense to request an auto-adjust minimum
     * that is higher than the current gas-deadzone-out value. In that case
     * the auto-adjust condition can never be satisfied.
     */
    if (st->auto_gas_deadzone_enabled &&
        st->auto_gas_deadzone_minimum > st->gas_deadzone_out) {
        fprintf(stderr,
                "Error: adjust-deadzone-out-with-minimum (%d) must be <= gas-deadzone-out (%d).\n",
                st->auto_gas_deadzone_minimum,
                st->gas_deadzone_out);
        exit(EXIT_FAILURE);
    }

    /*
     * Protect against sleep=0, which would effectively spin in a tight loop.
     * This is almost never desired in a companion monitor process.
     */
    if (st->sleep_Time == 0) {
        fprintf(stderr, "Error: sleep must be > 0 ms.\n");
        exit(EXIT_FAILURE);
    }

    /*
     * If joystick ID is not provided but VID/PID are, we will attempt auto-detection.
     * If neither joystick ID nor VID/PID are provided, show help.
     */
    if (!j && (st->target_vendor_id == 0))
        goto HELP;
}


/*
 * Telemetry_Init:
 * Sets up shared memory and event resources if enabled.
 */
static void
Telemetry_Init(PedalMonState *st)
{
    if (!st->telemetry_enabled)
        return;
    
/* 
     * Create a Security Descriptor that grants "Everyone" (World) full access.
     * This is required if the C program runs as Admin/SYSTEM but the consumer
     * (PowerShell) runs as a standard user.
     */
    SECURITY_ATTRIBUTES sa;
    ZeroMemory(&sa, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = FALSE; /* Don't inherit to child processes */
    
    /* SDDL String: DACL: "D:(A;;GA;;;WD)" = (Allow; Generic All; World/Everyone) */
    
    /* 
    * REFERENCE ONLY SDDL: "D:(A;;GRGW;;;WD)"
    * Allow (A) Generic Read + Generic Write (GRGW) to World (WD).
    * This removes the "Owner" check and lets anyone who can see it, write to it.
    */
    
    /* SDDL String: "D:(A;;0x100006;;;AU)S:(ML;;NW;;;LW)"
     * 
     * This string configures two security layers to ensure cross-process access
     * regardless of whether the program runs as Admin (High Integrity) or 
     * Standard User (Medium Integrity).
     *
     * 1. DACL "D:(A;;0x100006;;;AU)"
     *    - Trustee: AU (Authenticated Users).
     *    - Access Mask: 0x100006
     *        0x100000 (SYNCHRONIZE)       -> Allows Waiting on the Event.
     *        0x000004 (SECTION_MAP_READ)  -> Allows Reading Memory.
     *        0x000002 (SECTION_MAP_WRITE) -> Allows Writing Memory.
     *    
     *    We grant Read/Write/Sync to any Authenticated User to ensure no 
     *    permission bottlenecks between the C program and PowerShell.
     *
     * 2. SACL "S:(ML;;NW;;;LW)"
     *    - ML: Mandatory Label (Integrity Level).
     *    - LW: Low Integrity Level.
     *    - NW: No-Write-Up (Standard policy).
     *
     *    CRITICAL FIX: By explicitly labeling this object as "Low Integrity", 
     *    we prevent Windows Mandatory Integrity Control (MIC) from blocking access.
     *    This allows a Standard User process (Medium Integrity) to open/modify 
     *    this object even if it was originally created by an Administrator 
     *    (High Integrity).
     */
    
/* 
     * SDDL String: "D:(A;;GA;;;WD)"
     * 
     * Reverted to granting "Generic All" (GA) to "Everyone" (WD) to handle
     * the "Zombie Object" scenario.
     *
     * Scenario:
     *   1. C program creates the memory/event.
     *   2. PowerShell connects and holds an open handle.
     *   3. C program is restarted (Ctrl+C then run again).
     *   4. Because PowerShell holds the handle, the kernel object persists.
     *   5. The new C instance attaches to this EXISTING object.
     *
     * Why the previous "0x100006" permission failed:
     *   The C program calls MapViewOfFile with FILE_MAP_ALL_ACCESS.
     *   The specific mask 0x100006 granted Read/Write but missed other required
     *   rights (like READ_CONTROL or SECTION_QUERY). When the C program tried
     *   to re-attach with "ALL_ACCESS", the OS blocked it with Error 5.
     *
     * Solution:
     *   By using "GA" (Generic All), we ensure that if the object stays alive
     *   in memory, the restarting C program has full permission to re-open
     *   and map it with FILE_MAP_ALL_ACCESS without Access Denied errors.
     */    
             
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(            
            "D:(A;;GA;;;WD)",  
            SDDL_REVISION_1, 
            &sa.lpSecurityDescriptor, 
            NULL)) {
        fprintf(stderr, "Critical Error: Failed to create security descriptor (%lu).\n", GetLastError()); /* always print this type of error */
        sa.lpSecurityDescriptor = NULL;
        exit(EXIT_FAILURE); 
    }

    /* --------------------------------------------------------- */    

    /* Create/Open File Mapping backed by the paging file */
    g_hTelemetryMap = CreateFileMappingA(
        INVALID_HANDLE_VALUE,
        &sa,
        PAGE_READWRITE,
        0,
        sizeof(PedalMonState),
        PEDMON_TELEMETRY_MAPPING_NAME
    );

    if (!g_hTelemetryMap) {
        fprintf(stderr, "Critical Error: Failed to create file mapping (%lu).\n", GetLastError()); /* always print this type of error */
        exit(EXIT_FAILURE); /* this will cleanup sa */
    }

    /* Map the view */
    g_shared_st = (PedalMonState *)MapViewOfFile(
        g_hTelemetryMap,
        FILE_MAP_ALL_ACCESS,
        0,
        0,
        sizeof(PedalMonState)
    );

    if (!g_shared_st) {
        fprintf(stderr, "Critical Error: Failed to map view (%lu).\n", GetLastError()); /* always print this type of error */
        CloseHandle(g_hTelemetryMap);
        g_hTelemetryMap = NULL;
        exit(EXIT_FAILURE); /* this will cleanup sa */
    }

    /* Create/Open the sync Event */
    /* Using auto-reset event (FALSE for manual reset) */
    g_hTelemetryEvent = CreateEventA(
        &sa,   /* <--- Custom Security Attributes */
        FALSE, /* Auto-reset */
        FALSE, /* Initial state unsignaled */
        PEDMON_TELEMETRY_EVENT_NAME
    );

    if (!g_hTelemetryEvent) {
        fprintf(stderr, "Critical Error: Failed to create event (%lu).\n", GetLastError()); /* always print this type of error */
        UnmapViewOfFile(g_shared_st);
        g_shared_st = NULL;
        CloseHandle(g_hTelemetryMap);
        g_hTelemetryMap = NULL;
        st->telemetry_enabled = 0;
        exit(EXIT_FAILURE); /* this will cleanup sa */
    }
    
    /* Cleanup Security Descriptor (no longer needed after creation) */
    if (sa.lpSecurityDescriptor) {
        LocalFree(sa.lpSecurityDescriptor);
    }    

    if (st->verbose_flag) printf("Telemetry: Synch-Event and Shared memory initialized [%s].\n", PEDMON_TELEMETRY_MAPPING_NAME); 
}

/*
 * Telemetry_Publish:
 * Copies the current state to shared memory and signals the event.
 * Must be called when the state is consistent (end of loop iteration).
 */
static void
Telemetry_Publish(PedalMonState *st)
{
    if (st->telemetry_enabled && g_shared_st && g_hTelemetryEvent) {
        st->producer_notify_ms = GetTickCount();
        st->telemetry_sequence++;
        
        /* Copy entire state struct to shared memory */
        *g_shared_st = *st;
        
        /* Signal consumers */
        SetEvent(g_hTelemetryEvent);
    }
}

/*
 * Telemetry_Shutdown:
 * Cleans up shared memory resources.
 */
static void
Telemetry_Shutdown(PedalMonState *st)
{
    if (g_shared_st) {
        UnmapViewOfFile(g_shared_st);
        g_shared_st = NULL;
    }
    if (g_hTelemetryEvent) {
        CloseHandle(g_hTelemetryEvent);
        g_hTelemetryEvent = NULL;
    }
    if (g_hTelemetryMap) {
        CloseHandle(g_hTelemetryMap);
        g_hTelemetryMap = NULL;
    }
    // (void)st; /* Unused in shutdown, but kept for symmetry */
}


int
main(int argc, char **argv)
{
    /*
     * Initialize PedalMonState with default values.
     */
    PedalMonState st = {
        /* Configuration / feature flags (keep existing defaults). */
        .verbose_flag                  = 0,
        .monitor_clutch                = 0,
        .monitor_gas                   = 0,

        .gas_deadzone_in               = 5,
        .gas_deadzone_out              = 93,
        .gas_window                    = 30,
        .gas_cooldown                  = 60,
        .gas_timeout                   = 10,
        .gas_min_usage_percent         = 20,

        .axis_normalization_enabled    = 1,
        .debug_raw_mode                = 0,
        .clutch_repeat_required        = 4,

        .estimate_gas_deadzone_enabled = 0,
        .auto_gas_deadzone_enabled     = 0,
        .auto_gas_deadzone_minimum     = 0,

        .gas_physical_pct              = 0,
        .clutch_physical_pct           = 0,
        .gas_logical_pct               = 0,
        .clutch_logical_pct            = 0,	

        .target_vendor_id              = 0,
        .target_product_id             = 0,

        /* Telemetry and TTS defaults */
        .telemetry_enabled             = 0,
        .tts_enabled                   = 1, /* Default enabled */
        .ipc_enabled                   = 0, /* Default disabled */
        .no_console_banner             = 0,

        /* CLI defaults (legacy behavior). */
        /* joy_ID: "impossible" 17 to force explicit selection or VID/PID usage. */
        .joy_ID                        = 17, 
        .joy_Flags                     = JOY_RETURNALL,
        .iterations                    = 1,     /* 0 means infinite loop. */
        .margin                        = 5,     /* % for clutch stickiness. */
        .sleep_Time                    = 1000,
        
        /* Runtime state can be zero-initialized or set explicitly here. */
        .lastClutchValue               = 0,
        .repeatingClutchCount          = 0,
        .isRacing                      = FALSE,
        .peakGasInWindow               = 0,
        .best_estimate_percent         = 100U,
        .last_printed_estimate         = 100U,
        .estimate_window_peak_percent  = 0U,
        .last_estimate_print_time      = 0,
        .iLoop                         = 0
    };

    /* Initialize timing related runtime state after struct init */
    st.lastFullThrottleTime       = GetTickCount();
    st.lastGasActivityTime        = GetTickCount();
    st.lastGasAlertTime           = 0;
    st.estimate_window_start_time = GetTickCount();

    ParseCommandLine(argc, argv, &st);

    
    /* Single-instance guard: prevent accidentally launching multiple monitors. */
    HANDLE hMutex = CreateMutexA(NULL, TRUE, "fanatec_monitor_single_instance_mutex");
    if (hMutex == NULL || GetLastError() == ERROR_ALREADY_EXISTS) {
        ALERT("Error.  Another instance of Fanatec Monitor is already running.");
        if (hMutex)
            CloseHandle(hMutex);
        exit(EXIT_FAILURE);
    }


    /* Optional auto-detect by VID/PID (if provided). */
    if (st.target_vendor_id != 0 && st.target_product_id != 0) {
        if (st.verbose_flag)
            printf("Looking for Controller VID:%X PID:%X...\n", st.target_vendor_id, st.target_product_id);

        int foundID = FindJoystick(st.target_vendor_id, st.target_product_id);
        if (foundID != -1) {
            st.joy_ID = (UINT)foundID;
            if (st.verbose_flag)
                printf("Found at ID: %u\n", st.joy_ID);
        } else {
            if (st.verbose_flag)
                printf("Not found at startup. Will use ID %u until error.\n", st.joy_ID);
        }
    }

    /*
     * Axis scaling:
     *   - In raw mode (JOY_RETURNRAWDATA), Fanatec pedals report 0..1023.
     *   - Otherwise we assume a standard 16-bit axis (0..65535).
     *
     * All subsequent logic uses normalized 0..axisMax values:
     *   0       = idle
     *   axisMax = full press
     */
    st.axisMax = (st.joy_Flags & JOY_RETURNRAWDATA) ? 1023 : 65535;

    /* -------------------- Command strings -------------------- */

    /* Clutch: fixed script, no numeric argument. */
    const char *clutch_command =
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe "
        "-ExecutionPolicy Bypass -File .\\sayRudder.ps1";

        
    

    /* -------------------- Device capabilities -------------------- */

    MMRESULT mr;
    JOYCAPS jc; /* Kept as local variable per rules */

    mr = joyGetDevCaps(st.joy_ID, &jc, sizeof(jc));
    if ( st.verbose_flag && mr == JOYERR_NOERROR) {
        printf("Monitoring ID=[%u] VID=[%hX] PID=[%hX]\n", st.joy_ID, jc.wMid, jc.wPid);
        printf("Axis Max: [%lu]\n", (unsigned long)st.axisMax);
        printf("Axis normalization: %s\n",
               st.axis_normalization_enabled ? "enabled (normalize inverted -> 0..max)"
                                          : "disabled (use raw 0..max)");
        if (st.monitor_gas) {
            printf("Gas Config: DZ In:%d%% Out:%d%% Window:%ds Timeout:%ds Cooldown:%ds MinUsage:%d%%\n",
                   st.gas_deadzone_in,
                   st.gas_deadzone_out,
                   st.gas_window,
                   st.gas_timeout,
                   st.gas_cooldown,
                   st.gas_min_usage_percent);
            if (st.estimate_gas_deadzone_enabled)
                printf("Gas Estimation: enabled (will print [Estimate] lines).\n");
            if (st.auto_gas_deadzone_enabled)
                printf("Gas Auto-Adjust: enabled (minimum=%d).\n", st.auto_gas_deadzone_minimum);
        }
        if (st.monitor_clutch) {
            printf("Clutch Config: Margin:%u%% Repeat:%d\n",
                   st.margin,
                   st.clutch_repeat_required);
        }
    }

    JOYINFOEX info; /* Kept as local variable per rules */
    info.dwSize  = sizeof(info);
    info.dwFlags = st.joy_Flags;

    /* -------------------- Clutch state -------------------- */

    st.axisMargin = st.axisMax * st.margin / 100;  /* Convert % margin to units. */

    /*
     * For clutch monitoring we require:
     *   - Gas axis to be in its "idle" band (gasValue <= gasIdleMax),
     *   - Clutch axis to be away from idle (clutchValue > 0),
     *   - The clutch axis to stay within axisMargin for several samples.
     *
     * This filters out normal clutch usage and noise while you're actively driving.
     */

    /* -------------------- Gas state -------------------- */

    /*
     * In normalized space:
     *   gasIdleMax:
     *     Maximum value considered "idle".
     *     Example: gas_deadzone_in=5, axisMax=1023 -> gasIdleMax ˜ 51.
     *   gasFullMin:
     *     Minimum value considered "full throttle".
     *     Example: gas_deadzone_out=93, axisMax=1023 -> gasFullMin ˜ 951.
     */
    st.gasIdleMax = st.axisMax * st.gas_deadzone_in  / 100;
    st.gasFullMin = st.axisMax * st.gas_deadzone_out / 100;

    /* Precompute timeouts in milliseconds to avoid repeated multiplications in the hot path. */
    st.gas_timeout_ms  = (DWORD)st.gas_timeout  * 1000U;
    st.gas_window_ms   = (DWORD)st.gas_window   * 1000U;
    st.gas_cooldown_ms = (DWORD)st.gas_cooldown * 1000U;

    if (!st.no_console_banner)
        printf("Fanatec Pedals Monitor started.\n");

    /* Initialize Telemetry if requested */
    Telemetry_Init(&st);

    /* -------------------- Main loop -------------------- */

    
        /* warning: iLoop will always be zero due to the short-circuit bellow when st.iterations == 0 */
	while (st.iterations == 0 || ++st.iLoop <= st.iterations) {

			
		/* Start of loop telemetry bookkeeping */
		st.producer_loop_start_ms = GetTickCount();

		/*
		 * Reset per-frame one-shot event flags.
		 *
		 * controller_disconnected is treated as a latched "current state":
		 *   0 = controller currently believed to be connected
		 *   1 = controller currently believed to be disconnected
		 *
		 * It is therefore NOT cleared here; only explicit disconnect /
		 * reconnect transitions change it.
		 */
		st.gas_alert_triggered    = 0;
		st.clutch_alert_triggered = 0;
		st.controller_reconnected = 0;  /* one-shot event */
		st.gas_estimate_decreased = 0;
		st.gas_auto_adjust_applied = 0;

		mr = joyGetPosEx(st.joy_ID, &info);


        /* ---------------- Error handling & reconnect ---------------- */

		if (mr != JOYERR_NOERROR) {
			printf("Error reading joystick (Code %u)\n", mr); /* critical error, no longer requires verbose */

			if (st.target_vendor_id != 0 && st.target_product_id != 0) {
				/* Only speak/attempt reconnect if VID/PID were provided. */
				ALERT("Controller disconnected. Waiting 60 seconds.");

				/* Event + state: Controller is now disconnected. */
				st.controller_disconnected = 1;
				st.controller_reconnected  = 0;
				st.last_disconnect_time_ms = GetTickCount();

				/* Publish a telemetry frame so PedBridge / PedDash see the disconnect. */
				Telemetry_Publish(&st);

				if (st.verbose_flag)
					printf("Entering Reconnection Mode...\n");

				while (1) {
					Sleep(60000); /* sleep 60 seconds to avoid busy-looping */

					int newID = FindJoystick(st.target_vendor_id, st.target_product_id);
					if (newID != -1) {
						st.joy_ID = (UINT)newID;
						ALERT("Controller found. Resuming monitoring.");

						/* Event: Controller Reconnected */
						st.controller_disconnected = 0;  /* back to "connected" state */
						st.controller_reconnected  = 1;  /* one-shot event flag */
						st.last_reconnect_time_ms  = GetTickCount();

						/* Publish a telemetry frame so the reconnect event is visible. */
						Telemetry_Publish(&st);

						if (st.verbose_flag)
							printf("Reconnected at ID %u\n", st.joy_ID);

						/* Reinitialize JOYINFOEX for the newly found device. */
						info.dwSize  = sizeof(info);
						info.dwFlags = st.joy_Flags;

						/*
						 * Recompute axisMax and gas thresholds in case flags
						 * or effective resolution changed for the new device.
						 */
						st.axisMax    = (st.joy_Flags & JOY_RETURNRAWDATA) ? 1023 : 65535;
						st.gasIdleMax = st.axisMax * st.gas_deadzone_in  / 100;
						st.gasFullMin = st.axisMax * st.gas_deadzone_out / 100;

						/* Reset gas/clutch and estimator state so we don't immediately alert. */
						st.lastFullThrottleTime         = GetTickCount();
						st.lastGasActivityTime          = GetTickCount();
						st.isRacing                     = FALSE;
						st.peakGasInWindow              = 0;
						st.lastClutchValue              = 0;
						st.repeatingClutchCount         = 0;
						st.best_estimate_percent        = 100U;
						st.last_printed_estimate        = 100U;
						st.estimate_window_peak_percent = 0U;
						st.estimate_window_start_time   = GetTickCount();
						st.last_estimate_print_time     = 0;

						break; /* Leave reconnect loop, resume main loop. */
					} else {
						ALERT("Controller not found. Retrying.");
						if (st.verbose_flag)
							printf("Scan failed. Retrying in 60s...\n");
					}
				}

				/* Skip the rest of this iteration; next iteration will read again. */
				continue;
			}

			/* If VID/PID not specified, we just skip processing this frame. */
		}


        if (mr == JOYERR_NOERROR) {
            st.currentTime = GetTickCount();

            /* Capture raw axis values once; normalize once per frame. */
            st.rawGas    = info.dwYpos;
            st.rawClutch = info.dwRpos;

            st.gasValue    = normalize_pedal_axis(st.axis_normalization_enabled, st.rawGas, st.axisMax);
            st.clutchValue = normalize_pedal_axis(st.axis_normalization_enabled, st.rawClutch, st.axisMax);

            /* 
             * UI Percentage Computation
             * These four fields provide standardized 0-100 values for the dashboard.
             */
            if (st.axisMax > 0) {
                /* Physical: Pure geometric travel */
                st.gas_physical_pct = (unsigned int)((100u * st.gasValue) / st.axisMax);
                st.clutch_physical_pct = (unsigned int)((100u * st.clutchValue) / st.axisMax);
            } else {
                st.gas_physical_pct = 0;
                st.clutch_physical_pct = 0;
            }

            /* Logical: In-game activity using gas deadzone thresholds for both pedals */
            st.gas_logical_pct = ComputeLogicalPct(st.gasValue, st.gasIdleMax, st.gasFullMin);
            st.clutch_logical_pct = ComputeLogicalPct(st.clutchValue, st.gasIdleMax, st.gasFullMin);
			
            if (st.verbose_flag) {
                if (st.debug_raw_mode) {
                    printf("%lu, gas_raw=%lu gas_norm=%lu, clutch_raw=%lu clutch_norm=%lu\n",
                           (unsigned long)st.currentTime,
                           (unsigned long)st.rawGas,
                           (unsigned long)st.gasValue,
                           (unsigned long)st.rawClutch,
                           (unsigned long)st.clutchValue);
                } else {
                    printf("%lu, gas=%lu, clutch=%lu\n",
                           (unsigned long)st.currentTime,
                           (unsigned long)st.gasValue,
                           (unsigned long)st.clutchValue);
                }
            }

            /* ---------------- 1. CLUTCH MONITORING ---------------- */

            if (st.monitor_clutch) {
                /*
                 * closure:
                 *   Absolute change in normalized clutch position between the current
                 *   sample and the previous one. Used as a "stickiness" metric:
                 *   if |delta| stays <= axisMargin for several consecutive samples,
                 *   we treat the clutch as stuck/noisy at that position.
                 */
                
                /*
                 * Only consider clutch noise when:
                 *   - Gas is at/near idle (gasValue <= gasIdleMax),
                 *   - Clutch axis is not fully released (clutchValue > 0).
                 */
                if ((st.gasValue <= st.gasIdleMax) && (st.clutchValue > 0)) {
                    /* Absolute difference without relying on abs()'s int-only signature. */
                    if (st.clutchValue >= st.lastClutchValue)
                        st.closure = (int)(st.clutchValue - st.lastClutchValue);
                    else
                        st.closure = (int)(st.lastClutchValue - st.clutchValue);

                    if (st.closure <= (int)st.axisMargin)
                        st.repeatingClutchCount++;
                    else
                        st.repeatingClutchCount = 0;
                } else {
                    st.repeatingClutchCount = 0;
                }

                st.lastClutchValue = st.clutchValue;

                /*
                 * Require several consecutive "stuck" samples to avoid
                 * reacting to transient noise.
                 */
                if (st.repeatingClutchCount >= st.clutch_repeat_required) {
                    /* Use ALERT macro: Handles logging, --tts check, and IPC/External selection */
                    ALERT("Rudder"); 
                    
                    /* Event: Clutch Alert */
                    st.clutch_alert_triggered    = 1;
                    // st.last_clutch_alert_time_ms = st.currentTime;
                    
                    st.repeatingClutchCount = 0;
                }
            }

            /* ---------------- 2. GAS MONITORING ---------------- */

            if (st.monitor_gas) {
                /* ---- Activity detection & "isRacing" state ---- */

                if (st.gasValue > st.gasIdleMax) {
                    /*
                     * We have meaningful throttle input (pedal moved out of idle band).
                     * If we were previously idle, start a new racing window.
                     */
                    if (!st.isRacing) {
                        st.lastFullThrottleTime = st.currentTime;
                        st.peakGasInWindow      = 0;
                        if (st.estimate_gas_deadzone_enabled) {
                            st.estimate_window_start_time   = st.currentTime;
                            st.estimate_window_peak_percent = 0U;
                        }
                        if (st.verbose_flag)
                            printf("Gas: Activity Resumed.\n");
                    }

                    st.isRacing = TRUE;
                    st.lastGasActivityTime = st.currentTime;
                } else {
                    /*
                     * Gas is in/near idle band.
                     * If we stay idle for longer than gas_timeout seconds, we
                     * assume the sim is paused or you're in a menu.
                     */
                    if (st.isRacing &&
                        (st.currentTime - st.lastGasActivityTime > st.gas_timeout_ms)) {
                        if (st.verbose_flag)
                            printf("Gas: Auto-Pause (Idle for %d s).\n", st.gas_timeout);
                        st.isRacing = FALSE;
                        if (st.estimate_gas_deadzone_enabled) {
                            st.estimate_window_start_time   = st.currentTime;
                            st.estimate_window_peak_percent = 0U;
                        }
                    }
                }

                /* ---- Performance/drift check ---- */

                if (st.isRacing) {
                    /* Track the deepest press (largest normalized gas value) in the current window. */
                    if (st.gasValue > st.peakGasInWindow)
                        st.peakGasInWindow = st.gasValue;

                    if (st.gasValue >= st.gasFullMin) {
                        /*
                         * We observed a "full throttle" (or close enough) event:
                         * - reset the window anchor (lastFullThrottleTime),
                         * - clear peakGasInWindow so the next window starts fresh.
                         */
                        st.lastFullThrottleTime = st.currentTime;
                        st.peakGasInWindow      = 0;
                    } else {
                        /*
                         * We haven't hit full throttle recently.
                         * Once gas_window seconds elapse since lastFullThrottleTime,
                         * we evaluate whether the *maximum* travel seen in this window
                         * is "suspiciously low".
                         */
                        if ((st.currentTime - st.lastFullThrottleTime) > st.gas_window_ms) {

                            /* Rate-limit alerts to at most one per gas_cooldown seconds. */
                            if ((st.currentTime - st.lastGasAlertTime) > st.gas_cooldown_ms) {

                                /* Compute travel as a percentage using integer math. */
                                st.percentReached =
                                    (unsigned int)((st.peakGasInWindow * 100U) / st.axisMax);

                                /*
                                 * Drift detection uses a strict ">" comparison vs.
                                 * gas_min_usage_percent, while the estimator later uses
                                 * a ">=" comparison. The drift alert is intentionally
                                 * slightly more conservative: we only trigger if the
                                 * peak usage clearly exceeds the configured minimum,
                                 * whereas the estimator is willing to treat a peak
                                 * exactly equal to the threshold as meaningful input.
                                 * This keeps the alert logic quieter while allowing
                                 * the estimator to learn from borderline windows.
                                 */
                                if (st.percentReached > (unsigned int)st.gas_min_usage_percent) {

                                    /* 
                                     * Construct simple text string for the Alert.
                                     * We need a buffer for "Gas *** percent".
                                     */
                                    static char gas_msg[] = "Gas ******* percent."; /* leaving additional spaces to have min buffer size = 11, safe for ints */
                                    
                                    /* 
                                     * Calculate pointer to the end of the "***" area.
                                     * So the digits area ends at index 10 (0-based).
                                     */
                                    char *end_of_digits = gas_msg + 10;

                                    /* Write the percentage into the string */
                                    append_digits_from_right(st.percentReached, ' ', end_of_digits, 11);

                                    /* 
                                     * Trigger Alert. 
                                     * This will Log to console (should_log=1) AND Speak (via IPC or External).
                                     * We removed the manual 'puts' to avoid double-logging.
                                     */
                                    ALERT(gas_msg); /* gas is being suspiciously low */

                                    /* Event: Gas Alert Triggered */
                                    st.gas_alert_triggered    = 1;
                                    // st.last_gas_alert_time_ms = st.currentTime;

                                    /* BUG FIX: Update the timestamp so the cooldown actually works */
                                    st.lastGasAlertTime = st.currentTime;
                                }
                            }
                        }
                    }

                    /* ---- Gas deadzone-out estimation and optional auto-adjust ---- */

                    if (st.estimate_gas_deadzone_enabled) {
                        /*
                         * Update peak usage within the current estimation window.
                         * We only care about gas values above the idle band.
                         */
                        if (st.gasValue > st.gasIdleMax) {
                            st.currentPercent =
                                (unsigned int)((st.gasValue * 100U) / st.axisMax);

                            if (st.currentPercent > st.estimate_window_peak_percent)
                                st.estimate_window_peak_percent = st.currentPercent;
                        }

                        /*
                         * When an estimation window of approximately gas_cooldown
                         * seconds has elapsed, evaluate whether the observed peak
                         * suggests a lower --gas-deadzone-out value.
                         */
                        if ((st.currentTime - st.estimate_window_start_time) >= st.gas_cooldown_ms) {
                            /*
                             * Estimation uses a ">=" comparison against
                             * gas_min_usage_percent. The estimator is intentionally
                             * slightly more permissive than the drift alert:
                             * if the peak usage is exactly equal to the minimum
                             * threshold, it can still provide useful information
                             * about the pedal's reachable maximum, even if we
                             * prefer not to raise a user-facing drift alert in
                             * that borderline case.
                             */
                            if (st.estimate_window_peak_percent >= (unsigned int)st.gas_min_usage_percent) {
                                unsigned int candidate = st.estimate_window_peak_percent;

                                if (candidate < st.best_estimate_percent) {
                                    st.best_estimate_percent = candidate;

                                    /* Always print when our best estimate decreases, but
                                     * at most once per gas_cooldown interval.
                                     */
                                    if (st.best_estimate_percent < st.last_printed_estimate &&
                                        (st.currentTime - st.last_estimate_print_time) >= st.gas_cooldown_ms) {
                                                                                
                                        /* Notify the user via TTS */                                        
                                        /* reserve enough room: at least 11 bytes for uint32 (10 digits + NUL) but we now best_estimate_percent <= 100 */
                                        static char speak_buf[] = "New deadzone estimation:*** percent."; /* buffer always larger than 11 */
                                        char *last_valid = speak_buf + 26; /* now we are pointing at the last '*' */

                                        /* append number in-place and fill gap with spaces up to ':' */
                                        append_digits_from_right(st.best_estimate_percent, ':', last_valid, sizeof(speak_buf));

                                        /* speak_buf now contains: "New deadzone estimation:87\0" (or digits placed at the right) */
                                        ALERT(speak_buf);

                                        /* Event: Estimate Decreased */
                                        st.gas_estimate_decreased       = 1;
                                        // st.last_estimate_speech_time_ms = st.currentTime;

                                        st.last_printed_estimate    = st.best_estimate_percent;
                                        st.last_estimate_print_time = st.currentTime;
                                    }

                                    /*
                                     * Optional auto-adjust:
                                     *   If enabled, decrease gas_deadzone_out to the new
                                     *   best_estimate_percent, but never below the user-
                                     *   supplied auto_gas_deadzone_minimum. This keeps
                                     *   the drift detector aligned with a degrading pedal
                                     *   without dropping to unrealistic values if the
                                     *   pedal just wasn't fully pressed in some session.
                                     *
                                     *   The ParseCommandLine validation ensures that:
                                     *     auto_gas_deadzone_minimum <= gas_deadzone_out
                                     *   so this condition is both meaningful and reachable.
                                     */
                                    if (st.auto_gas_deadzone_enabled &&
                                        st.best_estimate_percent < (unsigned int)st.gas_deadzone_out &&
                                        st.best_estimate_percent >= (unsigned int)st.auto_gas_deadzone_minimum) {

                                        st.gas_deadzone_out = (int)st.best_estimate_percent;
                                        st.gasFullMin       = st.axisMax * st.gas_deadzone_out / 100;

                                        printf("[AutoAdjust] gas-deadzone-out updated to %d (min=%d)\n",
                                               st.gas_deadzone_out,
                                               st.auto_gas_deadzone_minimum);

                                        /* Event: Auto Adjust Applied */
                                        st.gas_auto_adjust_applied  = 1;
                                        // st.last_auto_adjust_time_ms = st.currentTime;
                                    }
                                }
                            }

                            /* Start a new estimation window from this point. */
                            st.estimate_window_start_time   = st.currentTime;
                            st.estimate_window_peak_percent = 0U;
                        }
                    }
                }
            }
            
            /* 
             * Telemetry: Publish frame state to shared memory.
             * Done at the end of valid processing for this iteration.
             */
            Telemetry_Publish(&st);
            
        } /* if (mr == JOYERR_NOERROR) */

        /* 
         * Calculate loop duration for the *current* iteration.
         * This value will be available in the Telemetry state during the *next* publish.
         */
        st.fullLoopTime_ms = GetTickCount() - st.producer_loop_start_ms;

        Sleep(st.sleep_Time);
    }

    Telemetry_Shutdown(&st);

    /* Windows will do this on process exit, but explicit is good form. */
    ReleaseMutex(hMutex);
    CloseHandle(hMutex);

    return EXIT_SUCCESS;

}
