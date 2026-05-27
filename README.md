# claude-statusline

A minimal, cross-platform [Claude Code](https://claude.com/claude-code) status line.
Identical output on Windows (PowerShell), Linux, and macOS (bash + `jq`):

```
code/cloudflare-telegram-proxy | sonnet-4-6 | 12k/200k | 5h:84%~68% | 1W:36%~29%
```

## Prerequisites

- Claude Code installed
- Linux/macOS only: [`jq`](https://jqlang.github.io/jq/) ≥ 1.5 (`sudo apt install jq` / `brew install jq`)

## Install

**Quick install** — one line, fetches the script straight from GitHub:

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/main/install.sh | bash
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/main/install.ps1 | iex
```

**Clone instead** — if you'd rather read the code first and keep a local copy to `git pull`:

```bash
# Linux / macOS
git clone https://github.com/MatthewMazaika/claude-statusline.git
cd claude-statusline
bash install.sh
```

```powershell
# Windows (PowerShell)
git clone https://github.com/MatthewMazaika/claude-statusline.git
cd claude-statusline
.\install.ps1
```

Either way the installer drops the script in `~/.claude/` and adds a `statusLine` entry
(with an absolute path) to `~/.claude/settings.json`. Restart Claude Code to see it.

## Update

Cloned? Pull and re-run the installer:

```bash
git pull && bash install.sh      # Linux/macOS
```

```powershell
git pull; .\install.ps1          # Windows
```

Used the one-liner? Just run it again.

## Format reference

| Field | Source | Notes |
|-------|--------|-------|
| `code/cloudflare-telegram-proxy` | `cwd` last 2 path segments | forward-slash normalized |
| `sonnet-4-6` | `model.id` with `claude-` stripped | |
| `12k/200k` | `context_window.total_input_tokens` / `context_window_size` | abbreviated k / M |
| `5h:84%~68%` | `rate_limits.five_hour` | `remaining%~expected%`; `~expected` omitted within ±3% |
| `1W:36%~29%` | `rate_limits.seven_day` | same, over a 168h window |

`expected = 100 − (elapsed / window × 100)`. Rate-limit fields appear only after the
first API call of a session, and are omitted from the line until then.
