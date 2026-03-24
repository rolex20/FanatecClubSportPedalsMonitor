# AGENTS.md

Read [docs/coding-culture.md](docs/coding-culture.md) before making code changes in this repo.
That file is the full source of truth for coding style, comment style, optimization culture,
and collaboration workflow. Do not replace it with a summary; follow it as written.

Operational notes for this repo:

- For code changes, default to this workflow unless the user explicitly asks for something else:
  1. create a new `codex/*` branch
  2. implement the requested changes
  3. stop and tell the user the code is ready for review/edit
  4. wait for the user to finish edits or approve
  5. then commit, push, and create the PR with `gh`
  6. the user does the final merge in GitHub

- On this PC, when building with MSYS2 UCRT GCC, run `C:/msys64/ucrt64/bin/gcc.exe`
  with the process working directory set to `C:/msys64/ucrt64/bin`.
  See [.vscode/tasks.json](.vscode/tasks.json) for the working setup.
