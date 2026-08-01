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
  .\install.ps1
  .\install.ps1 -DryRun
  .\install.ps1 -NoRoblox -Mode full
  .\install.ps1 -Force
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
$RbxSkillSlug = 'brockmartin/roblox-game-skill'   # form the skills CLI expects

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
# Returns 'ok' | 'fail' | 'dry'. Callers must not print "registered" on 'dry' —
# nothing was written. Each caller prints its own dry-run line, since this
# helper also backs the statusline merge, not just MCP configs.
function Invoke-NodeJson {
  param([string]$Script, [string[]]$NodeArgs)
  if ($DryRun) { return 'dry' }
  & node -e $Script @NodeArgs
  if ($LASTEXITCODE -eq 0) { return 'ok' } else { return 'fail' }
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
# Cline CLI keeps MCP config under its data dir (shared with the VS Code ext).
$ClineMcp = Join-Path $HomeDir (Join-Path '.cline' (Join-Path 'data' (Join-Path 'settings' 'cline_mcp_settings.json')))

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

# The caveman skills must exist in the shared ~/.agents/skills tree: that is
# what Gemini reads (see the extension note below) and what codex/cursor/cline/
# copilot share. `caveman --all` only writes there if one of those agents is
# detected, and never with -g, so seed it explicitly when it is missing.
$SharedSkills = (Join-Path (Join-Path $HomeDir '.agents') 'skills')
if ((Test-Cmd gemini) -and -not (Test-Path (Join-Path $SharedSkills 'caveman'))) {
  if ($DryRun) {
    Info '$ npx skills add JuliusBrussee/caveman -a cline -g   # seeds ~/.agents/skills'
  } else {
    $cvSeed = (& npx -y skills add JuliusBrussee/caveman --skill '*' -a cline -g --yes 2>&1 | Out-String)
    if ($cvSeed -match 'caveman') {
      Ok 'caveman skills seeded into ~/.agents/skills'
    } else { Warn 'could not seed caveman skills into ~/.agents/skills' }
  }
}

# Gemini CLI < 0.2 has no `extensions` subcommand. It still exits 0 on
# `extensions --help` (prints global help), so probe the output text instead.
# Detection still matters: only newer versions can hold a stale extension.
if (Test-Cmd gemini) {
  $gver = (& gemini --version 2>$null | Select-Object -First 1)
  $extHelp = (& gemini extensions --help 2>&1 | Out-String)
  $geminiHasExt = $extHelp -match 'extensions'
  if ($geminiHasExt) {
    Ok "gemini $gver detected"
  } else {
    Info "gemini $gver predates extensions — nothing to clean up"
  }

  # Deliberately NOT installing the caveman gemini extension.
  #
  # Gemini scans its own extensions dir AND the shared ~/.agents/skills tree.
  # Codex, Cursor, Cline and Copilot can only install into that shared tree, so
  # an extension makes every skill collide — Gemini renames the commands
  # (/caveman -> /caveman1) and shadows one copy. Verified: with the extension
  # present alongside the shared copies, `gemini skills list` reports 7-8
  # conflicts; with the shared tree alone it reports 0 and still discovers
  # every skill. One copy serves Gemini and the other agents at once.
  if ($geminiHasExt) {
    $extList = (& gemini extensions list 2>&1 | Out-String)
    if ($extList -match 'caveman') {
      if ($DryRun) {
        Info '$ gemini extensions uninstall caveman   # conflicts with ~/.agents/skills'
      } else {
        'y' | & gemini extensions uninstall caveman *> $null
        Ok 'removed caveman gemini extension (conflicted with shared skills)'
      }
    }
  }

  # Gemini reads the shared skills, but nothing auto-activates caveman there —
  # extensions carried that. ~/.gemini/GEMINI.md loads every session on every
  # version, so the always-on rule goes there, importing the same shared copies
  # rather than duplicating their text.
  $gmd = (Join-Path $GeminiDir 'GEMINI.md')
  $gmdHasOther = (Test-Path $gmd) -and ((Get-Item $gmd).Length -gt 0) -and
                 -not ((Get-Content $gmd -Raw -ErrorAction SilentlyContinue) -match 'caveman')
  if ($DryRun) {
    Info "`$ write $gmd (caveman always-on, mode $Mode)"
  } elseif ($gmdHasOther -and -not $Force) {
    Skip 'GEMINI.md has unrelated content, left alone'
  } else {
    try {
      New-Item -ItemType Directory -Force -Path $GeminiDir | Out-Null
      $gmdBody = @"
@~/.agents/skills/caveman/SKILL.md
@~/.agents/skills/caveman-commit/SKILL.md
@~/.agents/skills/caveman-review/SKILL.md
@~/.agents/skills/caveman-compress/SKILL.md

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Default intensity: **$Mode**. Persist every response until user says "stop caveman" or "normal mode".

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
"@
      Set-Content -Path $gmd -Value $gmdBody -Encoding UTF8
      Ok "~/.gemini/GEMINI.md written (caveman always-on, $Mode)"
    } catch {
      Warn "could not write $gmd"
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

Info 'agy imports its plugins from the caveman plugin dir (below)'

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
    switch (Invoke-NodeJson -Script $js -NodeArgs @((Join-Path $ClaudeDir 'settings.json'), $cmd)) {
      'ok'   { Ok "claude code badge wired [CAVEMAN:$($Mode.ToUpper())]" }
      'dry'  { Info "`$ write statusLine into $(Join-Path $ClaudeDir 'settings.json')" }
      'fail' { Warn 'failed writing statusLine into settings.json' }
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
    Info '$ install into claude/opencode skills dirs + shared ~/.agents/skills'
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

      # --- gemini: no extension, same reason as caveman above. Gemini picks the
      # skill up from ~/.agents/skills, which the profile loop below fills.
      if ((Test-Cmd gemini) -and $geminiHasExt) {
        $extList2 = (& gemini extensions list 2>&1 | Out-String)
        if ($extList2 -match 'roblox-game') {
          if ($DryRun) {
            Info '$ gemini extensions uninstall roblox-game   # conflicts with ~/.agents/skills'
          } else {
            'y' | & gemini extensions uninstall roblox-game *> $null
            Ok 'removed roblox-game gemini extension (conflicted with shared skills)'
          }
        }
      }

      # agy used to import from the gemini extensions; those are gone now, so
      # import straight from the plugin directory. `agy plugin import` takes a
      # path as well as the `gemini`/`claude` keywords. --force refreshes a
      # previous import. roblox-game is a bare skill dir, not a plugin — agy
      # reads it from the shared tree the profile loop fills.
      if (Test-Cmd agy) {
        $cvPlug = Get-ChildItem -Directory -ErrorAction SilentlyContinue `
          (Join-Path $ClaudeDir (Join-Path 'plugins' (Join-Path 'cache' (Join-Path 'caveman' 'caveman')))) |
          Select-Object -First 1
        if ($cvPlug) {
          if ($DryRun) {
            Info "`$ agy plugin import $($cvPlug.FullName) --force"
          } else {
            $agyOut = (& agy plugin import $cvPlug.FullName --force 2>&1 | Out-String)
            if ($agyOut -match 'caveman') {
              Ok 'antigravity imported: caveman'
            } else { Warn 'agy plugin import found nothing to import' }
            Info 'agy needs Google OAuth on first run: agy'
          }
        }
      }

      # --- Codex and the other `npx skills` agents.
      # Same mechanism caveman uses for them: the upstream skills CLI writes
      # into each agent's own profile. -g installs user-wide, not into $PWD.
      #
      # codex, cursor, cline and copilot all resolve to the shared
      # ~/.agents/skills tree — one install covers all of them, and Gemini
      # reads that tree too. windsurf and trae keep their own directories.
      #
      # Gemini alone would leave the shared tree empty (it installs nothing
      # itself), so seed it via the cline profile when gemini is present but
      # none of the shared-tree agents are.
      $sharedSkillsDir = Join-Path (Join-Path $HomeDir '.agents') 'skills'
      if ((Test-Cmd gemini) -and -not (Test-Path (Join-Path $sharedSkillsDir 'roblox-game'))) {
        if ($DryRun) {
          Info "`$ npx skills add $RbxSkillSlug -a cline -g   # seeds ~/.agents/skills for gemini"
        } else {
          $seedOut = (& npx -y skills add $RbxSkillSlug --skill '*' -a cline -g --yes 2>&1 | Out-String)
          if ($seedOut -match 'roblox-game') {
            Ok 'gemini: roblox-game skill installed (~/.agents/skills)'
          } else { Warn 'gemini: could not seed roblox-game into ~/.agents/skills' }
        }
      }

      $npxProfiles = @(
        @{ id = 'codex';          test = { Test-Cmd codex } },
        @{ id = 'cursor';         test = { Test-Path (Join-Path $HomeDir '.cursor') } },
        @{ id = 'windsurf';       test = { Test-Path (Join-Path (Join-Path $HomeDir '.codeium') 'windsurf') } },
        @{ id = 'cline';          test = { (Test-Path (Join-Path $HomeDir '.clinerules')) -or (Test-Path (Join-Path $HomeDir '.cline')) } },
        @{ id = 'github-copilot'; test = { (Test-Path (Join-Path $HomeDir '.copilot')) -or (Test-Path (Join-Path (Join-Path $HomeDir '.config') 'github-copilot')) } },
        @{ id = 'trae';           test = { Test-Path (Join-Path $HomeDir '.trae') } }
      )
      foreach ($p in $npxProfiles) {
        if (-not (& $p.test)) { continue }
        if ($DryRun) { Info "`$ npx skills add $RbxSkillSlug -a $($p.id) -g"; continue }
        $skOut = (& npx -y skills add $RbxSkillSlug --skill '*' -a $p.id -g --yes 2>&1 | Out-String)
        if ($skOut -match 'roblox-game') {
          Ok "$($p.id): roblox-game skill installed"
        } else { Warn "$($p.id): roblox-game skill install failed" }
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
const args=["-y",pkg+"@"+ver,"--auto-install-plugin"];
cfg[key].robloxstudio =
  shape==="opencode" ? {type:"local",command:["npx",...args],enabled:true}
// Cline nests the transport instead of keeping command/args at top level.
: shape==="cline"    ? {transport:{type:"stdio",command:"npx",args}}
:                      {command:"npx",args};
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
    switch (Invoke-NodeJson -Script $mergeJs -NodeArgs @((Join-Path $OpencodeDir 'opencode.json'),'mcp','https://opencode.ai/config.json','opencode',$RbxPkg,$RbxVersion)) {
      'ok'   { Ok 'opencode MCP registered' }
      'dry'  { Info "`$ merge robloxstudio into $(Join-Path $OpencodeDir 'opencode.json')" }
      'fail' { Warn 'opencode MCP merge failed' }
    }
  } else { Skip 'opencode not found' }

  # --- Gemini CLI
  if (Test-Cmd gemini) {
    switch (Invoke-NodeJson -Script $mergeJs -NodeArgs @((Join-Path $GeminiDir 'settings.json'),'mcpServers','','standard',$RbxPkg,$RbxVersion)) {
      'ok'   { Ok 'gemini CLI MCP registered' }
      'dry'  { Info "`$ merge robloxstudio into $(Join-Path $GeminiDir 'settings.json')" }
      'fail' { Warn 'gemini settings.json merge failed' }
    }
  } else { Skip 'gemini CLI not found' }

  # --- Antigravity (IDE + CLI share ~/.gemini/config/mcp_config.json)
  if ((Test-Path (Join-Path $HomeDir '.antigravity')) -or (Test-Cmd agy) -or (Test-Cmd antigravity)) {
    switch (Invoke-NodeJson -Script $mergeJs -NodeArgs @($AntigravityMcp,'mcpServers','','standard',$RbxPkg,$RbxVersion)) {
      'ok'   { Ok "antigravity MCP registered ($AntigravityMcp)"
               Info 'restart Antigravity, then Manage MCP Servers to verify' }
      'dry'  { Info "`$ merge robloxstudio into $AntigravityMcp" }
      'fail' { Warn 'antigravity mcp_config.json merge failed' }
    }
  } else { Skip 'antigravity not found' }

  # --- Cline CLI
  # `cline mcp install --yes` writes the config itself, which beats guessing
  # the schema — the CLI nests the transport where every other agent keeps
  # command/args flat. Fall back to a direct merge if the CLI is absent (the
  # VS Code extension reads the same file).
  if (Test-Cmd cline) {
    $clineHas = (Test-Path $ClineMcp) -and
                ((Get-Content $ClineMcp -Raw -ErrorAction SilentlyContinue) -match '"robloxstudio"')
    if ($clineHas -and -not $Force) {
      Skip 'cline: robloxstudio already registered'
    } elseif ($DryRun) {
      Info "`$ cline mcp install robloxstudio --yes -- npx -y $RbxPkg@$RbxVersion"
    } else {
      $clineOut = (& cline mcp install robloxstudio --transport stdio --yes -- `
        npx -y "$RbxPkg@$RbxVersion" --auto-install-plugin 2>&1 | Out-String)
      if ($clineOut -match 'nstalled') {
        Ok 'cline MCP registered'
      } else { Warn 'cline mcp install failed' }
    }
  } elseif (Test-Path (Join-Path $HomeDir '.cline')) {
    switch (Invoke-NodeJson -Script $mergeJs -NodeArgs @($ClineMcp,'mcpServers','','cline',$RbxPkg,$RbxVersion)) {
      'ok'   { Ok 'cline MCP registered (config merge)' }
      'dry'  { Info "`$ merge robloxstudio into $ClineMcp" }
      'fail' { Warn 'cline mcp settings merge failed' }
    }
  } else { Skip 'cline not found' }

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
