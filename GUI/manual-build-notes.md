# Manual Build Instructions for PedDash

This app is a C# WinUI 3 + Win2D desktop app.

## Important rules before you build

- Keep the project `x64` only.
- Do not switch to `AnyCPU`.
- The supported unpackaged deliverable is `bin\win-x64\publish`.
- The normal supported publish path keeps trimming disabled.
- `PublishTrimmed=false` is the safe default for this repo.

## Recommended CLI commands

Run all commands from the folder that contains `PedDash.csproj`.

### 1. Restore packages

```powershell
dotnet restore PedDash.csproj
```

Use this when NuGet packages are missing, after clearing caches, or after pulling dependency changes.

### 2. Clean the Debug x64 output

```powershell
dotnet clean PedDash.csproj -c Debug -p:Platform=x64
```

Use this to remove the current Debug build artifacts before a fresh rebuild.

### 3. Build Debug x64

```powershell
dotnet build PedDash.csproj -c Debug -p:Platform=x64
```

Use this for normal local development validation.  
Expected output path:

```text
bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64
```

### 4. Publish Release x64 without trimming

```powershell
dotnet publish PedDash.csproj -c Release /p:PublishProfile=win-x64
```

This is the normal supported publish command for this repo.  
Expected output path:

```text
bin\win-x64\publish
```

This uses the existing publish profile and keeps:

- `Platform=x64`
- `RuntimeIdentifier=win-x64`
- `SelfContained=true`
- `PublishTrimmed=false`

### 5. Optional Release build without publishing

```powershell
dotnet build PedDash.csproj -c Release -p:Platform=x64
```

Use this if you only want a Release compile check without producing the publish folder.

## Forced trimming command

```powershell
dotnet publish PedDash.csproj -c Release /p:PublishProfile=win-x64 -p:PublishTrimmed=true -p:PublishDir=bin\win-x64\publish-trimmed\
```

Use this only as an experiment or size-comparison build.

Why the separate output folder matters:

- It avoids overwriting the supported non-trimmed publish output.
- It makes it easy to compare the trimmed and non-trimmed builds side by side.

## Why forced trimming is risky here

This repo intentionally keeps trimming off by default.

### Practical disadvantages

- Trimming can remove code that is only discovered through reflection, runtime activation, or dynamic access patterns.
- Desktop UI stacks on Windows are often more trim-sensitive than simple console apps.
- A trimmed build can launch and still fail later in a specific screen, control, serialization path, or WinRT interaction.
- Debugging trimmed-build failures is usually slower because missing members are removed at publish time.

### Specific .NET trimming concerns

- Reflection-heavy code is a known trimming risk.
- Dynamic assembly loading is a known trimming risk.
- Built-in COM marshalling on Windows is a known trimming risk.
- In .NET 8, `PublishTrimmed=true` also disables reflection-based `System.Text.Json` defaults unless you explicitly opt back in.

For PedDash, that means a trimmed publish should be treated as a test artifact, not the primary supported deliverable.

## Visual Studio 2026 GUI publish instructions

These steps are written for the current Visual Studio 2026 line.  
If a minor update renames a button slightly, use the same publish-profile settings with the closest matching label.

## Publish without trimming in Visual Studio 2026

### First-time profile setup

1. Open the `PedDash` project in Visual Studio 2026.
2. In Solution Explorer, right-click the `PedDash` project.
3. Select `Publish`.
4. If no publish profile exists yet, choose `Folder`.
5. Set the target folder to:

```text
bin\win-x64\publish
```

6. Save the profile as `win-x64` if Visual Studio asks for a name.

### Profile settings to keep

In the publish profile settings, confirm these values:

- `Configuration`: `Release`
- `Target runtime`: `win-x64`
- `Deployment mode`: `Self-contained`
- `Trim unused code`: `Off` or unchecked
- `Produce single file`: `Off` or unchecked
- `Platform`: `x64` if that field is shown

Do not change the app to `Any CPU`.

### Publish steps

1. Open the `Publish` page for the `PedDash` project.
2. Select the `win-x64` folder profile.
3. Confirm the target folder is `bin\win-x64\publish`.
4. Confirm trimming is disabled.
5. Click `Publish`.
6. After publish completes, test `PedDash.exe` from:

```text
bin\win-x64\publish
```

## Publish with trimming in Visual Studio 2026

This is the experimental path.

### Create a separate trimmed profile

1. Open the `Publish` page for the `PedDash` project.
2. Duplicate the existing `win-x64` profile if Visual Studio offers `Duplicate`.
3. If duplicate is not available, create a new `Folder` profile manually.
4. Name it something like `win-x64-trimmed`.
5. Set the publish folder to:

```text
bin\win-x64\publish-trimmed
```

### Trimmed profile settings

In the trimmed profile settings, use:

- `Configuration`: `Release`
- `Target runtime`: `win-x64`
- `Deployment mode`: `Self-contained`
- `Trim unused code`: `On` or checked
- `Produce single file`: `Off` unless you are testing that separately
- `Platform`: `x64` if shown

### Publish steps

1. Select the trimmed folder profile.
2. Confirm the output folder is `bin\win-x64\publish-trimmed`.
3. Turn trimming on.
4. Click `Publish`.
5. Launch the trimmed `PedDash.exe`.
6. Test the important UI paths, not just startup:

- Main window load
- Racing page
- Signals page
- Export actions
- Config page
- Any hardware-related path you use in production

If the trimmed build behaves differently, keep using the non-trimmed publish as the supported output.

## Recommended workflow

For normal work:

```powershell
dotnet clean PedDash.csproj -c Debug -p:Platform=x64
dotnet build PedDash.csproj -c Debug -p:Platform=x64
dotnet publish PedDash.csproj -c Release /p:PublishProfile=win-x64
```

For trimming experiments only:

```powershell
dotnet publish PedDash.csproj -c Release /p:PublishProfile=win-x64 -p:PublishTrimmed=true -p:PublishDir=bin\win-x64\publish-trimmed\
```

## Bottom line

- Supported publish: non-trimmed `bin\win-x64\publish`
- Experimental publish: trimmed `bin\win-x64\publish-trimmed`
- Keep `x64`
- Do not use `AnyCPU`
- Do not treat the trimmed build as the default deliverable unless it is thoroughly revalidated
