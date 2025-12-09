/*
 * File:   main.c
 * Author: rolex20
 * Updated by: Assistant
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
 * https://tia.mat.br/posts/2014/06/23/integer_to_string_conversion.html
 * 
 * License: https://github.com/rolex20/FanatecClubSportPedalsMonitor/blob/main/LICENSE
 * 
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "windows.h"


#include <getopt.h>
#include <stdint.h>

/* Flag set by ‘--verbose’. */
static int verbose_flag = 0;

/*
 * Feature toggles (set via command line):
 *   monitor_clutch: legacy clutch/rudder noise detection.
 *   monitor_gas:    gas pedal drift detection.
 */
static int monitor_clutch = 0;
static int monitor_gas    = 0;

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
static int gas_deadzone_in         = 5;
static int gas_deadzone_out        = 93;
static int gas_window              = 30;
static int gas_cooldown            = 60;
static int gas_timeout             = 10;
static int gas_min_usage_percent   = 20;

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
static int axis_normalization_enabled = 1;

/*
 * Debug mode:
 *   debug_raw_mode != 0:
 *       In verbose mode, print both raw and normalized values.
 */
static int debug_raw_mode = 0;

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
static int clutch_repeat_required = 4;

/*
 * Target device for auto-reconnect (0 means "not specified").
 * If both VID and PID are provided, we use them to re-find the device when disconnected.
 */
static int target_vendor_id  = 0;
static int target_product_id = 0;


/*
 * We use a dedicated buffer size for integer-to-string conversion.
 * 32 bytes is enough for 32-bit values plus a trailing space and NUL.
 */
#define INT_TO_STR_BUFFER_SIZE 32

/*
 * Optimized Integer to String Converter.
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
normalize_pedal_axis(DWORD raw_value, DWORD axis_max)
{
    /* axis_max is constant per run; this branch is extremely predictable. */
    if (axis_normalization_enabled)
        return axis_max - raw_value;    /* Inverted hardware -> normalize. */

    return raw_value;                   /* Already in 0..axis_max order.   */
}

/*
 * Fire-and-forget text-to-speech helper.
 * Used for relatively rare events (disconnects, etc.), so snprintf is fine.
 */
static void
Speak(const char *text)
{
    char cmd[512];

    snprintf(
        cmd,
        sizeof(cmd),
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe "
        "-ExecutionPolicy Bypass -File .\\saySomething.ps1 \"%s\"",
        text
    );

    system(cmd);
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
 *     - process priority / affinity.
 */
static void
ParseCommandLine(int argc,
                 char **argv,
                 UINT *joy_ID,
                 DWORD *joy_Flags,
                 UINT *iterations,
                 UINT *margin,
                 UINT *sleep_Time)
{
    int c;
    int j = 0; /* whether joystick was explicitly set */

    HANDLE hProcess = GetCurrentProcess();

    while (1) {
        static struct option long_options[] = {
            /* Feature flags */
            {"verbose",              no_argument,       &verbose_flag,              1},
            {"brief",                no_argument,       &verbose_flag,              0},
            {"monitor-clutch",       no_argument,       &monitor_clutch,            1},
            {"monitor-gas",          no_argument,       &monitor_gas,               1},
            {"no-axis-normalization",no_argument,       &axis_normalization_enabled,0},
            {"debug-raw",            no_argument,       &debug_raw_mode,            1},

            /* Generic options (use short codes) */
            {"help",                 no_argument,       0, 'h'},
            {"no_buffer",            no_argument,       0, 'n'},
            {"iterations",           required_argument, 0, 'i'},
            {"margin",               required_argument, 0, 'm'},
            {"flags",                required_argument, 0, 'f'},
            {"sleep",                required_argument, 0, 's'},
            {"joystick",             required_argument, 0, 'j'},
            {"idle",                 no_argument,       0, 'd'},
            {"belownormal",          no_argument,       0, 'b'},
            {"affinitymask",         required_argument, 0, 'a'},

            /* Gas monitor tuning */
            {"gas-deadzone-in",      required_argument, 0, '1'},
            {"gas-deadzone-out",     required_argument, 0, '2'},
            {"gas-window",           required_argument, 0, '3'},
            {"gas-cooldown",         required_argument, 0, '4'},
            {"gas-timeout",          required_argument, 0, '5'},
            {"gas-min-usage",        required_argument, 0, '6'},

            /* Clutch tuning */
            {"clutch-repeat",        required_argument, 0, '7'},

            /* Reconnect via VID/PID */
            {"vendor-id",            required_argument, 0, 'v'},
            {"product-id",           required_argument, 0, 'p'},

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

            puts("   General:");
            puts("       --joystick ID:      Initial Joystick ID (0-15).");
            puts("       --iterations N:     Number of iterations. Default=1. Use 0 for infinite loop.");
            puts("       --sleep MS:         Wait time (ms) between iterations. Default=1000.");
            puts("       --flags N:          dwFlags. Default=JOY_RETURNALL.");
            puts("                           Use 266 for JOY_RETURNRAWDATA | JOY_RETURNR | JOY_RETURNY.");
            puts("       --margin N:         Tolerance (0-100) for clutch stickiness. Default=5.");
            puts("       --no_buffer:        Disable standard output buffering.");
            puts("       --no-axis-normalization:");
            puts("                           Do NOT invert pedal axes; use raw 0..axisMax values.");
            puts("                           Default behavior is to normalize so 0=idle, max=full.");
            puts("       --verbose:          Enable verbose logging (prints axis values, config, etc).\n");
            puts("       --brief:            Disable verbose logging (Default unless --verbose is used).\n");
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
            puts("                           Default=20. Increase if you race gently (no full-throttle).\n");

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
            *margin = (UINT)atoi(optarg);
            break;

        case 'f':
            *joy_Flags = (DWORD)atoi(optarg);
            break;

        case 's':
            *sleep_Time = (UINT)atoi(optarg);
            break;

        case 'i':
            *iterations = (UINT)atoi(optarg);
            break;

        case 'j':
            *joy_ID = (UINT)atoi(optarg);
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
            gas_deadzone_in = atoi(optarg);
            break;
        case '2':
            gas_deadzone_out = atoi(optarg);
            break;
        case '3':
            gas_window = atoi(optarg);
            break;
        case '4':
            gas_cooldown = atoi(optarg);
            break;
        case '5':
            gas_timeout = atoi(optarg);
            break;
        case '6':
            gas_min_usage_percent = atoi(optarg);
            break;

        /* Clutch tuning */
        case '7':
            clutch_repeat_required = atoi(optarg);
            break;

        /* VID/PID for reconnect (hex) */
        case 'v':
            target_vendor_id = (int)strtol(optarg, NULL, 16);
            break;
        case 'p':
            target_product_id = (int)strtol(optarg, NULL, 16);
            break;

        case '?':
            /* getopt_long already printed an error. */
            break;

        default:
            abort();
        }
    }

    /* Minimal validation for obviously bad values. */
    if (*joy_ID > 15 && target_vendor_id == 0) {
        fprintf(stderr, "Error: Invalid Joystick ID (0-15).\n");
        exit(EXIT_FAILURE);
    }

    if (*margin > 100U) {
        fprintf(stderr, "Error: margin must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_deadzone_in < 0 || gas_deadzone_in > 100) {
        fprintf(stderr, "Error: gas-deadzone-in must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_deadzone_out < 0 || gas_deadzone_out > 100) {
        fprintf(stderr, "Error: gas-deadzone-out must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_window <= 0) {
        fprintf(stderr, "Error: gas-window must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_timeout <= 0) {
        fprintf(stderr, "Error: gas-timeout must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_cooldown <= 0) {
        fprintf(stderr, "Error: gas-cooldown must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    if (gas_min_usage_percent < 0 || gas_min_usage_percent > 100) {
        fprintf(stderr, "Error: gas-min-usage must be 0-100.\n");
        exit(EXIT_FAILURE);
    }

    if (clutch_repeat_required <= 0) {
        fprintf(stderr, "Error: clutch-repeat must be > 0.\n");
        exit(EXIT_FAILURE);
    }

    /*
     * If joystick ID is not provided but VID/PID are, we will attempt auto-detection.
     * If neither joystick ID nor VID/PID are provided, show help.
     */
    if (!j && (target_vendor_id == 0))
        goto HELP;
}

int
main(int argc, char **argv)
{
    /* Single-instance guard: prevent accidentally launching multiple monitors. */
    HANDLE hMutex = CreateMutex(NULL, TRUE, "fanatec_monitor_single_instance_mutex");
    if (hMutex == NULL || GetLastError() == ERROR_ALREADY_EXISTS) {
        system(
            "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe "
            "-ExecutionPolicy Bypass -File .\\sayDuplicateInstance.ps1"
        );
        perror("Instance already running.");
        if (hMutex)
            CloseHandle(hMutex);
        exit(EXIT_FAILURE);
    }

    /*
     * Defaults chosen to match legacy behavior:
     *   iterations: 1 by default (run once unless overridden).
     *   joy_ID:     "impossible" 17 to force explicit selection or VID/PID usage.
     */
    UINT  joy_ID     = 17;
    DWORD joy_Flags  = JOY_RETURNALL;
    UINT  iterations = 1;   /* Default=1; 0 means infinite loop. */
    UINT  margin     = 5;   /* % closure for clutch stickiness.  */
    UINT  sleep_Time = 1000;

    ParseCommandLine(argc, argv, &joy_ID, &joy_Flags, &iterations, &margin, &sleep_Time);

    /* Optional auto-detect by VID/PID (if provided). */
    if (target_vendor_id != 0 && target_product_id != 0) {
        if (verbose_flag)
            printf("Looking for Controller VID:%X PID:%X...\n", target_vendor_id, target_product_id);

        int foundID = FindJoystick(target_vendor_id, target_product_id);
        if (foundID != -1) {
            joy_ID = (UINT)foundID;
            if (verbose_flag)
                printf("Found at ID: %u\n", joy_ID);
        } else {
            if (verbose_flag)
                printf("Not found at startup. Will use ID %u until error.\n", joy_ID);
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
    DWORD axisMax = (joy_Flags & JOY_RETURNRAWDATA) ? 1023 : 65535;

    /* -------------------- Command strings -------------------- */

    /* 1. Clutch: fixed script, no numeric argument. */
    const char *clutch_command =
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe "
        "-ExecutionPolicy Bypass -File .\\sayRudder.ps1";

    /* 2. Gas: script requires a numeric argument (percentage reached). */
    char gas_command_line[512];
    strcpy(
        gas_command_line,
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe "
        "-ExecutionPolicy Bypass -File .\\sayGas.ps1 "
    );
    /*
     * gas_arg_ptr points just after ".ps1 ".
     * We overwrite from here with "NN " (percentReached + space).
     */
    char *gas_arg_ptr = gas_command_line + strlen(gas_command_line);

    /* -------------------- Device capabilities -------------------- */

    MMRESULT mr;
    JOYCAPS jc;

    mr = joyGetDevCaps(joy_ID, &jc, sizeof(jc));
    if (verbose_flag && mr == JOYERR_NOERROR) {
        printf("Monitoring ID=[%u] VID=[%hX] PID=[%hX]\n", joy_ID, jc.wMid, jc.wPid);
        printf("Axis Max: [%lu]\n", (unsigned long)axisMax);
        printf("Axis normalization: %s\n",
               axis_normalization_enabled ? "enabled (normalize inverted -> 0..max)"
                                          : "disabled (use raw 0..max)");
        if (monitor_gas) {
            printf("Gas Config: DZ In:%d%% Out:%d%% Window:%ds Timeout:%ds Cooldown:%ds MinUsage:%d%%\n",
                   gas_deadzone_in,
                   gas_deadzone_out,
                   gas_window,
                   gas_timeout,
                   gas_cooldown,
                   gas_min_usage_percent);
        }
        if (monitor_clutch) {
            printf("Clutch Config: Margin:%u%% Repeat:%d\n",
                   margin,
                   clutch_repeat_required);
        }
    }

    JOYINFOEX info;
    info.dwSize  = sizeof(info);
    info.dwFlags = joy_Flags;

    /* -------------------- Clutch state -------------------- */

    DWORD axisMargin = axisMax * margin / 100;  /* Convert % margin to units. */
    DWORD lastClutchValue      = 0;             /* Normalized clutch value (0..axisMax). */
    int   repeatingClutchCount = 0;

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
     *     Example: gas_deadzone_in=5, axisMax=1023 -> gasIdleMax ≈ 51.
     *   gasFullMin:
     *     Minimum value considered "full throttle".
     *     Example: gas_deadzone_out=93, axisMax=1023 -> gasFullMin ≈ 951.
     */
    DWORD gasIdleMax = axisMax * gas_deadzone_in  / 100;
    DWORD gasFullMin = axisMax * gas_deadzone_out / 100;

    /* Precompute timeouts in milliseconds to avoid repeated multiplications in the hot path. */
    DWORD gas_timeout_ms  = (DWORD)gas_timeout  * 1000U;
    DWORD gas_window_ms   = (DWORD)gas_window   * 1000U;
    DWORD gas_cooldown_ms = (DWORD)gas_cooldown * 1000U;

    /*
     * Gas state machine:
     *   isRacing:
     *     TRUE  -> we have seen gas activity recently; check for drift.
     *     FALSE -> either idle/menu or we haven't yet started a racing window.
     *
     *   peakGasInWindow:
     *     Highest normalized gas value seen since last "full throttle" event.
     *
     *   lastFullThrottleTime:
     *     When we last saw a value >= gasFullMin (i.e., pedal floored).
     *
     *   lastGasActivityTime:
     *     When we last saw gasValue > gasIdleMax (i.e., pedal moved out of idle band).
     *
     *   lastGasAlertTime:
     *     Throttle drift alerts are rate-limited by gas_cooldown seconds.
     */
    BOOL  isRacing             = FALSE;
    DWORD peakGasInWindow      = 0;
    DWORD lastFullThrottleTime = GetTickCount();
    DWORD lastGasActivityTime  = GetTickCount();
    DWORD lastGasAlertTime     = 0;   /* 0 means "no alert yet". */

    if (verbose_flag)
        printf("Monitoring loop starting.\n");

    /* -------------------- Main loop -------------------- */

    unsigned int iLoop = 0;
    while (iterations == 0 || ++iLoop <= iterations) {
        mr = joyGetPosEx(joy_ID, &info);

        /* ---------------- Error handling & reconnect ---------------- */

        if (mr != JOYERR_NOERROR) {
            if (verbose_flag)
                printf("Error reading joystick (Code %u)\n", mr);

            if (target_vendor_id != 0 && target_product_id != 0) {
                /* Only speak/attempt reconnect if VID/PID were provided. */
                Speak("Controller disconnected. Waiting 60 seconds.");
                if (verbose_flag)
                    printf("Entering Reconnection Mode...\n");

                while (1) {
                    Sleep(60000); /* sleep 60 seconds to avoid busy-looping */

                    int newID = FindJoystick(target_vendor_id, target_product_id);
                    if (newID != -1) {
                        joy_ID = (UINT)newID;
                        Speak("Controller found. Resuming monitoring.");
                        if (verbose_flag)
                            printf("Reconnected at ID %u\n", joy_ID);

                        /* Reinitialize JOYINFOEX for the newly found device. */
                        info.dwSize  = sizeof(info);
                        info.dwFlags = joy_Flags;

                        /* Reset gas/clutch state so we don't immediately alert. */
                        lastFullThrottleTime = GetTickCount();
                        lastGasActivityTime  = GetTickCount();
                        isRacing             = FALSE;
                        peakGasInWindow      = 0;
                        lastClutchValue      = 0;
                        repeatingClutchCount = 0;

                        break; /* Leave reconnect loop, resume main loop. */
                    } else {
                        Speak("Controller not found. Retrying.");
                        if (verbose_flag)
                            printf("Scan failed. Retrying in 60s...\n");
                    }
                }

                /* Skip the rest of this iteration; next iteration will read again. */
                continue;
            }

            /* If VID/PID not specified, we just skip processing this frame. */
        }

        if (mr == JOYERR_NOERROR) {
            DWORD currentTime = GetTickCount();

            /* Capture raw axis values once; normalize once per frame. */
            DWORD rawGas    = info.dwYpos;
            DWORD rawClutch = info.dwRpos;

            DWORD gasValue    = normalize_pedal_axis(rawGas, axisMax);
            DWORD clutchValue = normalize_pedal_axis(rawClutch, axisMax);

            if (verbose_flag) {
                if (debug_raw_mode) {
                    printf("%lu, gas_raw=%lu gas_norm=%lu, clutch_raw=%lu clutch_norm=%lu\n",
                           (unsigned long)currentTime,
                           (unsigned long)rawGas,
                           (unsigned long)gasValue,
                           (unsigned long)rawClutch,
                           (unsigned long)clutchValue);
                } else {
                    printf("%lu, gas=%lu, clutch=%lu\n",
                           (unsigned long)currentTime,
                           (unsigned long)gasValue,
                           (unsigned long)clutchValue);
                }
            }

            /* ---------------- 1. CLUTCH MONITORING ---------------- */

            if (monitor_clutch) {
                /*
                 * closure:
                 *   Absolute change in normalized clutch position between the current
                 *   sample and the previous one. Used as a "stickiness" metric:
                 *   if |delta| stays <= axisMargin for several consecutive samples,
                 *   we treat the clutch as stuck/noisy at that position.
                 */
                int closure;

                /*
                 * Only consider clutch noise when:
                 *   - Gas is at/near idle (gasValue <= gasIdleMax),
                 *   - Clutch axis is not fully released (clutchValue > 0).
                 */
                if ((gasValue <= gasIdleMax) && (clutchValue > 0)) {
                    /* Absolute difference without relying on abs()'s int-only signature. */
                    if (clutchValue >= lastClutchValue)
                        closure = (int)(clutchValue - lastClutchValue);
                    else
                        closure = (int)(lastClutchValue - clutchValue);

                    if (closure <= (int)axisMargin)
                        repeatingClutchCount++;
                    else
                        repeatingClutchCount = 0;
                } else {
                    repeatingClutchCount = 0;
                }

                lastClutchValue = clutchValue;

                /*
                 * Require several consecutive "stuck" samples to avoid
                 * reacting to transient noise.
                 */
                if (repeatingClutchCount >= clutch_repeat_required) {
                    if (verbose_flag)
                        printf("Clutch Alert\n");
                    system(clutch_command);
                    repeatingClutchCount = 0;
                }
            }

            /* ---------------- 2. GAS MONITORING ---------------- */

            if (monitor_gas) {
                /* ---- Activity detection & "isRacing" state ---- */

                if (gasValue > gasIdleMax) {
                    /*
                     * We have meaningful throttle input (pedal moved out of idle band).
                     * If we were previously idle, start a new racing window.
                     */
                    if (!isRacing) {
                        lastFullThrottleTime = currentTime;
                        peakGasInWindow      = 0;
                        if (verbose_flag)
                            printf("Gas: Activity Resumed.\n");
                    }

                    isRacing = TRUE;
                    lastGasActivityTime = currentTime;
                } else {
                    /*
                     * Gas is in/near idle band.
                     * If we stay idle for longer than gas_timeout seconds, we
                     * assume the sim is paused or you're in a menu.
                     */
                    if (isRacing &&
                        (currentTime - lastGasActivityTime > gas_timeout_ms)) {
                        if (verbose_flag)
                            printf("Gas: Auto-Pause (Idle for %d s).\n", gas_timeout);
                        isRacing = FALSE;
                    }
                }

                /* ---- Performance/drift check ---- */

                if (isRacing) {
                    /* Track the deepest press (largest normalized gas value) in the current window. */
                    if (gasValue > peakGasInWindow)
                        peakGasInWindow = gasValue;

                    if (gasValue >= gasFullMin) {
                        /*
                         * We observed a "full throttle" (or close enough) event:
                         * - reset the window anchor (lastFullThrottleTime),
                         * - clear peakGasInWindow so the next window starts fresh.
                         */
                        lastFullThrottleTime = currentTime;
                        peakGasInWindow      = 0;
                    } else {
                        /*
                         * We haven't hit full throttle recently.
                         * Once gas_window seconds elapse since lastFullThrottleTime,
                         * we evaluate whether the *maximum* travel seen in this window
                         * is "suspiciously low".
                         */
                        if ((currentTime - lastFullThrottleTime) > gas_window_ms) {

                            /* Rate-limit alerts to at most one per gas_cooldown seconds. */
                            if ((currentTime - lastGasAlertTime) > gas_cooldown_ms) {

                                /* Compute travel as a percentage using integer math. */
                                unsigned int percentReached =
                                    (unsigned int)((peakGasInWindow * 100U) / axisMax);

                                /*
                                 * Ignore windows where you never used more than
                                 * gas_min_usage_percent of the travel.
                                 *
                                 * Motivation:
                                 *   - Avoid "false positives" when you're just creeping along
                                 *     (safety car, pit lane, taxiing, etc.).
                                 *   - In those scenarios it's normal to never go near full throttle,
                                 *     and that's not evidence of a drifting potentiometer.
                                 *
                                 * If you tend to drive entire sessions without exceeding this,
                                 * raise this value or increase gas_window.
                                 */
                                if (percentReached > (unsigned int)gas_min_usage_percent) {
                                    char temp_num_buf[INT_TO_STR_BUFFER_SIZE];

                                    /*
                                     * Writes "NN " into temp buffer and then copies into
                                     * gas_command_line at gas_arg_ptr.
                                     */
                                    strcpy(gas_arg_ptr,
                                           lwan_uint32_to_str(
                                               (uint32_t)percentReached,
                                               temp_num_buf));

                                    if (verbose_flag)
                                        printf("Gas Alert: %u%%\n", percentReached);

                                    system(gas_command_line);
                                    lastGasAlertTime = currentTime;
                                }
                            }
                        }
                    }
                }
            }
        } /* if (mr == JOYERR_NOERROR) */

        Sleep(sleep_Time);
    }

    /* Cleanup (Windows will do this on process exit, but explicit is better). */
    ReleaseMutex(hMutex);
    CloseHandle(hMutex);

    return EXIT_SUCCESS;
}