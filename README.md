# claude-statusline

Know exactly where you stand with Claude Code, on one line, before you hit a limit.

```
code/my-project | opus-4-7/high | 12k/200k | 5h:84%~68% | 7d:36%~29% | $1.23
```

You're in **`code/my-project`** on **`opus-4-7`** at **`high`** reasoning effort, **12k of 200k
context** in. **84% of your 5-hour budget left**, **68% of the window still to go** — budget's
outpacing the clock, plenty of room to start that deep dive. Same shape for the week:
**36% budget, 29% clock**. The session's run **$1.23** so far. Read `~` as the clock side:
budget > clock = room to push, budget < clock = tread lightly or you'll run out.

## Why you'll want it

- See the cap coming. Pro and Max usage is metered over a rolling 5-hour window and a rolling
  weekly window; keeping both in view lets you pace the work instead of discovering the limit
  mid-task.
- The same line everywhere. Identical output on Windows, Linux, and macOS, with `jq` the only
  dependency. No Node, no runtime.
- One line to install.

## Prerequisites

- Claude Code installed
- Linux/macOS only: [`jq`](https://jqlang.github.io/jq/) ≥ 1.5 (`sudo apt install jq` / `brew install jq`)

## Install

Quick install — one line, fetches the script straight from GitHub.

Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/main/install.sh | bash
```

Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/main/install.ps1 | iex
```

Clone instead — if you'd rather read the code first and keep a local copy to `git pull`.

Linux / macOS

```bash
git clone https://github.com/MatthewMazaika/claude-statusline.git
cd claude-statusline
bash install.sh
```

Windows (PowerShell)

```powershell
git clone https://github.com/MatthewMazaika/claude-statusline.git
cd claude-statusline
.\install.ps1
```

Either way the installer drops the script in `~/.claude/` and adds a `statusLine` entry
(with an absolute path) to `~/.claude/settings.json`. Restart Claude Code to see it.

## Update

Cloned? Pull and re-run the installer.

Linux / macOS

```bash
git pull && bash install.sh
```

Windows (PowerShell)

```powershell
git pull; .\install.ps1
```

Used the one-liner? Just run it again.

## Format reference

| Field | Source | Notes |
|-------|--------|-------|
| `code/my-project` | your current working directory | last 2 path segments, forward-slash normalized |
| `opus-4-7/high` | `model.id` with `claude-` stripped, then `/effort.level` | The `/effort` suffix is omitted for models that don't expose a reasoning effort level. |
| `12k/200k` | `context_window.total_input_tokens` / `context_window_size` | abbreviated k / M |
| `5h:84%~68%` | `rate_limits.five_hour` | Your 5-hour limit: how much you have left, then how much of the window is left — even spending keeps the two equal. The `~` figure disappears when they're within 3%. |
| `7d:36%~29%` | `rate_limits.seven_day` | Your weekly limit: how much you have left, then how much of the week is left — even spending keeps the two equal. The `~` figure disappears when they're within 3%. |
| `$1.23` | `cost.total_cost_usd` | Your session cost so far, to the cent. The column is hidden until the first billed turn — `$0` stays off the line. |

`expected = 100 − (elapsed / window × 100)`. Rate-limit and cost fields appear only
after the first API call of a session, and are omitted from the line until then.
