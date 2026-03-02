This folder contains **three PowerShell 5.1 scripts** (Windows 10/11) that generate:

1. `compileall.bat` — compiles **all 27 combinations** of `-O{2,3,s}` × `-march {none, gracemont, raptorlake}` × `-mtune {none, gracemont, raptorlake}` with unique `.exe` names.
2. `runall.bat` — runs each produced `.exe` with recommended `--bench` args and prints a machine-parseable header before each run. You’ll run it like:
   `runall.bat > results.txt`
3. `Parse-Results.ps1` — parses `results.txt`, aggregates (supports multiple runs per exe), and prints winners by multiple criteria.

All scripts are **PowerShell 5.1 compatible**.


# Suggested workflow (quick checklist)

1. Put these PS1 scripts next to your `main.c`.
2. Generate batch files:

   * `powershell -ExecutionPolicy Bypass -File .\New-CompileAllBat.ps1`
   * `powershell -ExecutionPolicy Bypass -File .\New-RunAllBat.ps1`
3. Compile everything:

   * `compileall.bat`
4. Run everything and capture:

   * `runall.bat > results.txt`
5. Parse winners:

   * `powershell -ExecutionPolicy Bypass -File .\Parse-Results.ps1 -Path .\results.txt`

---

# A couple of “as you see fit” improvements (already included)

* `runall.bat` has `RUNS_PER_EXE` (default 1). Set to `3` for better stability.
* Both `start /affinity` and program `--affinitymask` are applied, so you get the pin even if one method fails.
* The parser groups multiple runs of the same flags and uses **median-of-medians** for robustness.

