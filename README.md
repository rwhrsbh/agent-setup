# agent-setup

🎮 One command. Finds every agent on your machine. Installs for each.

```bash
# macOS · Linux · WSL · Git Bash
curl -fsSL https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/install.sh | bash
```

```powershell
# Windows · PowerShell 5.1+
irm https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/install.ps1 | iex
```

Sets up [caveman](https://github.com/JuliusBrussee/caveman) in ultra mode, the
[Roblox Studio MCP server](https://github.com/Chrrxs/robloxstudio-mcp), and the
[roblox-game skill](https://github.com/brockmartin/roblox-game-skill) — everywhere at once.

## What you get

| Agent | caveman | Badge | Roblox MCP | roblox-game |
|---|:---:|:---:|:---:|:---:|
| Claude Code | ✅ | ✅ | ✅ | ✅ |
| opencode | ✅ | — | ✅ | ✅ |
| Gemini CLI | ✅ | — | ✅ | ✅ |
| Antigravity (`agy`) | ✅ | — | ✅ | ✅ |
| Codex | ✅ | — | ✅ | ✅ |
| Cursor · Windsurf · Cline · Copilot · Trae | ✅ | — | — | ✅ |

Badge is Claude Code only — it's the one agent with a configurable statusline.
opencode's TUI has no plugin-writable badge; Gemini, Antigravity and Codex have no
statusline hook at all.

Ultra mode is the default. Change it with `--mode lite|full|ultra`.

## Options

```bash
curl -fsSL .../install.sh | bash -s -- --dry-run     # show everything, change nothing
curl -fsSL .../install.sh | bash -s -- --no-roblox   # caveman only
curl -fsSL .../install.sh | bash -s -- --mode full   # lite · full · ultra · wenyan*
curl -fsSL .../install.sh | bash -s -- --force       # reinstall
```

`iex` can't pass parameters, so on Windows save the file first:

```powershell
irm https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/install.ps1 -OutFile install.ps1
.\install.ps1 -DryRun      # -NoRoblox · -Mode full · -Force
```

## Good to know

- **Never breaks your configs.** MCP entries are merged, not overwritten — your other
  servers, themes and auth survive. Bad JSON is reported, never silently replaced.
- **Never aborts.** A failing agent becomes a warning; everything else still installs.
  Ends with `N done / N skipped / N warnings`.
- **Idempotent.** Re-run any time. Already-installed things are skipped.
- **Installs no CLIs.** It configures the agents you already have. Missing ones are
  skipped with a link to their installer.

**Needs:** Node ≥ 18, `git`. Windows: PowerShell 5.1+ (7+ better).

**After install:** restart Roblox Studio (and enable *Allow HTTP Requests* in
Game Settings → Security). Gemini CLI and Antigravity need their own login before
their MCP servers connect — the config is written, you sign in once.

## Uninstall

```bash
npx -y github:JuliusBrussee/caveman -- --uninstall
claude mcp remove robloxstudio
```

MIT
