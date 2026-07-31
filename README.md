# agent-setup

One command to set up [caveman](https://github.com/JuliusBrussee/caveman) (ultra mode),
the [Roblox Studio MCP server](https://github.com/Chrrxs/robloxstudio-mcp), and the
[roblox-game skill](https://github.com/brockmartin/roblox-game-skill) across every AI
coding agent on your machine.

## Install

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/setup-agents.sh -o setup-agents.sh
bash setup-agents.sh
```

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/setup-agents.ps1 -OutFile setup-agents.ps1
.\setup-agents.ps1
```

Read the script before running it — it writes to your agent config directories.
Pass `--dry-run` (bash) or `-DryRun` (PowerShell) to see every action without changing
anything.

## What it does

| Agent | caveman | Badge | Roblox MCP | roblox-game skill |
|---|---|---|---|---|
| Claude Code | yes | **yes** | yes | yes |
| opencode | yes | no | yes | yes |
| Gemini CLI | yes | no | yes | yes |
| Antigravity (`agy`) | yes | no | yes | yes |
| Codex | yes | no | yes | — |
| Cursor / Copilot / Trae / … | yes | no | — | — |

Only Claude Code gets a status badge: it is the only agent with a user-configurable
statusline. opencode's TUI exposes no plugin-writable badge, and Gemini CLI,
Antigravity and Codex have no statusline hook at all.

It also sets `CAVEMAN_DEFAULT_MODE=ultra` in your shell profile (bash) or user
environment (PowerShell), and writes the live mode flag so running sessions pick it up
without a restart.

## Options

| bash | PowerShell | Effect |
|---|---|---|
| `--dry-run` | `-DryRun` | Print every action, change nothing |
| `--no-roblox` | `-NoRoblox` | Skip the Roblox MCP server and skill |
| `--mode <m>` | `-Mode <m>` | caveman level: `lite`, `full`, `ultra` (default), `wenyan*` |
| `--force` | `-Force` | Reinstall even if already present |

## Behaviour

- **Never aborts.** A failing agent is recorded as a warning; the rest still install.
  The run ends with a `N done / N skipped / N warnings` summary and exits 0.
- **Idempotent.** Re-running skips what is already installed. Use `--force` to redo it.
- **Non-destructive to other MCP servers.** Configs are merged, not overwritten — only
  the `robloxstudio` key is touched. Existing settings (themes, auth, other servers)
  are preserved. Invalid JSON is reported rather than silently replaced.
- **Installs nothing you did not ask for.** It configures agents that are already on
  your machine. It will not install Claude Code, Gemini CLI, Antigravity or Codex for
  you — missing ones are skipped with a pointer to their installer.

## Requirements

- Node.js ≥ 18 (hard requirement — the installer and all JSON merging run through it)
- `git` for the roblox-game skill
- PowerShell 5.1+ on Windows (7+ recommended)

## Notes

- **Antigravity and Gemini CLI need a login** before their MCP servers can connect
  (`agy` uses Google OAuth; Gemini CLI needs `GEMINI_API_KEY` or a login). The script
  writes the config; you sign in once yourself.
- **Roblox Studio must be restarted** after install so the plugin reconnects. Enable
  *Allow HTTP Requests* in Game Settings → Security.
- **cavecrew subagents do not load under Gemini CLI.** Their tool names are
  Claude Code's, which Gemini rejects. caveman itself works fine; the three subagents
  are simply skipped.
- The caveman installer also drops its skills into the shared `~/.agents/skills` tree.
  Gemini scans both that tree and its own extensions, so the duplicates get removed —
  otherwise every command is renamed (`/caveman` → `/caveman1`).

## Uninstall

```bash
npx -y github:JuliusBrussee/caveman -- --uninstall
```

Roblox MCP entries are removed with `claude mcp remove robloxstudio`, or by deleting the
`robloxstudio` key from the relevant agent config.

## License

MIT
