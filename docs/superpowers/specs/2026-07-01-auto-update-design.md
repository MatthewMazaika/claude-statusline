# Auto-update for claude-statusline

## Purpose

Today, staying current requires the user to manually re-run the installer
(`git pull && install.sh`, or re-run the curl/irm one-liner). This design adds
silent, automatic self-updating so a deployed `~/.claude/statusline.sh` (or
`.ps1`) stays on the latest `v1.x` release without any manual action.

## Scope

Applies uniformly to `~/.claude/statusline.sh` and `~/.claude/statusline.ps1`
regardless of how they were originally installed (one-liner fetch or git
clone) — once deployed, both install paths produce the same file at the same
path, so auto-update operates purely at the deployed-script level. No changes
to `install.sh` / `install.ps1` / `release.yml` / `README.md` are required.

## Architecture

Self-update logic is embedded directly in both scripts, appended after the
existing statusline-rendering logic so it can never affect the primary
output or exit code. State is a single stamp file,
`~/.claude/.statusline-update-check`, holding the last-check timestamp.

On every invocation, **after** the statusline text has been computed and
printed:

1. If env var `CLAUDE_STATUSLINE_NO_UPDATE` is set (any non-empty value),
   skip everything below.
2. If the stamp file's mtime is younger than 24h, skip.
3. Otherwise, immediately rewrite the stamp file to "now" — this claims the
   check window before any network activity, so concurrent invocations
   (e.g. multiple open Claude Code panes rendering around the same time)
   don't all fire redundant checks.
4. Spawn a fully detached background process to perform the actual
   fetch/replace (Section: Fetch & replace). The parent process does not
   wait on it and exits immediately; the background process has no
   attachment to the parent's stdio or lifetime.

This keeps the hot render path at zero added latency: the only per-invocation
cost is a stamp-file mtime check (cheap filesystem stat), and that check only
ever triggers a spawn once per 24h.

## Fetch & replace (background process)

1. Fetch the current `v1`-tagged script from
   `https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/v1/statusline.sh`
   (or `.ps1`), using the same curl/wget fallback (bash) or
   `Invoke-WebRequest` (PowerShell) pattern the installers already use, with
   a short timeout (~5-10s total) so a slow/dead network can't leave the
   background process lingering.
2. Sanity-check the response before touching anything on disk:
   - non-empty
   - starts with the expected first line (`#!/usr/bin/env bash` for the
     bash script; the PowerShell header comment for the ps1 script)
   - size within a broad sane band of the current deployed file (guards
     against installing a GitHub error page or truncated response)
3. If the fetched content is byte-identical to the currently deployed file,
   do nothing further.
4. Otherwise, write the fetched content to a temp file in the same
   directory (`~/.claude/`), then atomically move/rename it over the
   deployed path (`mv` on POSIX; `Move-Item -Force` within the same volume
   on Windows). The deployed file is never observable in a half-written
   state, even if the process is killed mid-update.

## Error handling & edge cases

- **Network unreachable / timeout / GitHub down**: background process exits
  quietly. The stamp was already claimed for this window, so no retry until
  the next 24h boundary — no retry storms while offline.
- **No curl/wget available (bash) or fetch cmdlet error (PowerShell)**:
  swallowed, exits; no impact on the parent's already-returned output.
- **Corrupt/garbage response**: caught by the sanity check; deployed file
  left untouched.
- **Read-only or permission-denied `~/.claude`**: temp-file write fails,
  caught, swallowed; statusline continues working off the existing file.
- **Concurrent invocations racing the same throttle window**: the stamp
  file is rewritten before spawning, so any invocation arriving after sees
  a fresh stamp and skips — at most one background fetch per 24h window.
- **Self-replacement safety**: not a hazard in practice — by the time the
  background process actually swaps the file, the parent invocation that
  spawned it has already finished producing output and exited; the shell
  interpreters involved have already read what they need from the file for
  that invocation.

## Opt-out

`CLAUDE_STATUSLINE_NO_UPDATE` (any non-empty value) disables the entire
mechanism, checked before the stamp file is touched. Provided as a safety
valve for anyone who wants to pin their current version or avoid a
self-modifying script, at negligible implementation cost.

## Testing

No existing automated test suite in this repo; verification today is manual,
following the `CLAUDE_STATUSLINE_NOW`-style override convention already used
for deterministic rate-limit math testing. This design adds equivalent
overrides (e.g. for the stamp-file path and/or fetch URL) so the update path
can be exercised locally without waiting on the real 24h window or hitting
GitHub.

Manual verification plan:

1. Confirm invocation latency is unaffected both when the throttle window
   hasn't elapsed and when it has (the background spawn must not add
   measurable delay to stdout).
2. Force the throttle open, point the fetch override at a modified local
   fixture, confirm the deployed file is atomically replaced within a
   couple seconds.
3. Confirm `CLAUDE_STATUSLINE_NO_UPDATE` fully suppresses any file writes
   (no stamp file update, no background spawn).
