# Project instructions

## Code style

- Write code with comments. Always explain functions in detail, including input and output data types.
- After every prompt, add suggestions in case the user wants to make changes or improvements.

## Design principles:
Any prompt that is created/opened must be closeable/unseelctable with esc key.

## Useful skills for this project

When the task matches, prefer invoking these skills over re-deriving the workflow inline:

- **`/verify`** — for confirming UI changes (panels, click flows, hover/select behavior) actually work in the running app. Headless mode catches parse errors but not visual bugs; use this after non-trivial scene edits.
- **`/simplify`** — after large rewrites (e.g. the GameState.gd schema overhaul, the panel scripts), runs a reuse/quality/efficiency pass on changed code.
- **`/review`** — when pushing a PR or finishing a feature arc (families+relations was one; family-tree visualisation is the next candidate).
- **`/fewer-permission-prompts`** — this project triggers a lot of `Godot_v4.6.2-stable_win64_console.exe` and Python invocations. Worth running once to allowlist the common read-only ones.
- **`/security-review`** — low priority for an offline game, but valid before any export build that ships SQLite or executes user-supplied data.

Skills NOT relevant here:
- `/claude-api` (no Anthropic SDK in-tree), `/loop` / `/schedule` (no recurring jobs), `/init` (already initialised), `/keybindings-help` (editor config, not project work), `/update-config` (settings.json edits only).

## Token efficiency

This codebase has some genuinely large files (`MapData.gd` ~1000 lines, `GameState.gd` ~700 lines, `extract_design.py` ~430 lines, plus the multi-megabyte `gb_godot.json`). To keep iterations fast:

- **Read narrowly.** Use `Read` with `offset`/`limit` when revisiting a known section of a large file. Full reads of `gb_godot.json` should never happen — use `Grep` or `python -c` with `json.load` for targeted extracts.
- **Trust the harness.** Don't re-read a file immediately after `Edit`/`Write` — the tool errors if the change failed.
- **Pipe Godot headless output through `head -N`.** The boilerplate after `_ready END` rarely matters; the first 30-40 lines contain everything diagnostic.
- **Inspect SQLite once.** After a seed/migration is verified, trust the query — repeat inspections add no signal.
- **Prefer `Edit` over `Write`.** Use `Write` only for new files or genuine full rewrites; `Edit` only sends the diff.
- **Use `Grep` with `output_mode: files_with_matches`** for existence checks. Switch to `content` only when you actually need surrounding lines.
- **Batch independent reads in parallel.** Multiple `Read` / `Grep` calls in a single message rather than sequentially when there's no dependency.
- **Skip the auto-loaded `CLAUDE.md` re-reads.** It's already in context.

## Commit message format

Finish every prompt output with the following style of git commit message:

```
Appropriate context named Update

Changelog:
- Improved hover and select modes.
- Added database browser.

If applicable:
Bugfixes:
- bugfix

If applicable:
Work in Progress:
- Work item
```
