<#
.SYNOPSIS
  One-click install: caveman (ultra default) + robloxstudio-mcp across every agent.

.DESCRIPTION
  Installs caveman into every supported agent found on this machine (Claude Code,
  opencode, Gemini CLI, Antigravity, Codex, Cursor, Copilot, ...), sets ultra as the
  default compression mode, wires the Claude Code statusline badge, and registers the
  Roblox Studio MCP server everywhere it is supported.

  Never aborts on a failed step: failures are collected and printed as a warning
  summary at the end. Requires PowerShell 5.1+ (7+ recommended).

.EXAMPLE
  .\setup-agents.ps1
  .\setup-agents.ps1 -DryRun
  .\setup-agents.ps1 -NoRoblox -Mode full
  .\setup-agents.ps1 -Force
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$NoRoblox,
  [switch]$Force,
  [ValidateSet('lite','full','ultra','wenyan','wenyan-lite','wenyan-full','wenyan-ultra')]
  [string]$Mode = 'ultra'
)

$ErrorActionPreference = 'Continue'   # a failed agent must not kill the run
$RbxPkg      = '@chrrxs/robloxstudio-mcp'
$RbxVersion  = '2.23.0'
$RbxSkillRepo = 'https://github.com/brockmartin/roblox-game-skill'

$script:Warnings = [System.Collections.ArrayList]::new()
$script:Skipped  = [System.Collections.ArrayList]::new()
$script:Done     = [System.Collections.ArrayList]::new()

function Say  { param($m) Write-Host "`n$m" -ForegroundColor DarkYellow }
function Info { param($m) Write-Host "  $m" }
function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green;  [void]$script:Done.Add($m) }
function Skip { param($m) Write-Host "  = $m" -ForegroundColor DarkGray; [void]$script:Skipped.Add($m) }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow; [void]$script:Warnings.Add($m) }

function Test-Cmd { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# Set inside the gemini block; declared here so later sections can read it even
# when gemini is absent.
$geminiHasExt = $false

# $env:USERPROFILE / $env:TEMP are Windows-only. Fall back to the
# cross-platform values so the script also runs under pwsh on macOS/Linux.
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$TempDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }

# PS 5.1 has no ConvertFrom-Json -AsHashtable, so go through node for all JSON
# merges. Node is a hard requirement anyway.
function Invoke-NodeJson {
  param([string]$Script, [string[]]$NodeArgs)
  if ($DryRun) { return $true }
  & node -e $Script @NodeArgs
  return ($LASTEXITCODE -eq 0)
}

foreach ($p in @(
  "$env:LOCALAPPDATA\Programs\Antigravity\bin",
  "$env:APPDATA\npm",
  (Join-Path (Join-Path $HomeDir '.opencode') 'bin'),
  (Join-Path (Join-Path $HomeDir '.local') 'bin')
)) { if (Test-Path $p) { $env:PATH = "$p;$env:PATH" } }

# ------------------------------------------------------------------ preflight
Say '== preflight =='
if (-not (Test-Cmd node)) { Write-Error 'FATAL: node (>=18) required. https://nodejs.org'; exit 1 }
$nodeMajor = [int](& node -p "process.versions.node.split('.')[0]")
if ($nodeMajor -lt 18) { Write-Error "FATAL: node >=18 required (have $nodeMajor)"; exit 1 }
Ok "node $(& node -v)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Warn "PowerShell $($PSVersionTable.PSVersion) — 7+ recommended (JSON handled via node, so this should still work)"
}

# Join-Path rather than "$dir\sub": the backslash literal only resolves on
# Windows, and pwsh on macOS/Linux would treat it as part of the filename.
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HomeDir '.claude' }
$OpencodeDir = if ($env:APPDATA -and (Test-Path (Join-Path $env:APPDATA 'opencode'))) {
  Join-Path $env:APPDATA 'opencode'
} else {
  Join-Path (Join-Path $HomeDir '.config') 'opencode'
}
$GeminiDir = Join-Path $HomeDir '.gemini'
# Antigravity IDE + CLI share this central MCP config.
# Nested Join-Path: the 3-argument form needs PowerShell 6+.
$AntigravityMcp = Join-Path (Join-Path $GeminiDir 'config') 'mcp_config.json'
$CodexDir = Join-Path $HomeDir '.codex'

# -------------------------------------------------------------------- caveman
Say '== caveman =='
$cavemanPresent = Test-Path (Join-Path (Join-Path (Join-Path $ClaudeDir 'plugins') 'cache') 'caveman')
if ($cavemanPresent -and -not $Force) {
  Skip 'caveman already installed (-Force to reinstall)'
} else {
  if ($DryRun) {
    Info '$ npx -y github:JuliusBrussee/caveman --all'
  } else {
    & npx -y github:JuliusBrussee/caveman --all
    if ($LASTEXITCODE -eq 0) { Ok 'caveman installed' }
    else { Warn "caveman installer failed (exit $LASTEXITCODE) — agents below may be unconfigured" }
  }
}

# Gemini CLI < 0.2 has no `extensions` subcommand. It still exits 0 on
# `extensions --help` (prints global help), so probe the output text instead.
if (Test-Cmd gemini) {
  $gver = (& gemini --version 2>$null | Select-Object -First 1)
  $extHelp = (& gemini extensions --help 2>&1 | Out-String)
  $geminiHasExt = $extHelp -match 'extensions'
  if ($geminiHasExt) {
    Ok "gemini $gver supports extensions"
  } else {
    Warn "gemini $gver too old for 'extensions install' — falling back to GEMINI.md"
    Info 'upgrade it yourself for the native path: npm i -g @google/gemini-cli'
  }

  # Only fall back to GEMINI.md when the native extension path is unavailable.
  if (-not $geminiHasExt) {
    $gmd = (Join-Path $GeminiDir 'GEMINI.md')
    if ((Test-Path $gmd) -and ((Get-Item $gmd).Length -gt 0) -and -not $Force) {
      Skip 'GEMINI.md already has content, left alone'
    } elseif ($DryRun) {
      Info "`$ download caveman rule -> $gmd"
    } else {
      try {
        New-Item -ItemType Directory -Force -Path $GeminiDir | Out-Null
        $ruleUrl = 'https://raw.githubusercontent.com/JuliusBrussee/caveman/main/src/rules/caveman-activate.md'
        Invoke-WebRequest -Uri $ruleUrl -OutFile $gmd -UseBasicParsing
        Ok 'fallback GEMINI.md written'
      } catch {
        Warn 'could not fetch caveman rule for GEMINI.md fallback'
      }
    }
  } else {
    # Native path: install the caveman extension.
    $extList = (& gemini extensions list 2>&1 | Out-String)
    if (($extList -match 'caveman') -and -not $Force) {
      Skip 'gemini: caveman extension already installed'
    } elseif ($DryRun) {
      Info '$ gemini extensions install https://github.com/JuliusBrussee/caveman'
    } else {
      # "already installed" counts as success: agy's `plugin import` can restore
      # the extension before this step runs, so the install legitimately no-ops.
      $out = ('y' | & gemini extensions install https://github.com/JuliusBrussee/caveman 2>&1 | Out-String)
      if ($out -match 'installed successfully|already installed') {
        Ok 'gemini caveman extension installed'
        Info 'cavecrew subagents fail to load on gemini (Claude tool names) — harmless'
        # The caveman --all installer also drops these into the shared
        # ~/.agents/skills tree via `npx skills`. Gemini scans both that tree
        # and its own extensions, so leaving them duplicated renames every
        # command (/caveman -> /caveman1). The extension is the better copy:
        # agy imports from it and `gemini extensions update` maintains it.
        foreach ($s in @('caveman','cavecrew','caveman-commit','caveman-compress',
                         'caveman-help','caveman-review','caveman-stats')) {
          $dup = (Join-Path (Join-Path (Join-Path $HomeDir '.agents') 'skills') $s)
          if (Test-Path $dup) { Remove-Item $dup -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Ok 'removed duplicate caveman skills from ~/.agents/skills'
      } else { Warn 'gemini extension install failed' }
    }
  }
} else {
  Skip 'gemini CLI not found'
}

# --------------------------------------------------------------- antigravity
Say '== antigravity CLI =='
if (Test-Cmd agy) {
  Ok "agy $(& agy --version 2>$null | Select-Object -First 1) present"
} else {
  Skip 'antigravity CLI not found — install it from https://antigravity.google/docs/cli/install'
}

Info 'agy imports its plugins after the gemini extensions are in place (below)'

# --------------------------------------------------------------- default mode
Say "== caveman default mode: $Mode =="
# The hooks read CAVEMAN_DEFAULT_MODE. CAVEMAN_MODE is NOT read by anything.
if (-not $DryRun) {
  try {
    [Environment]::SetEnvironmentVariable('CAVEMAN_DEFAULT_MODE', $Mode, 'User')
    $env:CAVEMAN_DEFAULT_MODE = $Mode
    Ok 'CAVEMAN_DEFAULT_MODE set (user scope)'
  } catch {
    Warn "failed setting CAVEMAN_DEFAULT_MODE: $_"
  }
} else { Ok 'CAVEMAN_DEFAULT_MODE would be set (user scope)' }

# Hooks rewrite the flag only on a *new* session; set it now for live ones.
foreach ($flag in @((Join-Path $ClaudeDir '.caveman-active'), (Join-Path $OpencodeDir '.caveman-active'))) {
  $parent = Split-Path $flag -Parent
  if (-not (Test-Path $parent)) { Skip "$parent absent"; continue }
  if (-not $DryRun) {
    try { [IO.File]::WriteAllText($flag, $Mode) } catch { Warn "cannot write $flag"; continue }
  }
  Ok "flag $(Split-Path $parent -Leaf)\.caveman-active = $Mode"
}

# ----------------------------------------------------------------- statusline
Say '== statusline badge =='
# Only Claude Code exposes a user-configurable statusline. Gemini CLI,
# Antigravity and Codex have no such hook, and opencode's TUI does not let
# plugins write a badge — Claude Code is the only place a badge can exist.
if (Test-Path $ClaudeDir) {
  $sl = Get-ChildItem -Path (Join-Path (Join-Path (Join-Path $ClaudeDir 'plugins') 'cache') 'caveman') -Filter 'caveman-statusline.ps1' `
        -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $sl) {
    $sl = Get-ChildItem -Path (Join-Path (Join-Path (Join-Path $ClaudeDir 'plugins') 'cache') 'caveman') -Filter 'caveman-statusline.sh' `
          -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if ($sl) {
    $cmd = if ($sl.Extension -eq '.ps1') {
      "pwsh -NoProfile -File `"$($sl.FullName)`""
    } else {
      "bash `"$($sl.FullName)`""
    }
    $js = @'
const fs=require("fs");
const [file,cmd]=process.argv.slice(1);
let cfg={};
if(fs.existsSync(file)){
  const raw=fs.readFileSync(file,"utf8").trim();
  if(raw){ try{ cfg=JSON.parse(raw); }catch(e){
    console.error("settings.json is not valid JSON"); process.exit(2);
  }}
}
cfg.statusLine={type:"command",command:cmd};
fs.writeFileSync(file,JSON.stringify(cfg,null,2)+"\n");
'@
    if (Invoke-NodeJson -Script $js -NodeArgs @((Join-Path $ClaudeDir 'settings.json'), $cmd)) {
      Ok "claude code badge wired [CAVEMAN:$($Mode.ToUpper())]"
    } else {
      Warn 'failed writing statusLine into settings.json'
    }
  } else {
    Warn 'statusline script not found in plugin cache — badge not wired'
  }
} else {
  Skip 'claude code not installed'
}
Info 'no badge possible: opencode (TUI has no plugin-writable statusline),'
Info 'gemini / antigravity / codex (no statusline hook exists)'

# ------------------------------------------------------------- roblox skill
if (-not $NoRoblox) {
  Say '== roblox-game skill =='
  # Pure-markdown skill (no scripts). Claude Code and opencode read a plain
  # skills/<name>/ directory; gemini and agy need it wrapped as an extension
  # with a gemini-extension.json manifest and the skill under skills/.
  $rgsTmp = Join-Path $TempDir ("roblox-game-skill-" + [guid]::NewGuid().ToString('N').Substring(0,8))
  if ($DryRun) {
    Info "`$ git clone --depth 1 $RbxSkillRepo"
    Info '$ install into claude/opencode skills dirs + gemini/agy extensions'
  } elseif (-not (Test-Cmd git)) {
    Warn 'git not found — roblox-game skill skipped'
  } else {
    $src = Join-Path $rgsTmp 'src'
    & git clone --depth 1 $RbxSkillRepo $src *> $null
    if ($LASTEXITCODE -ne 0) {
      Warn "could not clone $RbxSkillRepo — roblox-game skill skipped"
    } else {
      # --- Claude Code + opencode: plain skills/<name>/ directory
      foreach ($base in @((Join-Path $ClaudeDir 'skills'), (Join-Path $OpencodeDir 'skills'))) {
        $parent = Split-Path $base -Parent
        if (-not (Test-Path $parent)) { Skip "$(Split-Path $parent -Leaf) not installed"; continue }
        $dest = Join-Path $base 'roblox-game'
        if ((Test-Path $dest) -and -not $Force) {
          Skip "$(Split-Path $parent -Leaf): roblox-game skill already installed"
          continue
        }
        try {
          New-Item -ItemType Directory -Force -Path $dest | Out-Null
          foreach ($item in @('SKILL.md','references','workflows','templates')) {
            Copy-Item (Join-Path $src $item) -Destination $dest -Recurse -Force
          }
          Ok "$(Split-Path $parent -Leaf): roblox-game skill installed"
        } catch {
          Warn "$(Split-Path $parent -Leaf): roblox-game copy failed"
        }
      }

      # --- gemini + agy: extension layout (manifest + skills/ subdir)
      if ((Test-Cmd gemini) -and $geminiHasExt) {
        $stage = Join-Path $rgsTmp 'ext'
        $stageSkill = Join-Path $stage (Join-Path 'skills' 'roblox-game')
        New-Item -ItemType Directory -Force -Path $stageSkill | Out-Null
        foreach ($item in @('SKILL.md','references','workflows','templates')) {
          Copy-Item (Join-Path $src $item) -Destination $stageSkill -Recurse -Force
        }
        Copy-Item (Join-Path $src 'SKILL.md') -Destination (Join-Path $stage 'GEMINI.md') -Force
        @'
{
  "name": "roblox-game",
  "description": "Expert Roblox game development companion — Luau, Roblox Studio, MCP integration, simulator, tycoon, obby, RPG, horror, battle royale, game design, security, performance.",
  "version": "1.0.0",
  "contextFileName": "GEMINI.md"
}
'@ | Set-Content (Join-Path $stage 'gemini-extension.json') -Encoding UTF8

        $extList2 = (& gemini extensions list 2>&1 | Out-String)
        if (($extList2 -match 'roblox-game') -and -not $Force) {
          Skip 'gemini: roblox-game already installed'
        } else {
          'y' | & gemini extensions uninstall roblox-game *> $null
          $rgsOut = ('y' | & gemini extensions install $stage 2>&1 | Out-String)
          if ($rgsOut -match 'installed successfully|already installed') {
            Ok 'gemini: roblox-game extension installed'
          } else { Warn 'gemini: roblox-game extension install failed' }
        }
      }

      # Single agy import, now that caveman AND roblox-game extensions both
      # exist. --force so a re-run refreshes the staged copies.
      if (Test-Cmd agy) {
        $agyOut = (& agy plugin import gemini --force 2>&1 | Out-String)
        $agyGot = @()
        if ($agyOut -match 'caveman')     { $agyGot += 'caveman' }
        if ($agyOut -match 'roblox-game') { $agyGot += 'roblox-game' }
        if ($agyGot.Count -gt 0) {
          Ok "antigravity imported: $($agyGot -join ' + ')"
        } else { Warn 'agy plugin import gemini imported nothing' }
        Info 'agy needs Google OAuth on first run: agy'
      }
    }
  }
  Remove-Item $rgsTmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------- roblox MCP
if (-not $NoRoblox) {
  Say "== robloxstudio-mcp $RbxVersion =="

  # Shared JSON merge for every mcpServers-style config.
  $mergeJs = @'
const fs=require("fs"), path=require("path");
const [file,key,schema,shape,pkg,ver]=process.argv.slice(1);
let cfg={};
if(fs.existsSync(file)){
  const raw=fs.readFileSync(file,"utf8").trim();
  if(raw){ try{ cfg=JSON.parse(raw); }catch(e){
    console.error("existing file is not valid JSON: "+file); process.exit(2);
  }}
}
fs.mkdirSync(path.dirname(file),{recursive:true});
if(schema && !cfg["$schema"]) cfg["$schema"]=schema;
cfg[key]=cfg[key]||{};
cfg[key].robloxstudio = shape==="opencode"
  ? {type:"local",command:["npx","-y",pkg+"@"+ver,"--auto-install-plugin"],enabled:true}
  : {command:"npx",args:["-y",pkg+"@"+ver,"--auto-install-plugin"]};
fs.writeFileSync(file,JSON.stringify(cfg,null,2)+"\n");
'@

  # --- Claude Code
  if (Test-Cmd claude) {
    $already = (& claude mcp list 2>$null | Out-String) -match 'robloxstudio'
    if ($already -and -not $Force) {
      Skip 'claude code: robloxstudio already registered'
    } elseif ($DryRun) {
      Info "`$ claude mcp add robloxstudio -- npx -y $RbxPkg@$RbxVersion --auto-install-plugin"
    } else {
      & claude mcp remove robloxstudio *> $null
      & claude mcp add robloxstudio -- npx -y "$RbxPkg@$RbxVersion" --auto-install-plugin
      if ($LASTEXITCODE -eq 0) { Ok 'claude code MCP registered' } else { Warn 'claude mcp add failed' }
    }
  } else { Skip 'claude code not found' }

  # --- opencode
  if (Test-Path $OpencodeDir) {
    if (Invoke-NodeJson -Script $mergeJs -NodeArgs @((Join-Path $OpencodeDir 'opencode.json'),'mcp','https://opencode.ai/config.json','opencode',$RbxPkg,$RbxVersion)) {
      Ok 'opencode MCP registered'
    } else { Warn 'opencode MCP merge failed' }
  } else { Skip 'opencode not found' }

  # --- Gemini CLI
  if (Test-Cmd gemini) {
    if (Invoke-NodeJson -Script $mergeJs -NodeArgs @((Join-Path $GeminiDir 'settings.json'),'mcpServers','','standard',$RbxPkg,$RbxVersion)) {
      Ok 'gemini CLI MCP registered'
    } else { Warn 'gemini settings.json merge failed' }
  } else { Skip 'gemini CLI not found' }

  # --- Antigravity (IDE + CLI share ~/.gemini/config/mcp_config.json)
  if ((Test-Path (Join-Path $HomeDir '.antigravity')) -or (Test-Cmd agy) -or (Test-Cmd antigravity)) {
    if (Invoke-NodeJson -Script $mergeJs -NodeArgs @($AntigravityMcp,'mcpServers','','standard',$RbxPkg,$RbxVersion)) {
      Ok "antigravity MCP registered ($AntigravityMcp)"
      Info 'restart Antigravity, then Manage MCP Servers to verify'
    } else { Warn 'antigravity mcp_config.json merge failed' }
  } else { Skip 'antigravity not found' }

  # --- Codex (TOML, not JSON)
  if ((Test-Cmd codex) -or (Test-Path $CodexDir)) {
    $codexToml = (Join-Path $CodexDir 'config.toml')
    $hasEntry = (Test-Path $codexToml) -and ((Get-Content $codexToml -Raw -ErrorAction SilentlyContinue) -match 'mcp_servers\.robloxstudio')
    if ($hasEntry -and -not $Force) {
      Skip 'codex: robloxstudio already in config.toml'
    } elseif ($DryRun) {
      Info "`$ append [mcp_servers.robloxstudio] to $codexToml"
    } else {
      try {
        New-Item -ItemType Directory -Force -Path $CodexDir | Out-Null
        $block = "`n[mcp_servers.robloxstudio]`ncommand = `"npx`"`nargs = [`"-y`", `"$RbxPkg@$RbxVersion`", `"--auto-install-plugin`"]`n"
        Add-Content -Path $codexToml -Value $block -Encoding UTF8
        Ok 'codex MCP appended to config.toml'
      } catch { Warn "cannot write $codexToml" }
    }
  } else { Skip 'codex not found' }

  # --- Studio plugin (.rbxmx) — the Studio half of the connection
  if ($DryRun) {
    Info "`$ npx -y $RbxPkg@$RbxVersion --install-plugin"
  } else {
    & npx -y "$RbxPkg@$RbxVersion" --install-plugin
    if ($LASTEXITCODE -eq 0) { Ok 'Roblox Studio plugin installed' }
    else { Warn "Studio plugin install failed — run manually: npx -y $RbxPkg@$RbxVersion --install-plugin" }
  }
} else { Skip 'roblox install skipped (-NoRoblox)' }

# -------------------------------------------------------------------- summary
Say '== summary =='
Write-Host ("  {0} done  {1} skipped  {2} warnings" -f `
  $script:Done.Count, $script:Skipped.Count, $script:Warnings.Count)

if ($script:Warnings.Count -gt 0) {
  Write-Host "`n  warnings:" -ForegroundColor Yellow
  foreach ($w in $script:Warnings) { Write-Host "    ! $w" }
}

@"

  next:
    restart your terminal    # load CAVEMAN_DEFAULT_MODE
    restart Claude Code      # badge appears
    restart Roblox Studio    # plugin reconnects
  uninstall caveman:
    npx -y github:JuliusBrussee/caveman -- --uninstall
"@

# Exit 0 even with warnings: partial success is not a crash.
exit 0
