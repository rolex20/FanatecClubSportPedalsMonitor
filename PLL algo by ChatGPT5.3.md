- Act as an expert system engineer with deep expertise as a game developer in c, powershell and c#

- Help me plan the following task (don't code yet):

- I need to integrate the existing PedMon (main.c) and PedBridge.ps1 into only one new Powershell script named FanatecPedals.ps1.  This way when I need to make changes in main.c I won't need to go to my developer laptop to recompile, then take the executable and test it in my gaming pc and go back to the laptop to fix any issues.  With the new FanatecPedals.ps1, I will be able to make changes to FanatecPedals.ps1 and test them directly into my gaming PC.  I've tested PedMon (main.c) and PedBridge.ps1 and they are so fast that I am not concerned about delays, besides the deep interactions with the windows API for Joystick will need to be done from a helper c# class which is compiled and will run fast so no worries there.

- I also need **absolutely all** user message strings from PedMon (main.c) and PedBridge.ps1 to be at the top of the new FanatecPedals.ps1 so I can easily modify them without the need for hunting them all over the code like a monkey.

- The same with configuration defaults, all at the top but after the strings.

- Also, it won't be necessary for the new FanatecPedals.ps1 to use a shared memory to read the values from the Joystick.   New FanatecPedals.ps1 will read the values from the joystick with a helper c# class and after that they can be made available to the http server by adding it to the list of frames handled by the current concurrent collection as it is doing now in PedBridge.ps1.

- This means that the new FanatecPedals.ps1 will need to leverage all possible benefits from a single integrated program instead of having two programs PedMon (main.c) and PedBridge.ps1

- The new FanatecPedals.ps1 needs to run perfectly on Powershell 5.1 on my gaming Windows 11 PC (Galvatron)

- The new FanatecPedals.ps1 will leverage all idiomatic benefits of powershell 5.1\n

- The new FanatecPedals.ps1 will minimize as much as possible the use of c# helper classes.  Only the bare minimun Win API calls and whatever else that really must be on C#:  This way the user will be able to easily make changes and test them in the gaming PC.  The user is familiar with powershell but not with changing c# code.

- The new FanatecPedals.ps1 needs to handle the same command lines that PedMon (main.c) actually handles.  The new FanatecPedals.ps1 will always perform TTS on all the same events that old PedMon (main.c) and PedBridge.ps1 actually do.   You can use the Powershell's native way to handle argument/command line parameters so no particular need to replicate or mirror the functionality in  <getopt.h>

- The new FanatecPedals.ps1 will always use async speak calls to avoid blocking (the same way it is doing now)

- The new FanatecPedals.ps1 needs to deliver exactly the same telemetry values via HTTP as PedBridge.ps1

- The new FanatecPedals.ps1 still needs several threads, one to read the telemetry at the specified interval and add/accumulate the samples/frames in an efficient/concurrent collection/structure (in the same way that is doing right now) and at least another to do the web serving.

- The new FanatecPedals.ps1 default behavior will be to display help and exit when no command line arguments were used.

- All this means, do not touch the current PedMon in (main.c ) or PedBridge.ps1

- CRITICAL: There are other components (PedDash.html), that rely on each one of the metrics/telemetry sent by the existing PedBridge.ps1 so is critical that the new FanatecPedals.ps1 exposes exactly the same ones to maintain 100% compatibility.

- Add the same type of protection to the redefinition of the add type  for c shell from the current PedBridge, I am talking about this: (snippet follows from PedBridge.ps1)
```
Powershell
} else {
    Write-Warning "Using existing C# definition. If you modified the C# code, please restart PowerShell."
}
```

- Add any other recommendations you can think of.

- Please create the technical plan to do this in one shot.







