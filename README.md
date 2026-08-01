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
[Roblox Studio MCP server](https://github.com/Chrrxs/robloxstudio-mcp), the
[roblox-game skill](https://github.com/brockmartin/roblox-game-skill), and 22
design/taste skills — everywhere at once.

## What you get

| Agent | caveman | Badge | Roblox MCP | Skills |
|---|:---:|:---:|:---:|:---:|
| Claude Code | ✅ | ✅ | ✅ | ✅ |
| opencode | ✅ | — | ✅ | ✅ |
| Gemini CLI | ✅ | — | ✅ | ✅ |
| Antigravity (`agy`) | ✅ | — | ✅ | ✅ |
| Cline | ✅ | — | ✅ | ✅ |
| Codex | ✅ | — | ✅ | ✅ |
| Cursor · Windsurf · Trae · Copilot | ✅ | — | — | ✅ |
| ~50 more the skills CLI knows | — | — | — | ✅ |

**Skills** covers `roblox-game` plus three design packs — 22 skills in all:
[emilkowalski/skills](https://github.com/emilkowalski/skills) (8: animation,
Apple-style motion, UI polish), [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill)
(13: anti-slop frontend, brand kits, image-to-code) and
[pbakaus/impeccable](https://github.com/pbakaus/impeccable) (1: frontend design
critique + live iteration). Skip them with `--no-design` / `-NoDesign`.

Badge is Claude Code only — it's the one agent with a configurable statusline.
opencode's TUI has no plugin-writable badge; Gemini, Antigravity, Cline and Codex
have no statusline hook at all.

Codex, Cursor, Cline and Copilot share one skills tree at `~/.agents/skills`, and
Gemini CLI reads it too — so every one of them is served by a single copy. That is
why the script installs **no Gemini extension**: an extension duplicates skills
Gemini already sees in the shared tree, and Gemini responds by renaming the commands
(`/caveman` becomes `/caveman1`) and shadowing one copy. Gemini instead gets its
always-on caveman rule from `~/.gemini/GEMINI.md`, which imports the same shared
files. Any leftover extension from an older run is removed.

Ultra mode is the default. Change it with `--mode lite|full|ultra`.

## Options

```bash
curl -fsSL .../install.sh | bash -s -- --dry-run     # show everything, change nothing
curl -fsSL .../install.sh | bash -s -- --no-roblox   # skip Roblox MCP + skill
curl -fsSL .../install.sh | bash -s -- --no-design   # skip the design skill packs
curl -fsSL .../install.sh | bash -s -- --mode full   # lite · full · ultra · wenyan*
curl -fsSL .../install.sh | bash -s -- --force       # reinstall
```

`iex` can't pass parameters, so on Windows save the file first:

```powershell
irm https://raw.githubusercontent.com/rwhrsbh/agent-setup/main/install.ps1 -OutFile install.ps1
.\install.ps1 -DryRun      # -NoRoblox · -NoDesign · -Mode full · -Force
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
rm -rf ~/.agents/skills          # shared skills (codex/cursor/cline/copilot/gemini)
```

MIT
