
**Role:** Act as a super expert .NET and PowerShell System Architect.

**The Environment:** Windows 11, strictly **PowerShell 5.1** (Desktop Edition).

**The Challenge:**
I am refactoring a complex telemetry system. I am merging a high-frequency main loop (reading Joystick hardware via P/Invoke) and an HTTP JSON Server (running in a background thread) into a **single .ps1 script**.

I need to pass data from the Main Thread to the Background HTTP Thread via a thread-safe `ConcurrentQueue`. I have two architectural approaches. One is "dirty" but works (from a legacy script), and the new "clean" dependency-injection approach is failing (the queue appears empty/disconnected in the background thread).

**The Goal:**
I need you to analyze why the "Clean" approach is failing in PowerShell 5.1, and propose specific, elegant patterns to share a **Live Reference** of a .NET Object (`ConcurrentQueue`) between the main session and a `[PowerShell]::Create()` Runspace.

---

### Architecture A: The "Dirty" Way (Legacy - It Works)
In the old script (`PedBridge.ps1`), we used a static class with static fields. The background thread simply accessed the type directly.

**C# Definition:**
```csharp
namespace PedMon {
    public static class Shared {
        public static ConcurrentQueue<object> TelemetryQueue = new ConcurrentQueue<object>();
    }
}
```

**PowerShell Logic:**
```powershell
# Background Thread Setup
$ps = [PowerShell]::Create()
$ps.AddScript({
    # Directly accessing the static member from the AppDomain
    $q = [PedMon.Shared]::TelemetryQueue
    # ... logic to Dequeue ...
})
$ps.BeginInvoke()
```
*   **Why it works:** The Type is loaded into the AppDomain. Both the Main Runspace and the Background Runspace seem to share the same AppDomain in this context, so they see the same static memory.
*   **Why we dislike it:** It relies on global static state and implicit scoping, which feels brittle and "dirty."

---

### Architecture B: The "Clean" Way (Current Attempt - Fails)
In the new script (`FanatecPedals.ps1`), I am trying to inject the specific instance of the Queue into the background runspace to avoid relying on static discovery.

**C# Definition:**
```csharp
namespace Fanatec {
    public static class Shared {
        public static ConcurrentQueue<PedalMonState> TelemetryQueue = new ConcurrentQueue<PedalMonState>();
    }
}
```

**PowerShell Logic:**
```powershell
# Main Thread
$QueueInstance = [Fanatec.Shared]::TelemetryQueue

# Background Thread Setup
$ps = [PowerShell]::Create()
# Attempting to pass the Reference
$ps.AddArgument($QueueInstance) 
$ps.AddScript({
    param($Q) # Receiving the argument
    
    # PROBLEM: $Q is not null, but it appears empty even when Main Thread fills it.
    # It acts like a disconnected copy or a serialized clone, not a live reference.
    $f = $null
    while ($Q.TryDequeue([ref]$f)) { ... } 
})
$ps.BeginInvoke()
```

---

### The Request

1.  CRITICAL: Think hard and **Analyze the Failure:** Why does `AddArgument` with a .NET Object (`ConcurrentQueue`) fail to maintain a live reference across Runspaces in PowerShell 5.1? Is it serializing the object instead of passing a pointer?
2.  CRITICAL: Think hard and **Evaluate Options:** Please provide at least 3 distinct solutions to share this data reliably, ranked from "Most Elegant/Robust" to "Quickest Fix."
    *   *Constraint:* Must be thread-safe.
    *   *Constraint:* Must work in PS 5.1.
3.  **Specific Consideration:** Can `SessionStateProxy.SetVariable` be used here to pass a live reference? Or is `[Hashtable]::Synchronized` a better bridge?
4.  **Recommendation:** Which approach do you recommend for a high-performance game telemetry loop where latency matters?

Please provide code snippets for the recommended fixes applied to the **Architecture B** style.



1) Why your “Clean” AddArgument() approach looks disconnected in PS 5.1

The important truth

In Windows PowerShell 5.1, an in-process runspace created via [PowerShell]::Create() runs in the same process and AppDomain, so passing a reference type like ConcurrentQueue<T> via .AddArgument($queue) should not be serialized or cloned. It should be the same instance.

So if the background runspace sees $Q as a real ConcurrentQueue<T> (it has .TryDequeue() etc) but it never receives items, then almost always one of these is happening:

The 3 most common real causes

Cause A — You’re not enqueueing into the same instance you passed

This happens when you capture one instance and later the producer starts enqueueing into a different instance.

Typical ways this happens in refactors:

You reassign the static field later:

Shared.TelemetryQueue = new ConcurrentQueue<PedalMonState>(); // boom: consumers now hold old instance

You have two “sources of truth”: sometimes you enqueue via $QueueInstance, other times via [Fanatec.Shared]::TelemetryQueue, and one of them got replaced.


Why Architecture A “works” in that scenario: it always re-reads [Fanatec.Shared]::TelemetryQueue, so it follows the replacement. Your DI approach “freezes” one instance at injection time.

Cause B — You accidentally loaded two different Fanatec.* type identities

This is sneaky and very common with Add-Type or script compilation in multiple runspaces:

Runspace #1 loads/compiles Fanatec.Shared and Fanatec.PedalMonState

Runspace #2 loads/compiles again (or loads from a different path/version)


You can end up with two different assemblies that each contain a Fanatec.Shared type, each with its own static TelemetryQueue. Then:

main thread enqueues into queue A

background is holding queue B (or vice versa)


This also happens if PedalMonState’s type identity differs: then any typed conversions can silently create “equivalent” containers that are not the same object graph you think they are.

Cause C — Parameter binding / conversion created a new queue

This happens if you typed the param (in your real script) as something that doesn’t exactly match the instance:

ConcurrentQueue[object] vs ConcurrentQueue[PedalMonState] (generic invariance)

a PedalMonState type identity mismatch (Cause B)


PowerShell can’t cast, so it may attempt a conversion path that effectively creates a new container. (You still see a queue, but it’s not the queue.)

> Bottom line: .AddArgument() is not the villain in normal in-proc runspaces. It’s almost always “you’re not actually talking about the same queue instance.”




---

2) Solutions (ranked)

✅ Option 1 — Most elegant/robust: Explicit runspace + inject dependencies via InitialSessionState

This is “real DI” for runspaces: you create the runspace yourself and seed variables with live references before it starts.

Why it’s robust: no parameter-binding surprises, no accidental conversion, and you can inject a whole dependency bundle cleanly.

using namespace System.Collections.Concurrent
using namespace System.Management.Automation.Runspaces
using namespace System.Threading
using namespace System.Net
using namespace System.Text

# Main thread: create shared objects ONCE
$queue = [Fanatec.Shared]::TelemetryQueue  # or: [ConcurrentQueue[Fanatec.PedalMonState]]::new()
$cts   = [CancellationTokenSource]::new()

# Seed runspace variables (live references)
$iss = [InitialSessionState]::CreateDefault()
$iss.Variables.Add([SessionStateVariableEntry]::new('TelemetryQueue', $queue, 'Shared telemetry queue'))
$iss.Variables.Add([SessionStateVariableEntry]::new('StopToken',     $cts.Token, 'Stop token'))

$rs = [RunspaceFactory]::CreateRunspace($iss)
$rs.ApartmentState = 'MTA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()

$ps = [PowerShell]::Create()
$ps.Runspace = $rs

$null = $ps.AddScript({
    param([int]$Port)

    $listener = [HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()

    $latest = $null
    $item = $null

    try {
        while (-not $StopToken.IsCancellationRequested) {
            # Block waiting for a request (no busy loop)
            $ctx = $listener.GetContext()

            # Drain queue fast; keep only most recent state
            while ($TelemetryQueue.TryDequeue([ref]$item)) {
                $latest = $item
            }

            $json  = if ($null -ne $latest) { $latest | ConvertTo-Json -Compress -Depth 6 } else { '{}' }
            $bytes = [Encoding]::UTF8.GetBytes($json)

            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        }
    }
    finally {
        $listener.Stop()
        $listener.Close()
    }
}).AddArgument(8080)

$async = $ps.BeginInvoke()

# Producer (main loop) example:
# $queue.Enqueue($state)

# Shutdown example:
# $cts.Cancel()
# $ps.EndInvoke($async)
# $ps.Dispose(); $rs.Dispose()


---

✅ Option 2 — Very good: SessionStateProxy.SetVariable() (runtime injection)

Yes — this works for in-process runspaces and passes a live reference.

It’s also a nice DI pattern if you want to create the runspace first, then inject:

using namespace System.Management.Automation.Runspaces

$queue = [Fanatec.Shared]::TelemetryQueue

$rs = [RunspaceFactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()

# Inject the live reference
$rs.SessionStateProxy.SetVariable('TelemetryQueue', $queue)

$ps = [PowerShell]::Create()
$ps.Runspace = $rs

$null = $ps.AddScript({
    $item = $null
    while ($true) {
        while ($TelemetryQueue.TryDequeue([ref]$item)) {
            # ...
        }
        Start-Sleep -Milliseconds 1
    }
})

$async = $ps.BeginInvoke()

When it won’t be “live”: if you accidentally use an out-of-process runspace, jobs, or remoting — then it will serialize. But for your described setup, this is solid.


---

✅ Option 3 — Best producer/consumer semantics: BlockingCollection<T> (built for this)

If the background thread shouldn’t spin/poll, BlockingCollection<T> is often the cleanest.

Producer calls .Add($item)

Consumer calls .Take($token) (blocks efficiently)


using namespace System.Collections.Concurrent
using namespace System.Threading

$bc  = [BlockingCollection[Fanatec.PedalMonState]]::new(
          [ConcurrentQueue[Fanatec.PedalMonState]]::new()
      )
$cts = [CancellationTokenSource]::new()

# Share $bc via InitialSessionState or SessionStateProxy as shown above

# Producer:
# $bc.Add($state)

# Consumer (runspace):
# while (-not $StopToken.IsCancellationRequested) { $s = $TelemetryBC.Take($StopToken); ... }

If you only care about the latest sample, you can combine this with a “drop old” strategy (bounded capacity = 1 and replace).


---

⚡ Quickest fix — keep static, but make it less “dirty”

Your Architecture A is actually a legitimate pattern in .NET: a static “bus” / “singleton” shared within a process.

If you keep it, at least:

Put it behind a small API (Enqueue(), TryDrainLatest())

Never reassign the queue instance (only enqueue/dequeue)


This removes the main gotcha that breaks DI (queue replacement).


---

3) SessionStateProxy.SetVariable vs [Hashtable]::Synchronized

SessionStateProxy.SetVariable

✅ Great for DI into a runspace

✅ Passes the same object reference in-process

✅ Cleanest way to “register” dependencies by name ($TelemetryQueue, $StopToken, etc.)

⚠️ Don’t use it as a high-frequency data path. Use it once to inject.


[Hashtable]::Synchronized

✅ Useful as a shared container for multiple dependencies/state

✅ Thread-safe for hashtable operations

❌ Adds a lock around every hashtable access (can become contention in a hot loop)

❌ Does not magically solve “wrong instance” problems; you still must ensure both runspaces have the same hashtable reference


If latency matters, I’d avoid synchronized hashtable access in your main loop unless you only touch it occasionally.


---

4) Recommendation for your high-frequency telemetry loop (latency matters)

If the HTTP server only needs the latest telemetry snapshot, the fastest design is usually:

Main loop: update a single “latest state” reference using Interlocked.Exchange() or Volatile.Write()

HTTP thread: Volatile.Read() latest state on demand


That avoids queue growth and minimizes allocations.

But if you do need a queue (for buffering / multi-sample processing), then:

Recommended for you:
✅ Option 1 (InitialSessionState DI) + ConcurrentQueue<T>
…and if you want to eliminate polling entirely, switch to:
✅ Option 3 (BlockingCollection<T>)

Both are PS 5.1-friendly and high performance.


---

Small “sanity check” snippet (to prove identity)

Run this once to confirm you truly share the same instance:

using namespace System.Runtime.CompilerServices

$queue = [Fanatec.Shared]::TelemetryQueue
$mainId = [RuntimeHelpers]::GetHashCode($queue)

$ps = [PowerShell]::Create()
$ps.AddScript({
    param($q,$mainId)
    $bgId = [RuntimeHelpers]::GetHashCode($q)
    "MainId=$mainId  BgId=$bgId  RefEqual=$([object]::ReferenceEquals($q, [Fanatec.Shared]::TelemetryQueue))"
}).AddArgument($queue).AddArgument($mainId) | Out-Null

$ps.Invoke()

If RefEqual is False, you’ve got Cause A or B (wrong instance / type identity split).

If it’s True but dequeue still “misses”, then something else is draining or you’re blocking elsewhere.



---

If you paste the exact runspace creation code you’re using (especially anything around Add-Type, module loads, or any place you might reassign TelemetryQueue), I can pinpoint which of Causes A/B/C is actually happening in your case and give you a minimal surgical fix.
