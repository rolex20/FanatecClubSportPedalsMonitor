# Response from ChatGPT to your question.  I also added a comment asking it what if in the future I execute PedDash from another PC in my LAN.
You’re 100% right to throw RTT away on localhost. If the “RTT” signal is basically **(event loop jitter + timer quantization)**, feeding it into the loop is like measuring temperature with a random-number generator.

### Important constraint (so expectations are correct)

Using **only queue depth** as the phase detector:

* `0` tells you “you’re **before** the write”
* `2+` tells you “you’re **after** multiple writes”
* `1` tells you “you’re **somewhere inside** the safe window”

That means queue depth alone cannot *directly* tell you “you are 5ms after the write” — it can only tell you “you are not too early / not too late.”
To actually land ~5ms after the write, you need a tiny **edge-seeking acquisition** step: *creep earlier until you barely hit a 0 once*, then back off by 5ms and hold. That’s still RTT-agnostic and uses queue depth only.

---

## RTT-agnostic “Edge-Seeking Digital PLL” (Absolute Timing)

* **ACQUIRE mode:** slowly walk earlier until you *just* get a `0` once → that reveals the boundary.
* Then shift later by `phaseAfterWriteMs` (≈5ms) and switch to **HOLD**.
* **HOLD mode:** no creeping; just a damped PI correction when `0` or `2+` appears (drift or stalls).

### `calculateNextSleep(framesReceived, producerPeriod)`

```js
const calculateNextSleep = (() => {
  // ---- Tunables (start here) ----
  const cfg = {
    phaseAfterWriteMs: 5,     // target margin after producer write
    creepMs: 0.25,            // ACQUIRE: how fast we walk earlier (ms per poll)
    alpha: 0.25,              // error low-pass (0..1)
    kp: 6.0,                  // ms per frame-error (proportional)
    ki: 0.6,                  // ms per frame-error per tick (integral)
    intLimit: 8,              // anti-windup (in "frames")
    maxAdjust: 25,            // clamp per-tick correction (ms): prevents sprinting
    minStepRatio: 0.60,       // min interval = P*ratio
    maxStepRatio: 1.40,       // max interval = P*ratio
    holdReacquireErrors: 2,   // consecutive bad reads before re-ACQUIRE
    slackMs: 2                // keep nextTarget at least this far in the future
  };

  // ---- State ----
  let nextTarget = NaN;       // absolute schedule time (performance.now domain)
  let errLP = 0;
  let errInt = 0;
  let mode = "ACQUIRE";
  let holdBadCount = 0;

  const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));

  return function calculateNextSleep(framesReceived, producerPeriod) {
    const now = performance.now();
    if (!Number.isFinite(nextTarget)) nextTarget = now;

    // Validate/sanitize period
    let P = Number.isFinite(producerPeriod) && producerPeriod > 0 ? producerPeriod : 100;

    // Phase detector using queue depth only:
    //   0 => too early (+)
    //   1 => in window (0)
    //   2 => too late (-1), 3 => (-2), ...
    let e;
    if (framesReceived <= 0) e = +1;
    else if (framesReceived === 1) e = 0;
    else e = -(framesReceived - 1);

    // Low-pass filter quantized detector output
    errLP += cfg.alpha * (e - errLP);

    // Integrate (anti-windup)
    errInt = clamp(errInt + errLP, -cfg.intLimit, cfg.intLimit);

    // PI correction in ms
    let adjust = cfg.kp * errLP + cfg.ki * errInt;

    // Mode logic
    let resetAfterThisTick = false;

    if (mode === "ACQUIRE") {
      // Walk earlier slowly while we keep seeing exactly 1 frame.
      if (framesReceived === 1) adjust -= cfg.creepMs;

      // When we finally see 0, we *just* crossed the boundary:
      // push later by desired margin and lock.
      if (framesReceived <= 0) {
        adjust += cfg.phaseAfterWriteMs;
        mode = "HOLD";
        holdBadCount = 0;
        resetAfterThisTick = true; // clear integrator memory after the lock event
      }
    } else { // HOLD
      if (framesReceived === 1) {
        holdBadCount = 0;
        // No creep in HOLD: keep the phase you found.
      } else {
        holdBadCount++;
        if (holdBadCount >= cfg.holdReacquireErrors) {
          mode = "ACQUIRE";
          holdBadCount = 0;
          errInt *= 0.5; // soften the handoff
        }
      }
    }

    // Clamp correction so we never "sprint"
    adjust = clamp(adjust, -cfg.maxAdjust, +cfg.maxAdjust);

    // Compute step and advance absolute schedule
    const minStep = P * cfg.minStepRatio;
    const maxStep = P * cfg.maxStepRatio;
    const step = clamp(P + adjust, minStep, maxStep);

    nextTarget += step;

    // If we're behind, SKIP forward by whole steps (do NOT snap to 'now', which causes 0-frame overshoot)
    if (nextTarget < now + cfg.slackMs) {
      const deficit = (now + cfg.slackMs) - nextTarget;
      const n = Math.ceil(deficit / step);
      nextTarget += n * step;
      errInt *= 0.5; // damp after a skip
    }

    if (resetAfterThisTick) {
      errLP = 0;
      errInt = 0;
    }

    return Math.max(0, nextTarget - now);
  };
})();
```

### How you use it

Call it **once per completed fetch** to get the sleep until the next fetch:

```js
let sleepMs = 0;

async function loop() {
  while (true) {
    await new Promise(r => setTimeout(r, sleepMs));

    const resp = await fetch("/frames", { cache: "no-store" });
    const frames = await resp.json();
    const framesReceived = Array.isArray(frames) ? frames.length : (frames.frames?.length ?? 0);

    // Use producerPeriod from Producer timestamps (e.g. 102.4)
    sleepMs = calculateNextSleep(framesReceived, producerPeriodMs);

    // render(frames) ...
  }
}
```

---

## Why this fixes the 10ms <-> 100ms oscillation

* It **never** collapses to “drain instantly” behavior.
* Corrections are **bounded** (`maxAdjust`) and **filtered** (`alpha`), so it can’t amplify jitter into a stable flip-flop.
* When behind, it **skips ahead by whole steps** instead of snapping to `now` (snapping is what causes the “poll immediately → 0 frames” overshoot pattern).

---

## If you later move to LAN: easy ways to add RTT back safely

### Option A: Keep this queue-depth PLL, add a *filtered* RTT “lead” term

When RTT becomes real, you can subtract a lead term so the **request arrival** aligns closer to `nextTarget`. But don’t use raw RTT samples.

Minimal, robust approach:

* Measure RTT per fetch.
* Maintain a window of last N RTTs (e.g., 20).
* Use **median** (or “min-of-window + small margin”) as the stable estimate.
* Only update the lead estimate with “good” samples (reject outliers).

Then do:

* `sleep = (nextTarget - now) - 0.5 * rttEstimate`

This is basically your original idea, but using an RTT estimate that isn’t garbage.

### Option B (best): Add one timestamp field on the Bridge and do NTP-style offset

If you can modify the JSON response, add:

* `bridgeSendEpochMs` (Date.now() on the bridge at send time)
  Optionally also:
* `producerWriteEpochMs` (best if producer can stamp real epoch time at write)

Then the browser can:

* Estimate **clock offset** and **one-way delay** with NTP-style math (using multiple samples + choose the best/min-RTT sample).
* Schedule against the **producer/bridge timebase**, not guesswork.

That turns the problem from “PLL with only a 3-level detector” into “real phase lock to the producer write timestamp,” and it gets dramatically easier and tighter.

### Option C: Stop polling (SSE/WebSocket)

If the bridge can push frames, you sidestep timer jitter + polling phase entirely. You can still enforce “process exactly 1 frame per render tick” in the UI, but transport becomes stable.

---

If you want, paste one or two short logs like:

* `framesReceived sequence over ~200 polls`
* the producer’s measured period (e.g., 102.4ms)
* whether you ever see `0` once locked

…and I’ll suggest concrete values for `creepMs`, `maxAdjust`, and the HOLD reacquire threshold for your jitter profile.
