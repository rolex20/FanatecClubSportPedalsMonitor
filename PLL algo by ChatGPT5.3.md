
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
