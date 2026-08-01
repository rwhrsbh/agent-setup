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
RBX_SKILL_SLUG="brockmartin/roblox-game-skill"   # form the skills CLI expects
# Design/taste skill packs. All are plain `npx skills` repos, so one command
# each covers every agent — see the install loop for why `-a '*'` is enough.
DESIGN_SKILL_REPOS="emilkowalski/skills Leonxlnx/taste-skill pbakaus/impeccable"
CAVEMAN_MODE_DEFAULT="ultra"
DRY_RUN=0
DO_ROBLOX=1
DO_DESIGN=1
FORCE=0

WARNINGS=()
SKIPPED=()
DONE=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --no-roblox) DO_ROBLOX=0 ;;
    --no-design) DO_DESIGN=0 ;;
    --force)     FORCE=1 ;;
    --mode)      CAVEMAN_MODE_DEFAULT="${2:-ultra}"; shift ;;
    -h|--help)
      # Inline rather than sed-ing "$0": under `curl | bash` there is no script
      # file to read — $0 is just "bash".
      cat <<'USAGE'
install — caveman (ultra) + robloxstudio-mcp + design skills, across every
agent found.

Usage:
  bash install.sh              install everything detected
  bash install.sh --dry-run    print what would happen, change nothing
  bash install.sh --no-roblox  skip the Roblox Studio MCP server + skill
  bash install.sh --no-design  skip the design/taste skill packs
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
# Cline CLI keeps MCP config under its data dir (shared with the VS Code ext).
CLINE_MCP="$HOME/.cline/data/settings/cline_mcp_settings.json"

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

# The caveman skills must exist in the shared ~/.agents/skills tree: that is
# what Gemini reads (see the extension note below) and what codex/cursor/cline/
# copilot share. `caveman --all` only writes there if one of those agents is
# detected, and never with -g, so seed it explicitly when it is missing.
if command -v gemini >/dev/null 2>&1 && [ ! -d "$HOME/.agents/skills/caveman" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    info "\$ npx skills add JuliusBrussee/caveman -a cline -g   # seeds ~/.agents/skills"
  else
    CVSEED=$(npx -y skills add JuliusBrussee/caveman --skill '*' -a cline -g --yes 2>&1 || true)
    if printf '%s' "$CVSEED" | grep -q 'caveman'; then
      ok "caveman skills seeded into ~/.agents/skills"
    else
      warn "could not seed caveman skills into ~/.agents/skills"
    fi
  fi
fi

# Gemini CLI < 0.2 has no `extensions` subcommand. Detection still matters:
# only newer versions can have a stale caveman extension to remove.
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
    ok "gemini $GEMINI_VER detected"
  else
    info "gemini $GEMINI_VER predates extensions — nothing to clean up"
  fi
  # Deliberately NOT installing the caveman gemini extension.
  #
  # Gemini scans its own extensions dir AND the shared ~/.agents/skills tree.
  # Codex, Cursor, Cline and Copilot can only install into that shared tree, so
  # an extension makes every skill collide — Gemini renames the commands
  # (/caveman -> /caveman1) and shadows one copy. Verified: with the extension
  # present alongside the shared copies, `gemini skills list` reports 7-8
  # conflicts; with the shared tree alone it reports 0 and still discovers
  # every skill. One copy in ~/.agents/skills serves Gemini and the other
  # agents at once, so that is where caveman lives.
  if [ "$GEMINI_HAS_EXT" = 1 ]; then
    GEM_LIST=$(gemini extensions list 2>/dev/null || true)
    if printf "%s" "$GEM_LIST" | grep -q caveman; then
      if [ "$DRY_RUN" = 1 ]; then
        info "\$ gemini extensions uninstall caveman   # conflicts with ~/.agents/skills"
      else
        yes 2>/dev/null | gemini extensions uninstall caveman >/dev/null 2>&1 || true
        ok "removed caveman gemini extension (conflicted with shared skills)"
      fi
    fi
  fi

  # Gemini reads the shared skills, but nothing auto-activates caveman there —
  # extensions carried that. ~/.gemini/GEMINI.md is loaded every session on
  # every version, so the always-on rule goes there, importing the same shared
  # copies rather than duplicating their text.
  if [ "$DRY_RUN" = 1 ]; then
    info "\$ write $GEMINI_DIR/GEMINI.md (caveman always-on, mode $CAVEMAN_MODE_DEFAULT)"
  elif [ -s "$GEMINI_DIR/GEMINI.md" ] && ! grep -q 'caveman' "$GEMINI_DIR/GEMINI.md" 2>/dev/null && [ "$FORCE" = 0 ]; then
    skip "GEMINI.md has unrelated content, left alone"
  else
    mkdir -p "$GEMINI_DIR"
    if cat > "$GEMINI_DIR/GEMINI.md" <<GEMMD
@~/.agents/skills/caveman/SKILL.md
@~/.agents/skills/caveman-commit/SKILL.md
@~/.agents/skills/caveman-review/SKILL.md
@~/.agents/skills/caveman-compress/SKILL.md

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Default intensity: **$CAVEMAN_MODE_DEFAULT**. Persist every response until user says "stop caveman" or "normal mode".

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
GEMMD
    then
      ok "~/.gemini/GEMINI.md written (caveman always-on, $CAVEMAN_MODE_DEFAULT)"
    else
      warn "could not write $GEMINI_DIR/GEMINI.md"
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

info "agy imports its plugins from the caveman plugin dir (below)"

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
    info "\$ install into claude/opencode skills dirs + shared ~/.agents/skills"
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

    # --- gemini: no extension, same reason as caveman above. Gemini picks the
    # skill up from ~/.agents/skills, which the profile loop below fills.
    if command -v gemini >/dev/null 2>&1 && [ "${GEMINI_HAS_EXT:-0}" = 1 ]; then
      GEM_LIST2=$(gemini extensions list 2>/dev/null || true)
      if printf "%s" "$GEM_LIST2" | grep -q roblox-game; then
        if [ "$DRY_RUN" = 1 ]; then
          info "\$ gemini extensions uninstall roblox-game   # conflicts with ~/.agents/skills"
        else
          yes 2>/dev/null | gemini extensions uninstall roblox-game >/dev/null 2>&1 || true
          ok "removed roblox-game gemini extension (conflicted with shared skills)"
        fi
      fi
    fi

    # agy used to import from the gemini extensions; those are gone now, so
    # import straight from the plugin directories. `agy plugin import` takes a
    # path as well as the `gemini`/`claude` keywords. --force refreshes a
    # previous import.
    if command -v agy >/dev/null 2>&1; then
      AGY_GOT=""
      CVPLUG=$(ls -d "$CLAUDE_DIR"/plugins/cache/caveman/caveman/*/ 2>/dev/null | head -1)
      if [ -n "$CVPLUG" ]; then
        if [ "$DRY_RUN" = 1 ]; then
          info "\$ agy plugin import $CVPLUG --force"
        else
          AGY_OUT=$(agy plugin import "$CVPLUG" --force 2>&1 || true)
          printf '%s' "$AGY_OUT" | grep -q 'caveman' && AGY_GOT="caveman"
        fi
      fi
      # roblox-game is a bare skill dir, not a plugin — agy reads skills from
      # the shared tree the profile loop above fills.
      if [ "$DRY_RUN" = 0 ]; then
        if [ -n "$AGY_GOT" ]; then
          ok "antigravity imported: $AGY_GOT"
        else
          warn "agy plugin import found nothing to import"
        fi
        info "agy needs Google OAuth on first run: agy"
      fi
    fi

    # --- Codex and the other `npx skills` agents.
    # Same mechanism caveman uses for them: the upstream skills CLI writes into
    # each agent's own profile. -g installs user-wide instead of into $PWD.
    #
    # codex, cursor, cline and copilot all resolve to the shared
    # ~/.agents/skills tree — one install covers all of them, and Gemini reads
    # that tree too. windsurf and trae keep their own directories.
    #
    # Gemini alone would leave the shared tree empty (it installs nothing
    # itself), so seed it via the cline profile when gemini is present but none
    # of the shared-tree agents are.
    if command -v gemini >/dev/null 2>&1 && [ ! -d "$HOME/.agents/skills/roblox-game" ]; then
      if [ "$DRY_RUN" = 1 ]; then
        info "\$ npx skills add $RBX_SKILL_SLUG -a cline -g   # seeds ~/.agents/skills for gemini"
      else
        SEED_OUT=$(npx -y skills add "$RBX_SKILL_SLUG" --skill '*' -a cline -g --yes 2>&1 || true)
        if printf '%s' "$SEED_OUT" | grep -q 'roblox-game'; then
          ok "gemini: roblox-game skill installed (~/.agents/skills)"
        else
          warn "gemini: could not seed roblox-game into ~/.agents/skills"
        fi
      fi
    fi

    for prof in codex cursor windsurf cline github-copilot trae; do
      case "$prof" in
        codex)          command -v codex >/dev/null 2>&1 || continue ;;
        cursor)         [ -d "$HOME/.cursor" ] || continue ;;
        windsurf)       [ -d "$HOME/.codeium/windsurf" ] || continue ;;
        cline)          { [ -d "$HOME/.clinerules" ] || [ -d "$HOME/.cline" ]; } || continue ;;
        github-copilot) { [ -d "$HOME/.config/github-copilot" ] || [ -d "$HOME/.copilot" ]; } || continue ;;
        trae)           [ -d "$HOME/.trae" ] || continue ;;
      esac

      if [ "$DRY_RUN" = 1 ]; then
        info "\$ npx skills add $RBX_SKILL_SLUG -a $prof -g"
        continue
      fi
      SK_OUT=$(npx -y skills add "$RBX_SKILL_SLUG" --skill '*' -a "$prof" -g --yes 2>&1 || true)
      if printf '%s' "$SK_OUT" | grep -q 'roblox-game'; then
        ok "$prof: roblox-game skill installed"
      else
        warn "$prof: roblox-game skill install failed"
      fi
    done
  else
    warn "could not clone $RBX_SKILL_REPO — roblox-game skill skipped"
  fi
  rm -rf "$RGS_TMP"
fi

# -------------------------------------------------------------- design skills
if [ "$DO_DESIGN" = 1 ]; then
  say "== design skills =="
  # These are ordinary `npx skills` repos, so `-a '*'` installs to every agent
  # the skills CLI knows about (~59) in one shot — no per-profile loop needed
  # like roblox-game requires. Everything still lands in ~/.agents/skills, the
  # single shared tree, so Gemini sees one copy and reports no conflict.
  #
  # Two agents (Eve, PromptScript) reject global installs by design; their
  # failure lines are expected and must not become warnings.
  for repo in $DESIGN_SKILL_REPOS; do
    if [ "$DRY_RUN" = 1 ]; then
      info "\$ npx skills add $repo -a '*' -g"
      continue
    fi
    DS_OUT=$(npx -y skills add "$repo" -a '*' -g --yes 2>&1 || true)
    # "Installed N skills" is the success banner; count it rather than matching
    # a skill name, since each repo ships a different set.
    DS_N=$(printf '%s' "$DS_OUT" | grep -oE 'Installed [0-9]+ skill' | grep -oE '[0-9]+' | head -1)
    if [ -n "$DS_N" ]; then
      ok "$repo: $DS_N skills installed"
    elif printf '%s' "$DS_OUT" | grep -q 'already installed'; then
      skip "$repo: already installed"
    else
      warn "$repo: skill install failed"
    fi
  done
else
  skip "design skills skipped (--no-design)"
fi

# --------------------------------------------------------------- roblox MCP
if [ "$DO_ROBLOX" = 1 ]; then
  say "== robloxstudio-mcp $RBX_VERSION =="

  # Shared helper: merge an mcpServers-style entry into a JSON config.
  # $1=file  $2=json-pointer-ish key ("mcpServers" or "mcp")  $3=schema url or ""
  merge_mcp_json() {
    local file="$1" key="$2" schema="$3" shape="$4"
    local dir; dir=$(dirname "$file")
    # node_json is a no-op under --dry-run, so say what would happen and stop
    # before mkdir — a dry run must not create directories either.
    if [ "$DRY_RUN" = 1 ]; then
      info "\$ merge robloxstudio into $file"
      return 2
    fi
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
      const args=["-y",pkg+"@"+ver,"--auto-install-plugin"];
      cfg[key].robloxstudio =
        shape==="opencode" ? {type:"local",command:["npx",...args],enabled:true}
      // Cline nests the transport instead of keeping command/args at top level.
      : shape==="cline"    ? {transport:{type:"stdio",command:"npx",args}}
      :                      {command:"npx",args};
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
    # rc 2 = dry run reported the plan and wrote nothing; not a failure.
    merge_mcp_json "$OPENCODE_DIR/opencode.json" "mcp" "https://opencode.ai/config.json" "opencode"
    case $? in
      0) ok "opencode MCP registered" ;;
      2) : ;;
      *) warn "opencode MCP merge failed (see message above)" ;;
    esac
  else
    skip "opencode not found"
  fi

  # --- Gemini CLI
  if command -v gemini >/dev/null 2>&1; then
    merge_mcp_json "$GEMINI_DIR/settings.json" "mcpServers" "" "standard"
    case $? in
      0) ok "gemini CLI MCP registered" ;;
      2) : ;;
      *) warn "gemini settings.json merge failed" ;;
    esac
  else
    skip "gemini CLI not found"
  fi

  # --- Antigravity (IDE + CLI share ~/.gemini/config/mcp_config.json)
  if [ -d "$HOME/.antigravity" ] || command -v agy >/dev/null 2>&1 \
     || command -v antigravity >/dev/null 2>&1; then
    merge_mcp_json "$ANTIGRAVITY_MCP" "mcpServers" "" "standard"
    case $? in
      0) ok "antigravity MCP registered ($ANTIGRAVITY_MCP)"
         info "restart Antigravity, then Manage MCP Servers to verify" ;;
      2) : ;;
      *) warn "antigravity mcp_config.json merge failed" ;;
    esac
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

  # --- Cline CLI
  # `cline mcp install --yes` writes the config itself, which beats guessing
  # the schema — the CLI nests the transport where every other agent keeps
  # command/args flat. Fall back to a direct merge if the CLI is absent (the
  # VS Code extension reads the same file).
  if command -v cline >/dev/null 2>&1; then
    if [ -f "$CLINE_MCP" ] && grep -q '"robloxstudio"' "$CLINE_MCP" 2>/dev/null && [ "$FORCE" = 0 ]; then
      skip "cline: robloxstudio already registered"
    elif [ "$DRY_RUN" = 1 ]; then
      info "\$ cline mcp install robloxstudio --yes -- npx -y $RBX_PKG@$RBX_VERSION"
    else
      CLINE_OUT=$(cline mcp install robloxstudio --transport stdio --yes -- \
        npx -y "$RBX_PKG@$RBX_VERSION" --auto-install-plugin 2>&1 || true)
      if printf '%s' "$CLINE_OUT" | grep -qi 'installed'; then
        ok "cline MCP registered"
      else
        warn "cline mcp install failed"
      fi
    fi
  elif [ -d "$HOME/.cline" ]; then
    merge_mcp_json "$CLINE_MCP" "mcpServers" "" "cline"
    case $? in
      0) ok "cline MCP registered (config merge)" ;;
      2) : ;;
      *) warn "cline mcp settings merge failed" ;;
    esac
  else
    skip "cline not found"
  fi

  # --- Studio plugin (.rbxmx) — the Studio half of the connection
  if [ "$DRY_RUN" = 1 ]; then
    info "\$ npx -y $RBX_PKG@$RBX_VERSION --install-plugin"
  elif run npx -y "$RBX_PKG@$RBX_VERSION" --install-plugin; then
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
