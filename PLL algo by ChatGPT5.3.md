- Below are the proposals from other powerful AI experts
- Compare your solutions to the other's
- Score and rank them on different categories with a detailed analysis
- Design a new better and improved solution if you find one with with a detailed explanation
- Select the Top 3 solutions and justify with a detailed analysis
- Here is the catch: The end user knows  powershell but not C#, so  it is prefered  a high performant solution with little overhead but minimizing the use of the helper C# code with Add-Type and all that stuff because the user won't know how to maintain it.
- A little challenge:  Try to guess which AI wrote each response.

# AI NUMBER 2 

### 1. Analysis of the Failure in Architecture B

In PowerShell 5.1, when you use `[PowerShell]::Create()` (which creates a new **runspace** in the same process and AppDomain), passing a .NET object like `ConcurrentQueue<T>` via `AddArgument()` (or `AddParameter()`) does **not** pass a live reference in the way you expect for mutable state.

- Simple .NET objects (e.g., strings, integers, or immutable types) are passed by reference because they share the same AppDomain.
- However, for complex mutable collections like `ConcurrentQueue<T>`, PowerShell's parameter binding mechanism performs a **deep copy/serialization-like marshal** when crossing runspace boundaries via arguments. This results in the background runspace receiving a **separate instance** that looks identical at the moment of passing but is disconnected from the original.

This is why `$Q` is not null, but `TryDequeue` never finds items enqueued from the main runspace—it is operating on a clone, not the live object.

Static members (as in Architecture A) work because the type itself is shared across the entire AppDomain, and static fields are truly global.

### 2. Evaluated Options (Ranked: Most Elegant/Robust → Quickest Fix)

All options are thread-safe and fully compatible with PowerShell 5.1.

| Rank | Approach | Description | Pros | Cons | Performance Impact |
|------|----------|-------------|------|------|---------------------|
| 1 (Most Elegant/Robust) | Use `SessionStateProxy.SetVariable` to inject the live queue instance | Create the runspace explicitly, open it, then use `$runspace.SessionStateProxy.SetVariable('Q', $QueueInstance)` to make the exact same object reference available in the background script as `$Q`. | Clean dependency injection, no globals, true live reference, no copying. | Slightly more verbose setup than `AddArgument`. | Negligible – direct reference. |
| 2 | Use `[hashtable]::Synchronized(@{})` as a bridge | Wrap the queue (or data) in a synchronized hashtable and inject via `SessionStateProxy` (or even `AddArgument` – synchronized collections pass live). | Very common pattern, flexible for multiple shared values. | Adds one layer of indirection (e.g., `$sync.Queue.Enqueue(...)`). | Minimal overhead. |
| 3 (Quickest Fix) | Revert to static class with static field | As in your working legacy Architecture A. | Zero changes needed beyond what already works. | Global mutable state – harder to reason about, test, and maintain. | None. |

### 3. Specific Consideration: `SessionStateProxy.SetVariable` vs `[Hashtable]::Synchronized`

- **`SessionStateProxy.SetVariable`** **can** pass a live reference to any .NET object (including `ConcurrentQueue<T>`). It does **not** serialize/copy the object – it directly sets the variable in the target runspace's session state to point to the same instance. This is the recommended way for true dependency injection in PS 5.1 runspaces.
- `[Hashtable]::Synchronized` is excellent when you need to share multiple values or a more complex structure, but for a single `ConcurrentQueue`, `SessionStateProxy` is simpler and more direct.

### 4. Recommendation

For a **high-performance game telemetry loop** where latency is critical:

**Go with Option 1: `SessionStateProxy.SetVariable` to inject the live `ConcurrentQueue`.**

- It gives you clean, explicit dependency injection without globals.
- No serialization overhead.
- `ConcurrentQueue<T>` is already lock-free and extremely fast – direct reference sharing preserves that performance.
- Avoids the "dirty" feel of statics while fixing the disconnection issue.

### Code Snippets: Applying the Recommended Fix to Architecture B Style

```powershell
# Load your C# type (assuming it's compiled/added via Add-Type)
Add-Type @"
namespace Fanatec {
    public class Shared {
        public static System.Collections.Concurrent.ConcurrentQueue<PedalMonState> TelemetryQueue = 
            new System.Collections.Concurrent.ConcurrentQueue<PedalMonState>();
    }
}
"@

# Main thread: Create the shared queue instance
$QueueInstance = [Fanatec.Shared]::TelemetryQueue

# Enqueue some test data in main loop (your high-frequency joystick loop)
while ($true) {
    $state = New-Object PedalMonState  # whatever your state object is
    # ... fill state from P/Invoke ...
    $QueueInstance.Enqueue($state)
    Start-Sleep -Milliseconds 1  # simulate loop
}

# Background HTTP server setup (in the same script)
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()

# Inject the LIVE queue reference into the background runspace
$runspace.SessionStateProxy.SetVariable('Q', $QueueInstance)

$ps = [powershell]::Create()
$ps.Runspace = $runspace

$ps.AddScript({
    # HTTP server logic here (e.g., using HttpListener in a loop)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add('http://+:8080/telemetry/')
    $listener.Start()

    while ($true) {
        $context = $listener.GetContext()
        # Dequeue latest telemetry safely
        $latest = $null
        while ($Q.TryDequeue([ref]$latest)) { }  # drain to latest

        if ($latest) {
            $json = $latest | ConvertTo-Json
            $context.Response.ContentType = 'application/json'
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        $context.Response.Close()
    }
})

$handle = $ps.BeginInvoke()

# Later, to stop cleanly:
# $ps.Stop()
# $handle.AsyncWaitHandle.WaitOne()
# $runspace.Close()
# $runspace.Dispose()
```

This gives you a single `.ps1` script with a high-frequency main loop producing data and a background HTTP thread consuming the **exact same** queue instance with zero copying and full thread-safety.

# AI NUMBER 3

### Analysis of the Failure

In PowerShell 5.1, when you create a new runspace with `[PowerShell]::Create()`, it operates within the same process and AppDomain as the main runspace, allowing shared access to static .NET members (as in Architecture A). However, passing .NET objects via `AddArgument` or `AddParameter` to a script block executed in the new runspace can lead to unexpected behavior for complex reference types like `ConcurrentQueue<T>`. 

The core issue is that `AddArgument` does not always guarantee a "live" shared reference in the way you might expect. While .NET reference types are generally passed by reference in local runspaces (no remoting involved), PowerShell's internal handling can involve marshaling or proxying the object across runspace boundaries to enforce isolation in session state. This is especially true for objects that implement interfaces like `IEnumerable` or have thread-affinity concerns. `ConcurrentQueue<T>` is not marked as `[Serializable]`, so it isn't fully serialized (which would fail outright), but the passed instance may end up as a disconnected or stale reference—essentially behaving like a snapshot or copy at the time of invocation, without reflecting subsequent enqueues from the main runspace. This is compounded if the custom type `PedalMonState` (your queue's generic type) has any serialization limitations or if there's apartment state mismatch (e.g., STA vs. MTA threading). In practice, this results in the background runspace seeing an empty queue, even as the main runspace populates it, because the reference isn't truly shared in a live, mutable way. This behavior is documented in PowerShell community resources as a common pitfall when sharing live objects between runspaces, where `AddArgument` is better suited for simple values or immutable data rather than mutable, thread-safe collections requiring ongoing synchronization.

### Evaluation of Options

Here are three distinct, thread-safe solutions to share a live reference to the `ConcurrentQueue<PedalMonState>` between the main runspace and the background runspace in PowerShell 5.1. They are ranked from most elegant/robust (prioritizing clean dependency injection, maintainability, and avoidance of globals) to quickest fix (prioritizing simplicity and minimal changes). All leverage the shared AppDomain for reference passing without serialization.

1. **Most Elegant/Robust: Use `SessionStateProxy.SetVariable` to Inject the Queue Reference**  
   This approach directly sets the queue instance in the new runspace's session state, ensuring a live, shared reference without relying on script parameters or statics. It's robust because it explicitly bridges session states while maintaining isolation elsewhere, and it's a standard pattern for sharing live .NET objects in runspaces (as recommended in PowerShell documentation and community guides). Overhead is negligible for high-frequency access.

2. **Intermediate: Wrap the Queue in a Synchronized Hashtable as a Bridge**  
   Create a synchronized `[Hashtable]` (thread-safe by design) and store the queue instance within it. Pass the hashtable reference to the background runspace (via `SetVariable` or even `AddArgument`, since hashtables serialize better but still share references locally). The background thread accesses the queue via the hashtable. This adds a layer of indirection for robustness in multi-runspace scenarios but is slightly less direct than option 1.

3. **Quickest Fix: Revert to Static Queue with Namespace Isolation**  
   Keep the queue as a static member (as in Architecture A), but encapsulate it in a non-public or uniquely named namespace/class to reduce "dirtiness" and avoid global pollution. This is the fastest to implement (minimal code changes) and performs well, as static access is direct, but it's least elegant due to implicit sharing.

### Specific Consideration

Yes, `SessionStateProxy.SetVariable` can be used to pass a live reference effectively here—it's the preferred method for sharing mutable .NET objects like your `ConcurrentQueue` across runspaces, as it injects the reference directly into the session state without the marshaling issues of `AddArgument`. This ensures both runspaces operate on the same instance in memory.

`[Hashtable]::Synchronized` could serve as a bridge (as in option 2 above), but it's not inherently "better" for your use case—it's more useful for key-value storage or when you need a collection that's natively synchronizable without importing `System.Collections.Concurrent`. Since `ConcurrentQueue` is already thread-safe and optimized for producer-consumer scenarios, wrapping it in a synchronized hashtable adds unnecessary overhead unless you're dealing with multiple shared objects or need fallback serialization support.

### Recommendation

For a high-performance game telemetry loop where latency matters (e.g., high-frequency joystick reads and HTTP responses), I recommend **option 1 (SessionStateProxy.SetVariable)** as the primary approach. It aligns with your "clean" Architecture B goal by enabling dependency injection without statics, while introducing minimal overhead—accessing the queue is still direct and thread-safe via `ConcurrentQueue`'s internal synchronization. Static access (option 3) might shave off microseconds in extreme cases due to no session state lookup, but the difference is negligible compared to P/Invoke or HTTP latency. Avoid option 2 unless you anticipate expanding to more shared state, as the indirection could add minor latency.

If performance testing shows any bottleneck (unlikely), fall back to statics. Ensure your main loop enqueues frequently and the background loop includes a wait mechanism (e.g., `Start-Sleep -Milliseconds 10` in a `while($true)` loop) to poll without spinning CPU, as `TryDequeue` is non-blocking.

#### Code Snippets for Recommended Fixes (Applied to Architecture B Style)

These modify your "Clean" approach in `FanatecPedals.ps1`. Assume your C# definition remains the same (static queue for instantiation, but we'll use an instance). I've focused on the setup; integrate with your full script.

**Primary Recommendation: Option 1 (SessionStateProxy.SetVariable)**  
```powershell
# Main Thread
$QueueInstance = [Fanatec.Shared]::TelemetryQueue  # Or new-up a non-static instance if preferred: New-Object 'System.Collections.Concurrent.ConcurrentQueue[Fanatec.PedalMonState]'

# Background Thread Setup
$ps = [PowerShell]::Create()
$ps.Runspace.SessionStateProxy.SetVariable('Q', $QueueInstance)  # Inject live reference

$ps.AddScript({
    # No param needed; $Q is now in session state
    $f = $null
    while ($true) {
        if ($Q.TryDequeue([ref]$f)) {
            # Process $f (e.g., send via HTTP JSON)
            # ... your dequeue logic ...
        } else {
            Start-Sleep -Milliseconds 10  # Poll without busy-wait; adjust for latency needs
        }
    }
})

$handle = $ps.BeginInvoke()  # Start async execution

# Later in main loop: $QueueInstance.Enqueue($somePedalState)  # Main thread populates
```

**Alternative: Option 2 (Synchronized Hashtable Bridge)**  
```powershell
# Main Thread
$QueueInstance = [Fanatec.Shared]::TelemetryQueue
$syncHash = [Hashtable]::Synchronized(@{ TelemetryQueue = $QueueInstance })  # Wrap for bridge

# Background Thread Setup
$ps = [PowerShell]::Create()
$ps.Runspace.SessionStateProxy.SetVariable('SyncHash', $syncHash)  # Inject the hash (or use AddArgument if preferred)

$ps.AddScript({
    $q = $SyncHash.TelemetryQueue  # Access queue via hash
    $f = $null
    while ($true) {
        if ($q.TryDequeue([ref]$f)) {
            # Process $f
            # ... your dequeue logic ...
        } else {
            Start-Sleep -Milliseconds 10
        }
    }
})

$handle = $ps.BeginInvoke()

# Main: $QueueInstance.Enqueue($somePedalState)  # Or via $syncHash.TelemetryQueue.Enqueue(...)
```

**Quick Fix: Option 3 (Static with Isolation)**  
If falling back: Keep your Architecture A C# (static queue), but no code changes needed beyond namespace tweaks for "cleanliness." Use directly as in legacy, avoiding injection.

# AI NUMBER 4

## **Analysis of the Failure in Architecture B**

**Root Cause:** In PowerShell 5.1, when you pass objects between runspaces using `AddArgument()`, they undergo **marshaling via serialization** (not true object reference passing). For simple types, PowerShell uses the `PSObject` wrapper and serializes the object. While `ConcurrentQueue` itself is thread-safe, when marshaled between runspaces, PowerShell creates a **serialized copy**, not a live reference.

**Key Evidence:** 
- `ConcurrentQueue` is not marked as `[System.MarshalByRefObject]`
- PowerShell 5.1's remoting infrastructure serializes objects using `PSObject`
- The background runspace gets a **disconnected copy** that's populated with the queue's *current contents at serialization time*, not a live reference

## **Ranked Solutions (Most Elegant → Quickest Fix)**

### **Solution 1: Most Elegant - Use `[Threading.Thread]::VolatileRead/Write` with a Reference Wrapper**
Create a lightweight wrapper that holds the queue reference in a way that survives marshaling:

```powershell
# Main Script: FanatecPedals.ps1
Add-Type @"
using System.Collections.Concurrent;
using System.Threading;

namespace Fanatec {
    public static class TelemetryBridge {
        private static ConcurrentQueue<PedalMonState> _queue = new ConcurrentQueue<PedalMonState>();
        private static object _sync = new object();
        
        public static void Enqueue(PedalMonState state) {
            lock(_sync) {
                _queue.Enqueue(state);
            }
        }
        
        public static bool TryDequeue(out PedalMonState result) {
            lock(_sync) {
                return _queue.TryDequeue(out result);
            }
        }
        
        public static int Count {
            get { lock(_sync) return _queue.Count; }
        }
        
        // Critical: This returns a live reference to the queue
        public static object GetQueueReference() {
            return _queue;
        }
    }
}
"@

# Main thread
$queueRef = [Fanatec.TelemetryBridge]::GetQueueReference()

# Background thread setup
$ps = [PowerShell]::Create()
$ps.Runspace.SessionStateProxy.SetVariable('TelemetryQueueRef', $queueRef)
$ps.AddScript({
    # Access the shared reference
    $q = $ExecutionContext.SessionState.PSVariable.GetValue('TelemetryQueueRef')
    
    # Now $q is a live reference to the same queue
    $f = $null
    while ($true) {
        if ($q.TryDequeue([ref]$f)) {
            # Process $f
        }
        Start-Sleep -Milliseconds 1
    }
})
$asyncResult = $ps.BeginInvoke()
```

### **Solution 2: Robust - Use `[Runspace]::DefaultRunspace` with Synchronized Wrapper**
Create a thread-safe wrapper that registers itself in a synchronized manner:

```powershell
# Main Script
Add-Type @"
using System.Collections.Concurrent;
using System.Collections;
using System.Threading;

namespace Fanatec {
    public class SharedQueue : MarshalByRefObject {
        private readonly ConcurrentQueue<PedalMonState> _queue;
        
        public SharedQueue() {
            _queue = new ConcurrentQueue<PedalMonState>();
        }
        
        public void Enqueue(PedalMonState state) {
            _queue.Enqueue(state);
        }
        
        public bool TryDequeue(out PedalMonState result) {
            return _queue.TryDequeue(out result);
        }
        
        // Override to ensure infinite lifetime lease
        public override object InitializeLifetimeService() {
            return null; // Infinite lifetime
        }
    }
    
    public static class GlobalRegistry {
        private static readonly Hashtable _registry = Hashtable.Synchronized(new Hashtable());
        
        public static void Register(string key, object value) {
            _registry[key] = value;
        }
        
        public static object Get(string key) {
            return _registry[key];
        }
    }
}
"@

# Main thread
$sharedQueue = [Fanatec.SharedQueue]::new()
[Fanatec.GlobalRegistry]::Register("TelemetryQueue", $sharedQueue)

# Background thread
$ps = [PowerShell]::Create()
$ps.AddScript({
    # Retrieve from global registry
    $q = [Fanatec.GlobalRegistry]::Get("TelemetryQueue")
    
    $f = $null
    while ($true) {
        if ($q.TryDequeue([ref]$f)) {
            # Process $f
        }
        Start-Sleep -Milliseconds 1
    }
})
$asyncResult = $ps.BeginInvoke()

# Enqueue from main thread
$sharedQueue.Enqueue($state)
```

### **Solution 3: Quickest Fix - Use `SessionStateProxy.SetVariable` with InitialSessionState**
This leverages PowerShell's runspace initialization to share variables:

```powershell
# Main Script
$queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

# Create InitialSessionState with shared variable
$initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$initialSessionState.Variables.Add(
    [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
        'TelemetryQueue',
        $queue,
        'Shared telemetry queue',
        [System.Management.Automation.ScopedItemOptions]::AllScope
    )
)

# Create runspace pool with shared session state
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, 5, $initialSessionState, $Host)
$runspacePool.Open()

# Create PowerShell instance with shared runspace
$ps = [PowerShell]::Create()
$ps.RunspacePool = $runspacePool

$ps.AddScript({
    # Directly access the shared variable
    $f = $null
    while ($true) {
        if ($TelemetryQueue.TryDequeue([ref]$f)) {
            # Process $f
        }
        Start-Sleep -Milliseconds 1
    }
})
$asyncResult = $ps.BeginInvoke()

# From main thread: Enqueue directly
$queue.Enqueue($state)
```

### **Solution 4: Alternative Quick Fix - Use Memory-Mapped File for High-Performance IPC**
For ultra-low latency scenarios:

```powershell
# Requires .NET 4.0+ but available in PS 5.1
Add-Type @"
using System.IO.MemoryMappedFiles;
using System.Threading;

namespace Fanatec {
    public class MappedQueue {
        private readonly MemoryMappedFile _mmf;
        private readonly Mutex _mutex;
        private const int MAX_SIZE = 65536;
        
        public MappedQueue(string name) {
            _mmf = MemoryMappedFile.CreateOrOpen(name, MAX_SIZE);
            _mutex = new Mutex(false, name + "_Mutex");
        }
        
        public void Write(byte[] data) {
            _mutex.WaitOne();
            try {
                using (var stream = _mmf.CreateViewStream()) {
                    stream.Write(data, 0, data.Length);
                }
            }
            finally {
                _mutex.ReleaseMutex();
            }
        }
        
        public byte[] Read() {
            _mutex.WaitOne();
            try {
                using (var stream = _mmf.CreateViewStream()) {
                    byte[] buffer = new byte[MAX_SIZE];
                    int read = stream.Read(buffer, 0, buffer.Length);
                    Array.Resize(ref buffer, read);
                    return buffer;
                }
            }
            finally {
                _mutex.ReleaseMutex();
            }
        }
    }
}
"@

# Both threads create same named instance
$mmq = [Fanatec.MappedQueue]::new("FanatecTelemetry")
```

## **Recommendation for High-Performance Game Telemetry:**

**Go with Solution 1** with these enhancements:

```powershell
# Optimized version for high-frequency updates
Add-Type @"
using System.Collections.Concurrent;
using System.Threading;
using System.Runtime.CompilerServices;

namespace Fanatec {
    public static class TelemetryExchange {
        // Use Lazy<T> for thread-safe initialization
        private static readonly Lazy<ConcurrentQueue<PedalMonState>> _queue = 
            new Lazy<ConcurrentQueue<PedalMonState>>(() => 
                new ConcurrentQueue<PedalMonState>(), 
                LazyThreadSafetyMode.ExecutionAndPublication);
        
        // Fast-path enqueue with inlining hint
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static void Push(PedalMonState state) {
            _queue.Value.Enqueue(state);
        }
        
        // Batch dequeue for efficiency
        public static PedalMonState[] PullBatch(int maxCount) {
            var results = new PedalMonState[maxCount];
            int count = 0;
            PedalMonState item;
            
            while (count < maxCount && _queue.Value.TryDequeue(out item)) {
                results[count++] = item;
            }
            
            if (count < maxCount) {
                Array.Resize(ref results, count);
            }
            
            return results;
        }
        
        // Return the actual queue reference (no serialization)
        public static object GetLiveReference() {
            return _queue.Value;
        }
    }
}
"@
```

**Why this is optimal:**
1. **Zero serialization overhead** - True reference passing
2. **Memory barriers handled** by `Lazy<T>` with proper thread safety
3. **Inlining hints** for critical path methods
4. **Batch processing** reduces lock contention
5. **Works seamlessly** across PowerShell 5.1 runspaces

**Critical Implementation Notes:**
1. Always use `SessionStateProxy.SetVariable()` for passing object references between runspaces
2. Avoid `AddArgument()` for .NET object references in PS 5.1
3. Use `[Threading.Thread]::MemoryBarrier()` if you need explicit memory ordering guarantees
4. Consider implementing a ring buffer if queue overhead becomes significant

**Final Architecture:**
```powershell
# Main thread (joystick loop)
$queueRef = [Fanatec.TelemetryExchange]::GetLiveReference()

# HTTP background thread
$ps = [PowerShell]::Create()
$ps.Runspace.SessionStateProxy.SetVariable('TelemetryQueue', $queueRef)
$ps.AddScript({
    $q = $TelemetryQueue  # Live reference
    
    while ($true) {
        $batch = [Fanatec.TelemetryExchange]::PullBatch(100)
        if ($batch.Length > 0) {
            # Convert to JSON and serve via HTTP
            $batch | ConvertTo-Json -Compress
        }
        [System.Threading.Thread]::Sleep(1)  # 1ms sleep for CPU relief
    }
})
```

This architecture maintains sub-millisecond latency while ensuring thread safety and clean separation of concerns.

# AI NUMBER 5

## Analysis of PowerShell 5.1 Runspace Object Sharing

## Critical Analysis: Why Architecture B Fails

The fundamental issue is that **PowerShell 5.1 serializes .NET objects when passed via `AddArgument()`**, rather than maintaining live references. When you call `$ps.AddArgument($QueueInstance)`, PowerShell attempts to serialize the `ConcurrentQueue<PedalMonState>` object across the runspace boundary, creating a disconnected copy or empty proxy rather than maintaining the live reference to the original queue.

This behavior occurs because PowerShell's remoting infrastructure (which underlies runspace communication) is designed to serialize objects for safety and isolation between execution contexts. Unlike the static class approach where both runspaces access the same AppDomain memory location, instance objects passed via arguments undergo serialization.

## Evaluation of Solutions (Ranked)

### Solution 1: SessionStateProxy.SetVariable (Most Elegant & Robust)
This is the **recommended approach** for high-performance telemetry. It directly injects the live object reference into the background runspace's session state without serialization overhead.

```powershell
# Main Thread
$QueueInstance = [Fanatec.Shared]::TelemetryQueue

# Create runspace and set up session state
$runspace = [RunspaceFactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('LiveTelemetryQueue', $QueueInstance)  # Inject live reference 

# Background thread setup
$ps = [PowerShell]::Create()
$ps.Runspace = $runspace
$ps.AddScript({
    # Access the queue directly from session state - it's a LIVE reference
    $q = $LiveTelemetryQueue
    
    while ($true) {
        $state = $null
        if ($q.TryDequeue([ref]$state)) {
            # Process dequeued item
            $json = $state | ConvertTo-Json
            # HTTP server logic here
        }
        Start-Sleep -Milliseconds 10
    }
})
$ps.BeginInvoke()
```

### Solution 2: Synchronized Hashtable Bridge (Balanced Approach)
Uses a thread-safe hashtable as a container to hold the queue reference, which PowerShell handles better across runspaces.

```powershell
# Main Thread
$sharedState = [Hashtable]::Synchronized(@{})
$sharedState.TelemetryQueue = [Fanatec.Shared]::TelemetryQueue

# Background Thread Setup
$ps = [PowerShell]::Create()
$ps.AddArgument($sharedState)  # Hashtables maintain references better than direct objects 
$ps.AddScript({
    param($shared)
    
    $q = $shared.TelemetryQueue  # Still a live reference through the synchronized container
    
    while ($true) {
        $state = $null
        if ($q.TryDequeue([ref]$state)) {
            # Process dequeued item
        }
        Start-Sleep -Milliseconds 10
    }
})
$ps.BeginInvoke()
```

### Solution 3: Static Class Pattern (Quickest Fix)
While architecturally "dirty," this leverages AppDomain-level sharing that PowerShell 5.1 handles natively.

```powershell
# C# Definition (keep as-is)
namespace Fanatec {
    public static class Shared {
        public static ConcurrentQueue<PedalMonState> TelemetryQueue = new ConcurrentQueue<PedalMonState>();
    }
}

# Background Thread Setup (works reliably)
$ps = [PowerShell]::Create()
$ps.AddScript({
    # Direct static access - same AppDomain memory 
    $q = [Fanatec.Shared]::TelemetryQueue
    
    while ($true) {
        $state = $null
        if ($q.TryDequeue([ref]$state)) {
            # Process dequeued item
        }
        Start-Sleep -Milliseconds 10
    }
})
$ps.BeginInvoke()
```

## Specific Considerations

**SessionStateProxy.SetVariable**: Yes, this is the **optimal solution** for your scenario. It injects the live .NET object reference directly into the background runspace's session state without serialization, maintaining the exact same memory pointer. This approach is thread-safe because `ConcurrentQueue` handles its own synchronization, and the session state injection is atomic.

**[Hashtable]::Synchronized**: While this works as a bridge pattern, it adds an unnecessary layer of indirection. Hashtables can maintain references better than direct object passing, but they still involve some overhead compared to direct session state injection.

## Recommendation for High-Performance Telemetry

For your high-frequency game telemetry loop with latency sensitivity, **Solution 1 (SessionStateProxy.SetVariable) is strongly recommended** because:

1. **Zero Serialization Overhead**: Maintains direct memory references without serialization/deserialization costs
2. **Minimal Latency**: Objects are accessed at native .NET speed
3. **Thread Safety**: `ConcurrentQueue` provides lock-free thread-safe operations
4. **Architectural Cleanliness**: Avoids global static state while maintaining performance
5. **PowerShell 5.1 Compatibility**: Works reliably in your constrained environment

The performance difference is significant - serialization approaches can add 10-100ms of overhead per operation, while direct reference sharing operates at microsecond speeds. For joystick telemetry running at 100+ Hz, this difference is critical.

This pattern is used in production high-performance PowerShell systems and provides the perfect balance of architectural cleanliness and raw performance required for your telemetry system.

