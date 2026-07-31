#!/usr/bin/env bash
# setup-agents.sh — one-click install: caveman (ultra default) + robloxstudio-mcp
#
# Installs across every agent found on this machine. Never aborts on a failed
# step: each failure is collected and printed as a warning summary at the end.
#
# Usage:
#   bash install.sh              # install everything detected
#   bash install.sh --dry-run    # print what would happen, change nothing
#   bash install.sh --no-roblox  # skip the Roblox Studio MCP server
#   bash install.sh --mode full  # caveman default mode (default: ultra)
#   bash install.sh --force      # reinstall even if already present

set -uo pipefail   # deliberately no -e: a failed agent must not kill the run

RBX_PKG="@chrrxs/robloxstudio-mcp"
RBX_VERSION="2.23.0"
RBX_SKILL_REPO="https://github.com/brockmartin/roblox-game-skill"
CAVEMAN_MODE_DEFAULT="ultra"
DRY_RUN=0
DO_ROBLOX=1
FORCE=0

WARNINGS=()
SKIPPED=()
DONE=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --no-roblox) DO_ROBLOX=0 ;;
    --force)     FORCE=1 ;;
    --mode)      CAVEMAN_MODE_DEFAULT="${2:-ultra}"; shift ;;
    -h|--help)
      # Inline rather than sed-ing "$0": under `curl | bash` there is no script
      # file to read — $0 is just "bash".
      cat <<'USAGE'
install — caveman (ultra) + robloxstudio-mcp across every agent found.

Usage:
  bash install.sh              install everything detected
  bash install.sh --dry-run    print what would happen, change nothing
  bash install.sh --no-roblox  skip the Roblox Studio MCP server + skill
  bash install.sh --mode full  caveman default mode (default: ultra)
  bash install.sh --force      reinstall even if already present
USAGE
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

case "$CAVEMAN_MODE_DEFAULT" in
  lite|full|ultra|wenyan|wenyan-lite|wenyan-full|wenyan-ultra) ;;
  *) echo "invalid --mode: $CAVEMAN_MODE_DEFAULT" >&2; exit 1 ;;
esac

say()  { printf '\n\033[38;5;172m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$*"; DONE+=("$*"); }
skip() { printf '  \033[90m=\033[0m %s\n' "$*"; SKIPPED+=("$*"); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARNINGS+=("$*"); }

run() {
  if [ "$DRY_RUN" = 1 ]; then printf '  $ %s\n' "$*"; return 0; fi
  "$@"
}

# node -e helper: runs a JS snippet, returns non-zero on throw.
node_json() {
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  node -e "$@"
}

# Antigravity ships its binary inside the .app bundle; PATH may not have it.
for d in "$HOME/.antigravity/antigravity/bin" "$HOME/.npm-global/bin" \
         "$HOME/.opencode/bin" "$HOME/.local/bin" "/opt/homebrew/bin"; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

# ---------------------------------------------------------------- preflight
say "== preflight =="
if ! command -v node >/dev/null 2>&1; then
  echo "FATAL: node (>=18) required. https://nodejs.org" >&2; exit 1
fi
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "FATAL: node >=18 required (have $NODE_MAJOR)" >&2; exit 1
fi
ok "node $(node -v)"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
OPENCODE_DIR="$HOME/.config/opencode"
GEMINI_DIR="$HOME/.gemini"
# Antigravity IDE + CLI share this central MCP config.
ANTIGRAVITY_MCP="$HOME/.gemini/config/mcp_config.json"
CODEX_DIR="$HOME/.codex"

# ------------------------------------------------------------------ caveman
say "== caveman =="
CAVEMAN_PRESENT=0
[ -d "$CLAUDE_DIR/plugins/cache/caveman" ] && CAVEMAN_PRESENT=1

if [ "$CAVEMAN_PRESENT" = 1 ] && [ "$FORCE" = 0 ]; then
  skip "caveman already installed (--force to reinstall)"
else
  # Installer auto-detects every supported agent and runs its native path.
  if run npx -y github:JuliusBrussee/caveman --all; then
    ok "caveman installed"
  else
    warn "caveman installer failed (exit $?) — agents below may be unconfigured"
  fi
fi

# Gemini CLI < 0.2 has no `extensions` subcommand, so caveman's gemini step
# fails there. GEMINI.md is read by every version, so use it as a fallback.
if command -v gemini >/dev/null 2>&1; then
  GEMINI_VER=$(gemini --version 2>/dev/null | head -1)
  # Old gemini (<0.2) exits 0 on `extensions --help` but just prints the global
  # help, so the exit code proves nothing. Newer versions document the
  # subcommand in that output; old ones never mention it.
  GEM_EXT_HELP=$(gemini extensions --help 2>&1 || true)
  if printf "%s" "$GEM_EXT_HELP" | grep -qi 'extensions'; then
    GEMINI_HAS_EXT=1
  else
    GEMINI_HAS_EXT=0
  fi
  if [ "$GEMINI_HAS_EXT" = 1 ]; then
    ok "gemini $GEMINI_VER supports extensions"
  else
    warn "gemini $GEMINI_VER too old for 'extensions install' — falling back to GEMINI.md"
    info "upgrade it yourself for the native path: npm i -g @google/gemini-cli"
  fi
  if [ "$GEMINI_HAS_EXT" = 0 ]; then
    if [ -s "$GEMINI_DIR/GEMINI.md" ] && [ "$FORCE" = 0 ]; then
      skip "GEMINI.md already has content, left alone"
    else
      RULE_URL="https://raw.githubusercontent.com/JuliusBrussee/caveman/main/src/rules/caveman-activate.md"
      if [ "$DRY_RUN" = 1 ]; then
        info "\$ curl $RULE_URL -o $GEMINI_DIR/GEMINI.md"
      else
        mkdir -p "$GEMINI_DIR"
        if curl -fsSL "$RULE_URL" -o "$GEMINI_DIR/GEMINI.md.tmp" 2>/dev/null; then
          mv "$GEMINI_DIR/GEMINI.md.tmp" "$GEMINI_DIR/GEMINI.md"
          ok "fallback ~/.gemini/GEMINI.md written"
        else
          rm -f "$GEMINI_DIR/GEMINI.md.tmp"
          warn "could not fetch caveman rule for GEMINI.md fallback"
        fi
      fi
    fi
  fi
  # Native gemini install path (works once extensions exist).
  if [ "$GEMINI_HAS_EXT" = 1 ]; then
    GEM_LIST=$(gemini extensions list 2>/dev/null || true)
    if printf "%s" "$GEM_LIST" | grep -q caveman && [ "$FORCE" = 0 ]; then
      skip "gemini: caveman extension already installed"
    elif [ "$DRY_RUN" = 1 ]; then
      info "\$ gemini extensions install https://github.com/JuliusBrussee/caveman"
    else
      # Installer prompts for confirmation; feed it 'y'. "already installed" is
      # a success for our purposes: agy's `plugin import` can restore the
      # extension before this step runs, so the install legitimately no-ops.
      #
      # Capture first, grep after: `yes | cmd | grep -q` dies to SIGPIPE once
      # grep exits early, and pipefail then reports the whole pipeline as
      # failed even though the match succeeded.
      GEM_OUT=$(yes 2>/dev/null | gemini extensions install \
        https://github.com/JuliusBrussee/caveman 2>&1 || true)
      if printf '%s' "$GEM_OUT" | grep -qE 'installed successfully|already installed'; then
        ok "gemini caveman extension installed"
        info "cavecrew subagents fail to load on gemini (Claude tool names) — harmless"
        # The caveman --all installer also drops these into the shared
        # ~/.agents/skills tree via `npx skills`. Gemini scans both that tree
        # and its own extensions, so leaving them duplicated renames every
        # command (/caveman -> /caveman1). The extension is the better copy:
        # agy imports from it and `gemini extensions update` maintains it.
        for s in caveman cavecrew caveman-commit caveman-compress \
                 caveman-help caveman-review caveman-stats; do
          [ -d "$HOME/.agents/skills/$s" ] && rm -rf "$HOME/.agents/skills/$s"
        done
        ok "removed duplicate caveman skills from ~/.agents/skills"
      else
        warn "gemini extension install failed"
      fi
    fi
  fi
else
  skip "gemini CLI not found"
fi

# --------------------------------------------------------------- antigravity
say "== antigravity CLI =="
if command -v agy >/dev/null 2>&1; then
  ok "agy $(agy --version 2>/dev/null | head -1) present"
else
  skip "antigravity CLI not found — install it from https://antigravity.google/docs/cli/install"
fi

info "agy imports its plugins after the gemini extensions are in place (below)"

# --------------------------------------------------------------- default mode
say "== caveman default mode: $CAVEMAN_MODE_DEFAULT =="
# The hooks read CAVEMAN_DEFAULT_MODE via getDefaultMode().
# CAVEMAN_MODE (without _DEFAULT) is NOT read by anything.
add_env() {
  local rc="$1"
  [ -f "$rc" ] || { skip "$rc absent"; return 0; }
  if grep -q '^export CAVEMAN_DEFAULT_MODE=' "$rc" 2>/dev/null; then
    # Rewrite so re-runs with a different --mode actually take effect.
    if node_json '
      const fs=require("fs");
      const [rc,mode]=process.argv.slice(1);
      let s=fs.readFileSync(rc,"utf8");
      s=s.replace(/^export CAVEMAN_DEFAULT_MODE=.*$/m,"export CAVEMAN_DEFAULT_MODE="+mode);
      fs.writeFileSync(rc,s);
    ' "$rc" "$CAVEMAN_MODE_DEFAULT"; then
      ok "$(basename "$rc") updated to $CAVEMAN_MODE_DEFAULT"
    else
      warn "failed rewriting $rc"
    fi
  else
    if [ "$DRY_RUN" = 0 ]; then
      printf '\n# caveman — default compression mode\nexport CAVEMAN_DEFAULT_MODE=%s\n' \
        "$CAVEMAN_MODE_DEFAULT" >> "$rc" || warn "failed appending to $rc"
    fi
    ok "$(basename "$rc") appended"
  fi
}
add_env "$HOME/.zshrc"
add_env "$HOME/.bashrc"

# Hooks rewrite the flag only on a *new* session; set it now for live ones.
for FLAG in "$CLAUDE_DIR/.caveman-active" "$OPENCODE_DIR/.caveman-active"; do
  [ -d "$(dirname "$FLAG")" ] || { skip "$(dirname "$FLAG") absent"; continue; }
  if [ -L "$FLAG" ]; then warn "$FLAG is a symlink — refused"; continue; fi
  if [ "$DRY_RUN" = 0 ]; then
    printf '%s' "$CAVEMAN_MODE_DEFAULT" > "$FLAG" 2>/dev/null \
      || { warn "cannot write $FLAG"; continue; }
  fi
  ok "flag $(basename "$(dirname "$FLAG")")/.caveman-active = $CAVEMAN_MODE_DEFAULT"
done

# ----------------------------------------------------------------- statusline
say "== statusline badge =="
# Only Claude Code exposes a user-configurable statusline. Gemini CLI,
# Antigravity and Codex have no such hook, and opencode's TUI does not let
# plugins write a badge — so Claude Code is the only place a badge can exist.
if [ -d "$CLAUDE_DIR" ]; then
  STATUSLINE=$(find "$CLAUDE_DIR/plugins/cache/caveman" -name caveman-statusline.sh \
    -type f 2>/dev/null | head -1)
  if [ -n "$STATUSLINE" ]; then
    if node_json '
      const fs=require("fs");
      const [file,script]=process.argv.slice(1);
      let cfg={};
      try{ cfg=JSON.parse(fs.readFileSync(file,"utf8")); }catch(e){}
      cfg.statusLine={type:"command",command:`bash "${script}"`};
      fs.writeFileSync(file,JSON.stringify(cfg,null,2)+"\n");
    ' "$CLAUDE_DIR/settings.json" "$STATUSLINE"; then
      ok "claude code badge wired [CAVEMAN:$(printf '%s' "$CAVEMAN_MODE_DEFAULT" | tr '[:lower:]' '[:upper:]')]"
    else
      warn "failed writing statusLine into $CLAUDE_DIR/settings.json"
    fi
  else
    warn "statusline script not found in plugin cache — badge not wired"
  fi
else
  skip "claude code not installed"
fi
info "no badge possible: opencode (TUI has no plugin-writable statusline),"
info "gemini / antigravity / codex (no statusline hook exists)"

# ------------------------------------------------------------- roblox skill
if [ "$DO_ROBLOX" = 1 ]; then
  say "== roblox-game skill =="
  # Pure-markdown skill (no scripts). Claude Code and opencode read a plain
  # skills/<name>/ directory; gemini and agy need it wrapped as an extension
  # with a gemini-extension.json manifest and the skill under skills/.
  RGS_TMP="$(mktemp -d -t roblox-game-skill.XXXXXX)"
  if [ "$DRY_RUN" = 1 ]; then
    info "\$ git clone --depth 1 $RBX_SKILL_REPO"
    info "\$ install into claude/opencode skills dirs + gemini/agy extensions"
  elif git clone --depth 1 "$RBX_SKILL_REPO" "$RGS_TMP/src" >/dev/null 2>&1; then
    SRC="$RGS_TMP/src"

    # --- Claude Code + opencode: plain skills/<name>/ directory
    for base in "$CLAUDE_DIR/skills" "$OPENCODE_DIR/skills"; do
      parent=$(dirname "$base")
      [ -d "$parent" ] || { skip "$(basename "$parent") not installed"; continue; }
      dest="$base/roblox-game"
      if [ -d "$dest" ] && [ "$FORCE" = 0 ]; then
        skip "$(basename "$parent"): roblox-game skill already installed"
        continue
      fi
      mkdir -p "$dest" 2>/dev/null || { warn "cannot create $dest"; continue; }
      if cp -R "$SRC/SKILL.md" "$SRC/references" "$SRC/workflows" "$SRC/templates" \
           "$dest/" 2>/dev/null; then
        ok "$(basename "$parent"): roblox-game skill installed"
      else
        warn "$(basename "$parent"): roblox-game copy failed"
      fi
    done

    # --- gemini + agy: extension layout (manifest + skills/ subdir)
    if command -v gemini >/dev/null 2>&1 && [ "${GEMINI_HAS_EXT:-0}" = 1 ]; then
      STAGE="$RGS_TMP/ext"
      mkdir -p "$STAGE/skills/roblox-game"
      cp -R "$SRC/SKILL.md" "$SRC/references" "$SRC/workflows" "$SRC/templates" \
        "$STAGE/skills/roblox-game/" 2>/dev/null
      cp "$SRC/SKILL.md" "$STAGE/GEMINI.md" 2>/dev/null
      cat > "$STAGE/gemini-extension.json" <<'MANIFEST'
{
  "name": "roblox-game",
  "description": "Expert Roblox game development companion — Luau, Roblox Studio, MCP integration, simulator, tycoon, obby, RPG, horror, battle royale, game design, security, performance.",
  "version": "1.0.0",
  "contextFileName": "GEMINI.md"
}
MANIFEST
      GEM_LIST2=$(gemini extensions list 2>/dev/null || true)
      if printf "%s" "$GEM_LIST2" | grep -q roblox-game && [ "$FORCE" = 0 ]; then
        skip "gemini: roblox-game already installed"
      else
        yes 2>/dev/null | gemini extensions uninstall roblox-game >/dev/null 2>&1 || true
        # Same SIGPIPE/pipefail trap as above: capture, then match.
        RGS_OUT=$(yes 2>/dev/null | gemini extensions install "$STAGE" 2>&1 || true)
        if printf '%s' "$RGS_OUT" | grep -qE 'installed successfully|already installed'; then
          ok "gemini: roblox-game extension installed"
        else
          warn "gemini: roblox-game extension install failed"
        fi
      fi

    fi

    # Single agy import, now that caveman AND roblox-game extensions both
    # exist. --force so a re-run refreshes the staged copies.
    if command -v agy >/dev/null 2>&1; then
      AGY_OUT=$(agy plugin import gemini --force 2>&1)
      AGY_GOT=""
      echo "$AGY_OUT" | grep -q 'caveman'     && AGY_GOT="caveman"
      echo "$AGY_OUT" | grep -q 'roblox-game' && AGY_GOT="${AGY_GOT:+$AGY_GOT + }roblox-game"
      if [ -n "$AGY_GOT" ]; then
        ok "antigravity imported: $AGY_GOT"
      else
        warn "agy plugin import gemini imported nothing"
      fi
      info "agy needs Google OAuth on first run: agy"
    fi
  else
    warn "could not clone $RBX_SKILL_REPO — roblox-game skill skipped"
  fi
  rm -rf "$RGS_TMP"
fi

# --------------------------------------------------------------- roblox MCP
if [ "$DO_ROBLOX" = 1 ]; then
  say "== robloxstudio-mcp $RBX_VERSION =="

  # Shared helper: merge an mcpServers-style entry into a JSON config.
  # $1=file  $2=json-pointer-ish key ("mcpServers" or "mcp")  $3=schema url or ""
  merge_mcp_json() {
    local file="$1" key="$2" schema="$3" shape="$4"
    local dir; dir=$(dirname "$file")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || { warn "cannot create $dir"; return 1; }
    node_json '
      const fs=require("fs");
      const [file,key,schema,shape,pkg,ver]=process.argv.slice(1);
      let cfg={};
      if(fs.existsSync(file)){
        const raw=fs.readFileSync(file,"utf8").trim();
        if(raw){ try{ cfg=JSON.parse(raw); }catch(e){
          console.error("existing file is not valid JSON: "+file); process.exit(2);
        }}
      }
      if(schema && !cfg["$schema"]) cfg["$schema"]=schema;
      cfg[key]=cfg[key]||{};
      cfg[key].robloxstudio = shape==="opencode"
        ? {type:"local",command:["npx","-y",pkg+"@"+ver,"--auto-install-plugin"],enabled:true}
        : {command:"npx",args:["-y",pkg+"@"+ver,"--auto-install-plugin"]};
      fs.writeFileSync(file,JSON.stringify(cfg,null,2)+"\n");
    ' "$file" "$key" "$schema" "$shape" "$RBX_PKG" "$RBX_VERSION"
  }

  # --- Claude Code
  if command -v claude >/dev/null 2>&1; then
    MCP_LIST=$(claude mcp list 2>/dev/null || true)
    if printf "%s" "$MCP_LIST" | grep -q '^robloxstudio' && [ "$FORCE" = 0 ]; then
      skip "claude code: robloxstudio already registered"
    else
      run claude mcp remove robloxstudio >/dev/null 2>&1
      if run claude mcp add robloxstudio -- npx -y "$RBX_PKG@$RBX_VERSION" --auto-install-plugin; then
        ok "claude code MCP registered"
      else
        warn "claude mcp add failed"
      fi
    fi
  else
    skip "claude code not found"
  fi

  # --- opencode
  if [ -d "$OPENCODE_DIR" ]; then
    if merge_mcp_json "$OPENCODE_DIR/opencode.json" "mcp" "https://opencode.ai/config.json" "opencode"; then
      ok "opencode MCP registered"
    else
      warn "opencode MCP merge failed (see message above)"
    fi
  else
    skip "opencode not found"
  fi

  # --- Gemini CLI
  if command -v gemini >/dev/null 2>&1; then
    if merge_mcp_json "$GEMINI_DIR/settings.json" "mcpServers" "" "standard"; then
      ok "gemini CLI MCP registered"
    else
      warn "gemini settings.json merge failed"
    fi
  else
    skip "gemini CLI not found"
  fi

  # --- Antigravity (IDE + CLI share ~/.gemini/config/mcp_config.json)
  if [ -d "$HOME/.antigravity" ] || command -v agy >/dev/null 2>&1 \
     || command -v antigravity >/dev/null 2>&1; then
    if merge_mcp_json "$ANTIGRAVITY_MCP" "mcpServers" "" "standard"; then
      ok "antigravity MCP registered ($ANTIGRAVITY_MCP)"
      info "restart Antigravity, then Manage MCP Servers to verify"
    else
      warn "antigravity mcp_config.json merge failed"
    fi
  else
    skip "antigravity not found"
  fi

  # --- Codex (TOML, not JSON)
  if command -v codex >/dev/null 2>&1 || [ -d "$CODEX_DIR" ]; then
    CODEX_TOML="$CODEX_DIR/config.toml"
    if [ -f "$CODEX_TOML" ] && grep -q 'mcp_servers.robloxstudio' "$CODEX_TOML" 2>/dev/null && [ "$FORCE" = 0 ]; then
      skip "codex: robloxstudio already in config.toml"
    elif [ "$DRY_RUN" = 1 ]; then
      info "\$ append [mcp_servers.robloxstudio] to $CODEX_TOML"
    else
      mkdir -p "$CODEX_DIR" 2>/dev/null
      if cat >> "$CODEX_TOML" <<EOF

[mcp_servers.robloxstudio]
command = "npx"
args = ["-y", "$RBX_PKG@$RBX_VERSION", "--auto-install-plugin"]
EOF
      then ok "codex MCP appended to config.toml"
      else warn "cannot write $CODEX_TOML"
      fi
    fi
  else
    skip "codex not found"
  fi

  # --- Studio plugin (.rbxmx) — the Studio half of the connection
  if run npx -y "$RBX_PKG@$RBX_VERSION" --install-plugin; then
    ok "Roblox Studio plugin installed"
  else
    warn "Studio plugin install failed — run manually: npx -y $RBX_PKG@$RBX_VERSION --install-plugin"
  fi
else
  skip "roblox install skipped (--no-roblox)"
fi

# -------------------------------------------------------------------- summary
say "== summary =="
printf '  \033[32m%d done\033[0m  \033[90m%d skipped\033[0m  \033[33m%d warnings\033[0m\n' \
  "${#DONE[@]}" "${#SKIPPED[@]}" "${#WARNINGS[@]}"

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  printf '\n\033[33m  warnings:\033[0m\n'
  for w in "${WARNINGS[@]}"; do printf '    ! %s\n' "$w"; done
fi

cat <<EOF

  next:
    source ~/.zshrc          # load CAVEMAN_DEFAULT_MODE into this shell
    restart Claude Code      # badge appears
    restart Roblox Studio    # plugin reconnects
  uninstall caveman:
    npx -y github:JuliusBrussee/caveman -- --uninstall
EOF

# Exit 0 even with warnings: partial success is not a crash.
exit 0
