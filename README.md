# claude-statusline

Know exactly where you stand with Claude Code, on one line, before you hit a limit.

```
code/my-project | opus-4-7/high | 12k/200k | 5h:80% [█○████░░] | 7d:36% [█████○░░] | $1.23
```

Directory, model and reasoning effort, context used, your two usage windows, and session
cost. The usage windows are the part worth learning — see below.

## Reading the usage gauge

Claude's Pro/Max usage is metered over a rolling 5-hour window and a rolling weekly window.
The hard part has always been pacing: *do I have room to start a big task, or am I about to
run dry?* That's two moving numbers — how much budget is left, and how much time is left —
and the gauge puts both on one bar.

The bar is your **trip through the window**. It fills left to right as time passes, and the
leading edge of the fill is **now**. The `○` marker is **how much of your budget you've
spent.** So the whole read is one glance: **is the marker behind the now-edge, or out ahead
of it?**

```
5h:80% [█○████░░]   conserving   — spent far less than the clock; the marker sits way back
                                   inside the elapsed time, fill stretching past it. Push.
5h:50% [████○░░░]   on pace      — the marker rides the leading edge of the fill. On track.
5h:25% [██░░░░○░]   overspending — the marker has run out past now into open water; the
                                   empty cells to its left are budget you no longer have.
                                   Ease off before the window resets.
```

The number in front (`80%`) is exactly how much budget you have left. The gauge answers the
*other* question — am I ahead of or behind the clock — so the two together tell you both how
much is in the tank and whether you're burning it too fast. If you spent at a perfectly even
rate, the marker would ride the now-edge the entire window; any gap you see is your pace.

See it on your own machine:

```bash
bash statusline.sh --demo        # Linux / macOS
pwsh statusline.ps1 --demo       # Windows
```

## Why you'll want it

- Pace the work, don't discover the limit mid-task. Both windows stay in view, and the gauge
  turns "am I ahead or behind?" into something you read without doing the math.
- The same line everywhere. Identical output on Windows, Linux, and macOS, with `jq` the only
  dependency. No Node, no runtime.
- One line to install.

## Prerequisites

- Claude Code installed
- Linux/macOS only: [`jq`](https://jqlang.github.io/jq/) ≥ 1.5 (`sudo apt install jq` / `brew install jq`)
- A terminal with a font that renders block glyphs (`█ ░`) — any modern terminal does

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
| `5h:80% [█○████░░]` | `rate_limits.five_hour` | Budget left, then a gauge of the 5-hour window. The bar fills with elapsed time (its leading edge is *now*); the `○` marks budget spent. Marker behind the edge = ahead of pace, marker past it = overspending. Shows a bare `5h:84%` with no gauge until the first API response provides a reset time. |
| `7d:36% [█████○░░]` | `rate_limits.seven_day` | Same gauge for the weekly window. |
| `$1.23` | `cost.total_cost_usd` | Your session cost so far, to the cent. The column is hidden until the first billed turn — `$0` stays off the line. |

A fresh session shows only directory, model, and context — the usage and cost fields have no
data until the first billed turn, so they stay off the line until then.
