# Response by Chat GPT 5.2 (Heavy Thinking Model)

Below is a **stable “digital PLL / PI controller”** approach that fixes the exact oscillation you described by **never sprinting** and by **scheduling against an absolute clock** (so fetch/JS overhead doesn’t silently slow your loop).

Key ideas:

* Treat `LastFramesReceived` as a **quantized phase detector**:

  * `0` ⇒ you polled **too early** → delay more next time
  * `2+` ⇒ you polled **too late** → delay less next time
* Apply **small, bounded corrections** (PI controller + low-pass filtering) so you *converge* instead of oscillate.
* Compute sleep from an **absolute next target time**, not `setTimeout(P)` after each fetch (which drifts).

---

## JavaScript logic (drop-in pattern)

```js
function clamp(x, lo, hi) { return Math.max(lo, Math.min(hi, x)); }

const ctrl = {
  P: 100,                 // ProducerPeriod (ms) - you can set from input
  targetFrames: 1,

  // Low-pass filter + integral state (units: "frames")
  errLP: 0,
  errInt: 0,

  // Tuning knobs (good starting points for P=100ms)
  alpha: 0.25,            // error low-pass (0..1). Higher = faster, more jittery
  kp: 6.0,                // ms per frame-error (proportional)
  ki: 0.6,                // ms per frame-error per tick (integral)

  // Anti-windup / stability bounds
  intLimit: 10,           // limits integral magnitude (in "frames")
  maxAdjust: 25,          // clamp per-tick correction (ms). Prevents "sprint" overshoot

  // Interval bounds (prevents absurdly fast/slow polling)
  minStep: 60,            // ms (>= ~P*0.6)
  maxStep: 140,           // ms (<= ~P*1.4)

  // Optional: estimate half-RTT so request-arrival is closer to target
  rttEma: 0,
  rttAlpha: 0.10,

  // Absolute schedule (ms in performance.now() timebase)
  nextTarget: performance.now() + 100
};

/**
 * Call this once per response to compute the NEXT setTimeout duration.
 * Inputs:
 *  - lastFramesReceived: integer (0,1,2,...)
 *  - producerPeriod: ms (e.g., 100)
 *  - requestRttMs: measured fetch round-trip time (ms)
 * Output:
 *  - nextSleepMs: ms to pass to setTimeout
 */
function computeNextSleepTime(lastFramesReceived, producerPeriod, requestRttMs) {
  const now = performance.now();
  ctrl.P = producerPeriod;

  // Track RTT (optional but helps when local stack latency varies)
  if (Number.isFinite(requestRttMs)) {
    ctrl.rttEma += ctrl.rttAlpha * (requestRttMs - ctrl.rttEma);
  }

  // Phase detector error: + => too early, - => too late
  // (We want 1 frame)
  let err = ctrl.targetFrames - lastFramesReceived;

  // Optional robustness bias: treat "0 frames" as more severe than "2 frames"
  // because empties are usually more disruptive than slight extra latency.
  if (lastFramesReceived === 0) err *= 1.35;

  // Low-pass filter the quantized error to reduce jitter-driven flips
  ctrl.errLP += ctrl.alpha * (err - ctrl.errLP);

  // Integrate (anti-windup clamp)
  ctrl.errInt = clamp(ctrl.errInt + ctrl.errLP, -ctrl.intLimit, ctrl.intLimit);

  // PI correction (ms)
  let adjust = ctrl.kp * ctrl.errLP + ctrl.ki * ctrl.errInt;
  adjust = clamp(adjust, -ctrl.maxAdjust, ctrl.maxAdjust);

  // Planned step to next poll time
  const step = clamp(ctrl.P + adjust, ctrl.minStep, ctrl.maxStep);

  // Advance absolute schedule
  ctrl.nextTarget += step;

  // If we fell behind (tab hiccup / long fetch), resync gently (no burst-drain)
  const minLead = 2; // ms: keep nextTarget slightly in the future
  if (ctrl.nextTarget < now + minLead) {
    ctrl.nextTarget = now + minLead;
    ctrl.errInt *= 0.5; // damp integrator after a resync event
  }

  // Convert absolute target into a setTimeout duration.
  // Subtract half RTT so *arrival* is closer to target (optional).
  const leadComp = 0.5 * ctrl.rttEma;
  const sleepMs = Math.max(0, ctrl.nextTarget - now - leadComp);

  return sleepMs;
}
```

### How to use it in your poll loop

```js
async function pollForever() {
  let sleepMs = 0;

  while (true) {
    await new Promise(r => setTimeout(r, sleepMs));

    const t0 = performance.now();
    const resp = await fetch("http://localhost:1234/frames", { cache: "no-store" });
    const data = await resp.json();
    const t1 = performance.now();

    const framesReceived = Array.isArray(data) ? data.length : (data.frames?.length ?? 0);
    const rtt = t1 - t0;

    sleepMs = computeNextSleepTime(framesReceived, 100, rtt);

    // render(data) ...
  }
}
```

---

## Why this won’t do the 10ms <-> 100ms oscillation

* You **never switch to a tiny fixed delay**. Corrections are **bounded** (`maxAdjust`) and **filtered** (`alpha`).
* Scheduling is **absolute-time-based** (`nextTarget += step`) so you don’t accumulate drift from fetch/JS time.
* The integrator gives it “memory” so it can correct a consistent offset without hunting, but anti-windup + resync prevents runaway.

---

## Tuning (fast and safe)

For `P = 100ms`, start with what’s in the code. If you want:

* **More stability / less twitchy:** lower `alpha` (0.15–0.25), lower `kp`
* **Faster convergence:** increase `kp` a bit (try 7–10), keep `maxAdjust` capped (20–30ms)
* **Fewer empty responses:** keep the `0-frame` bias (`*1.35`) or raise slightly (1.4–1.6)

This controller will settle into a phase where `LastFramesReceived` is overwhelmingly **1** and will correct slowly when it drifts—without draining the queue instantly and then starving.

If you can add **a monotonically increasing frame sequence number** in each frame payload, I can give you an even tighter “true PLL” variant that locks phase using sequence deltas (it becomes almost perfect).
