#!/usr/bin/env zsh
# ============================================================
#  dev-start.sh — tmux + git worktree manager for Kibana
#
#  USAGE:
#    Sessions:
#      (no args)                              start/attach all sessions (+ recover orphaned worktrees)
#      switch <branch> [--remote]             switch kibana-feat to a branch
#      new <branch> [--full] [--remote]       create worktree + hotfix session
#      attach <branch>                        attach to an existing session
#      kill <branch>                          kill session + remove worktree
#      kill-all                               kill ALL kibana-* sessions
#      recover                                recreate sessions for orphaned worktrees
#      prune                                  remove orphaned worktrees (no active session)
#    Operations:
#      restart <main|feat|branch> [--no-watch]  restart ES + Kibana (--no-watch skips file watcher; use for QA/screenshot restarts when FSEvents fails)
#      renew [--cluster-name <n>] [--session <t>] [--save]  refresh remote ES credentials
#      sync [main|feat|branch|all] [--remote|--local]  regenerate kibana.dev.yml from template (creates it for a branch worktree that has none)
#      clean [main|feat|name|all]             list or delete ES data folders
#    Info:
#      list                                   sessions, worktrees & port assignments
#      status                                 health check — ping ES + Kibana
#      setup                                  interactive config wizard
#      help                                   show help
#
#  FILES:
#    ~/bin/kbn-start.sh        helper script (must be installed first)
#    ~/.kibana-dev-state       auto-managed state file (feat branch + dir)
#
#  GENERATED PER WORKTREE:
#    config/kibana.dev.yml     Kibana port config
#    .cursor/mcp.json          Playwright-mcp config with correct Kibana URL
#
#  WINDOWS PER SESSION (full):
#    0: servers   [left: ES+bootstrap  |  right: Kibana (auto-started)]
#    1: cursor    [left: cursor-agent  |  right: spare shell]
#    2: scripts   [left: synthetics    |  right: inject data]
#    3: git       [single pane]
#    4: editor    [single pane — vim, /etc/hosts, config files]
#    5: checks    [top-left: eslint | top-right: type check | bottom: jest]
#    6: ftr       [left: ftr server    |  right: ftr runner]
#
#  WINDOWS PER SESSION (lightweight):
#    0: servers   [left: ES+bootstrap  |  right: Kibana (auto-started)]
#    1: cursor    [left: cursor-agent  |  right: spare shell]
#    2: scripts   [left: synthetics    |  right: inject data]
#    3: git       [single pane]
#    4: editor    [single pane]
# ============================================================

# ── CONFIG ────────────────────────────────────────────────
# User overrides — sourced first so they take precedence
KIBANA_DEV_CONF="$HOME/.kibana-dev.conf"
[[ -f "$KIBANA_DEV_CONF" ]] && source "$KIBANA_DEV_CONF"

# Paths (defaults apply only if not set by user config)
KIBANA_MAIN_DIR="${KIBANA_MAIN_DIR:-$HOME/Documents/Development/kibana}"
WORKTREE_BASE="${WORKTREE_BASE:-$HOME/Documents/Development/worktrees}"
ES_DATA_BASE="${ES_DATA_BASE:-$HOME/Documents/Development/es_data}"
STATE_FILE="${STATE_FILE:-$HOME/.kibana-dev-state}"
KBN_START="${KBN_START:-$HOME/bin/kbn-start.sh}"
REMOTE_ES_CONFIG="${REMOTE_ES_CONFIG:-$HOME/.kibana-remote-es.yml}"
OBLT_CLUSTER_NAME="${OBLT_CLUSTER_NAME:-}"
# Use `edge-oblt` (not `edge-lite-oblt`) as the CCS remote: edge-oblt ships with
# preconfigured monitors, so the "Remote cluster" grouping / CCS flows have data
# out of the box. Override via OBLT_CLUSTER_CREATE_CMD if you need a lite cluster.
OBLT_CLUSTER_CREATE_CMD="${OBLT_CLUSTER_CREATE_CMD:-oblt-cli cluster create ccs --remote-cluster=edge-oblt}"

# Script-relative paths (always derived from install location, not configurable)
TEMPLATE="${0:A:h}/kibana.dev.yml.template"
REMOTE_ES_EXAMPLE="${0:A:h}/kibana-remote-es.yml.example"
CONF_EXAMPLE="${0:A:h}/kibana-dev.conf.example"
RUN_CHECKS="${0:A:h}/run-checks.sh"
RUN_DATA="${0:A:h}/run-data.sh"

# kibana-main — permanent, never changes
MAIN_KIBANA_PORT="${MAIN_KIBANA_PORT:-5602}"
MAIN_ES_PORT="${MAIN_ES_PORT:-9201}"
MAIN_HOST="${MAIN_HOST:-kibana-main.local}"
MAIN_DATA_FOLDER="${MAIN_DATA_FOLDER:-main-cluster}"

# kibana-feat — permanent slot, branch changes via `switch`
FEAT_KIBANA_PORT="${FEAT_KIBANA_PORT:-5601}"
FEAT_ES_PORT="${FEAT_ES_PORT:-9200}"
FEAT_HOST="${FEAT_HOST:-kibana-feat.local}"

# Hotfix sessions scan upward from these ports
HOTFIX_KIBANA_PORT_START="${HOTFIX_KIBANA_PORT_START:-5603}"
HOTFIX_ES_PORT_START="${HOTFIX_ES_PORT_START:-9202}"

# ── END CONFIG ────────────────────────────────────────────


# ── COLORS ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'
# ── END COLORS ────────────────────────────────────────────


# ── STATE FILE ────────────────────────────────────────────
load_feat_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "${RED}Error:${NC} No feat state found. Run this first:"
    echo ""
    echo "  ${GREEN}./dev-start.sh switch <your-feature-branch>${NC}"
    echo ""
    echo "  Example: ./dev-start.sh switch feature/slo-filters"
    exit 1
  fi
  source "$STATE_FILE"
}

save_feat_state() {
  local branch="$1" dir="$2"
  cat > "$STATE_FILE" <<EOF
# Auto-managed by dev-start.sh — do not edit manually
FEAT_BRANCH=$branch
FEAT_DIR=$dir
EOF
  echo "${GREEN}✓${NC} State saved → $STATE_FILE"
}
# ── END STATE FILE ────────────────────────────────────────


# ── PORT HELPERS ──────────────────────────────────────────
port_in_use() {
  lsof -i ":$1" &>/dev/null
}

# Collect all Kibana and ES ports already assigned in worktree kibana.dev.yml files,
# so find_free_ports won't hand out a port that's claimed but not currently running.
collect_assigned_ports() {
  local reserved=()
  # Main and feat reserved ports
  reserved+=("$MAIN_KIBANA_PORT" "$MAIN_ES_PORT" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT")
  # Scan all worktree configs
  local yml
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    local k_port es_port
    k_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
    es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    [[ -n "$k_port" ]] && reserved+=("$k_port")
    [[ -n "$es_port" ]] && reserved+=("$es_port")
  done
  # Also check the main repo config
  if [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]]; then
    local mk mp
    mk=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    mp=$(grep -E "^ *- \"?http://localhost:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    [[ -n "$mk" ]] && reserved+=("$mk")
    [[ -n "$mp" ]] && reserved+=("$mp")
  fi
  # Also check the feat dir config (if it's outside WORKTREE_BASE)
  if [[ -n "${FEAT_DIR:-}" && -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
    local fk fp
    fk=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    fp=$(grep -E "^ *- \"?http://localhost:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    [[ -n "$fk" ]] && reserved+=("$fk")
    [[ -n "$fp" ]] && reserved+=("$fp")
  fi
  echo "${reserved[@]}"
}

find_free_ports() {
  local kibana_port=$HOTFIX_KIBANA_PORT_START
  local es_port=$HOTFIX_ES_PORT_START

  # Build set of all reserved/assigned ports (config-level + well-known)
  local reserved_str
  reserved_str=$(collect_assigned_ports)
  local -a reserved_ports=(${=reserved_str})

  _port_is_reserved() {
    local p="$1" r
    for r in "${reserved_ports[@]}"; do
      [[ "$p" == "$r" ]] && return 0
    done
    return 1
  }

  while true; do
    if _port_is_reserved "$kibana_port" || _port_is_reserved "$es_port"; then
      (( kibana_port++ )); (( es_port++ ))
      continue
    fi
    # Also check lsof for conflicts from outside dev-start (other apps)
    if ! port_in_use "$kibana_port" && ! port_in_use "$es_port"; then
      echo "$kibana_port $es_port"
      return
    fi
    (( kibana_port++ )); (( es_port++ ))
  done
}

generate_kibana_dev_yml() {
  local dir="$1" kibana_port="$2" es_port="$3"

  if [[ ! -f "$TEMPLATE" ]]; then
    echo "${RED}Error:${NC} Template not found at $TEMPLATE"
    exit 1
  fi

  mkdir -p "$dir/config"
  sed \
    -e "s/__KIBANA_PORT__/$kibana_port/g" \
    -e "s/__ES_PORT__/$es_port/g" \
    -e "s|__FLEET_ES_HOST__|http://host.docker.internal:$es_port|g" \
    -e "s/__FLEET_SERVER_PORT__/$(( 8220 + kibana_port - 5601 ))/g" \
    "$TEMPLATE" > "$dir/config/kibana.dev.yml"

  echo "${GREEN}✓${NC} config/kibana.dev.yml  → Kibana :$kibana_port  ES :$es_port"
}

generate_remote_kibana_dev_yml() {
  local dir="$1" kibana_port="$2"

  if [[ ! -f "$REMOTE_ES_CONFIG" ]]; then
    echo "${RED}Error:${NC} Remote ES config not found at $REMOTE_ES_CONFIG"
    echo ""
    echo "  Copy the example and fill in your cluster details:"
    echo "    ${GREEN}cp $REMOTE_ES_EXAMPLE $REMOTE_ES_CONFIG${NC}"
    echo "    ${GREEN}vim $REMOTE_ES_CONFIG${NC}"
    echo ""
    echo "  Get credentials from oblt-cli:"
    echo "    ${GREEN}oblt-cli cluster credentials${NC}"
    exit 1
  fi

  mkdir -p "$dir/config"

  local remote_host
  remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')

  {
    echo "server:"
    echo "  port: ${kibana_port}"
    echo "  restrictInternalApis: false"
    echo ""
    echo "# Remote ES — generated by dev-start.sh --remote"
    echo "# Source: $REMOTE_ES_CONFIG"
    echo ""
    # Strip any server: block from the remote config (dev-start.sh manages the port)
    awk '
      /^[[:space:]]*server:[[:space:]]*$/ { skipping=1; match($0,/^[[:space:]]*/); lvl=RLENGTH; next }
      skipping && /^[[:space:]]*$/ { next }
      skipping { match($0,/^[[:space:]]*/); if(RLENGTH>lvl){next} else {skipping=0} }
      {print}
    ' "$REMOTE_ES_CONFIG"
    # Ensure ignoreVersionMismatch is present (oblt-cli output may not include it)
    if ! grep -q "ignoreVersionMismatch" "$REMOTE_ES_CONFIG" 2>/dev/null; then
      echo "elasticsearch.ignoreVersionMismatch: true"
    fi
    if ! grep -q "versionResolution" "$REMOTE_ES_CONFIG" 2>/dev/null; then
      echo "server.versioned.versionResolution: oldest"
    fi
    if ! grep -q "oas.enabled" "$REMOTE_ES_CONFIG" 2>/dev/null; then
      echo "server.oas.enabled: true"
    fi
    echo ""
    # Append Fleet config from template (everything after the ES connection block)
    # Substitute placeholders with remote values
    sed -n '/^# Create an agent policy/,$ p' "$TEMPLATE" \
      | sed -e "s|__FLEET_ES_HOST__|${remote_host}|g" \
            -e "s/__FLEET_SERVER_PORT__/$(( 8220 + kibana_port - 5601 ))/g"
  } > "$dir/config/kibana.dev.yml"

  echo "${GREEN}✓${NC} config/kibana.dev.yml  → Kibana :$kibana_port  ES: ${BLUE}${remote_host:-remote}${NC}"
}

generate_cursor_mcp_json() {
  local dir="$1" kibana_port="$2" host="$3"
  local kibana_url
  if [[ "$host" == "localhost" ]]; then
    kibana_url="http://localhost:${kibana_port}"
  else
    kibana_url="http://${host}:${kibana_port}"
  fi
  mkdir -p "$dir/.cursor"
  cat > "$dir/.cursor/mcp.json" <<EOF
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"],
      "env": {
        "KIBANA_URL": "$kibana_url"
      }
    }
  }
}
EOF
  echo "${GREEN}✓${NC} .cursor/mcp.json       → KIBANA_URL=$kibana_url"
}
get_es_display() {
  local yml="$1"
  [[ ! -f "$yml" ]] && echo ":unknown" && return
  local local_port
  local_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
  if [[ -n "$local_port" ]]; then
    echo ":$local_port"
    return
  fi
  local remote_url
  remote_url=$(grep -E "^ *hosts: https?://" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
  if [[ -n "$remote_url" ]]; then
    echo "$remote_url"
    return
  fi
  echo ":unknown"
}
# ── VERSION HELPERS ───────────────────────────────────────

# Get the ES version from a remote cluster (authenticated request)
# Usage: get_remote_es_version <es_host_url> <remote_es_config_file>
# Prints the major.minor.patch version string, or empty on failure
get_remote_es_version() {
  local es_host_url="$1" config_file="$2"
  [[ -z "$es_host_url" || ! -f "$config_file" ]] && return

  local es_user es_pass
  es_user=$(grep -E "^ *username:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
  es_pass=$(grep -E "^ *password:" "$config_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
  [[ -z "$es_user" || -z "$es_pass" ]] && return

  local response
  response=$(curl -s -u "${es_user}:${es_pass}" "$es_host_url" --max-time 10 2>/dev/null)
  [[ -z "$response" ]] && return

  echo "$response" | sed -n 's/.*"number" *: *"\([^"]*\)".*/\1/p' | head -1
}

# Get the local Kibana version from package.json
# Usage: get_kibana_version <kibana_dir>
# Prints the major.minor.patch version string, or empty on failure
get_kibana_version() {
  local dir="$1"
  local pkg="$dir/package.json"
  [[ ! -f "$pkg" ]] && return
  sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$pkg" | head -1
}

# Detect which package manager a Kibana worktree uses (newer branches: pnpm, older: yarn).
# Usage: detect_pkg_manager <kibana_dir>   → prints "pnpm" or "yarn"
# Same logic as in kbn-start.sh — keep them in sync.
detect_pkg_manager() {
  local dir="$1"
  if grep -qE '"packageManager" *: *"pnpm@' "$dir/package.json" 2>/dev/null || [[ -f "$dir/pnpm-lock.yaml" ]]; then
    echo "pnpm"
  else
    echo "yarn"
  fi
}

# Extract major.minor from a version string (e.g. "9.5.0" → "9.5")
major_minor() {
  echo "${1%.*}"
}

# ── END PORT HELPERS ──────────────────────────────────────


# ── SESSION BUILDERS ──────────────────────────────────────
setup_servers_window() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  tmux send-keys -t "${session}:servers" "cd $dir" Enter
  tmux split-window -h -c "$dir" -t "${session}:servers"
  tmux send-keys -t "${session}:servers" "cd $dir" Enter
  tmux select-pane -t "${session}:servers.0"
  tmux send-keys -t "${session}:servers.0" \
    "$KBN_START $data_folder --kibana-port $kibana_port --es-port $es_port --host $host" \
    Enter
}

# cursor window: left pane = cursor-agent (~60%), right pane = spare shell (~40%)
setup_cursor_window() {
  local session="$1" dir="$2"

  tmux new-window -t "$session" -n "cursor" -c "$dir"

  # Split: left gets ~60% of width
  tmux split-window -h -p 40 -c "$dir" -t "${session}:cursor"

  # Left pane: cursor-agent
  tmux send-keys -t "${session}:cursor.0" "cd $dir" Enter

  # Right pane: spare shell
  tmux send-keys -t "${session}:cursor.1" "cd $dir" Enter

  # Focus left (cursor-agent)
  tmux select-pane -t "${session}:cursor.0"
}

# Full session: all 7 windows
build_kibana_session() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  # 0: servers
  tmux rename-window -t "${session}:0" "servers"
  setup_servers_window "$session" "$dir" "$kibana_port" "$es_port" "$host" "$data_folder"

  # 1: cursor [left: cursor-agent | right: spare shell]
  setup_cursor_window "$session" "$dir"

  # 2: scripts
  tmux new-window -t "$session" -n "scripts" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:scripts"
  # left pane — synthetics private location (with session-specific ports)
  tmux send-keys -t "${session}:scripts.0" "$RUN_DATA synthetics"
  # right pane — SLO data ingestion (data_forge with session-specific ports)
  tmux send-keys -t "${session}:scripts.1" "$RUN_DATA slo"
  tmux select-pane -t "${session}:scripts.0"

  # 3: git
  tmux new-window -t "$session" -n "git" -c "$dir"
  tmux send-keys -t "${session}:git" "cd $dir && git status" Enter

  # 4: editor (vim, single pane)
  tmux new-window -t "$session" -n "editor" -c "$dir"
  tmux send-keys -t "${session}:editor" "cd $dir" Enter

  # 5: checks [top-left: eslint | top-right: type check | bottom: jest]
  tmux new-window -t "$session" -n "checks" -c "$dir"
  tmux split-window -v -c "$dir" -t "${session}:checks"          # pane 1: bottom (jest)
  tmux split-window -h -c "$dir" -t "${session}:checks.0"        # pane 2: top-right (type check)
  tmux send-keys -t "${session}:checks.0" "$RUN_CHECKS lint"
  tmux send-keys -t "${session}:checks.2" "$RUN_CHECKS typecheck"
  tmux send-keys -t "${session}:checks.1" "$RUN_CHECKS jest"
  tmux select-pane -t "${session}:checks.0"

  # 6: ftr [left: ftr server | right: ftr runner]
  tmux new-window -t "$session" -n "ftr" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:ftr"
  local pm
  pm=$(detect_pkg_manager "$dir")
  tmux send-keys -t "${session}:ftr.0" "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use && $pm test:ftr:server"
  tmux send-keys -t "${session}:ftr.1" "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use && $pm test:ftr:runner"
  tmux select-pane -t "${session}:ftr.0"

  tmux select-window -t "${session}:servers"
}

# Lightweight session: 5 windows
build_lightweight_session() {
  local session="$1" dir="$2" kibana_port="$3" es_port="$4" host="$5" data_folder="$6"

  # 0: servers
  tmux rename-window -t "${session}:0" "servers"
  setup_servers_window "$session" "$dir" "$kibana_port" "$es_port" "$host" "$data_folder"

  # 1: cursor [left: cursor-agent | right: spare shell]
  setup_cursor_window "$session" "$dir"

  # 2: scripts
  tmux new-window -t "$session" -n "scripts" -c "$dir"
  tmux split-window -h -c "$dir" -t "${session}:scripts"
  # left pane — synthetics private location (with session-specific ports)
  tmux send-keys -t "${session}:scripts.0" "$RUN_DATA synthetics"
  # right pane — SLO data ingestion (data_forge with session-specific ports)
  tmux send-keys -t "${session}:scripts.1" "$RUN_DATA slo"
  tmux select-pane -t "${session}:scripts.0"

  # 3: git
  tmux new-window -t "$session" -n "git" -c "$dir"
  tmux send-keys -t "${session}:git" "cd $dir && git status" Enter

  # 4: editor
  tmux new-window -t "$session" -n "editor" -c "$dir"
  tmux send-keys -t "${session}:editor" "cd $dir" Enter

  tmux select-window -t "${session}:servers"
}
# ── END SESSION BUILDERS ──────────────────────────────────


# ── COMMANDS ──────────────────────────────────────────────
branch_to_session() {
  echo "kibana-$(echo "$1" | sed 's|.*/||' | tr '/' '-' | tr '.' '-')"
}

print_help() {
  echo ""
  echo "${BOLD}dev-start.sh — Kibana tmux + worktree manager${NC}"
  echo ""
  echo "  ${YELLOW}Sessions${NC}"
  echo "    ${GREEN}(no args)${NC}                              Start/attach all sessions (+ recover orphans)"
  echo "    ${GREEN}switch <branch> [--remote]${NC}             Switch kibana-feat to a branch"
  echo "    ${GREEN}new <branch> [--full] [--remote]${NC}       Create worktree + hotfix session"
  echo "    ${GREEN}attach <branch>${NC}                        Attach to an existing session"
  echo "    ${GREEN}kill <branch>${NC}                          Kill session + remove worktree"
  echo "    ${GREEN}kill-all${NC}                               Kill ALL kibana-* sessions"
  echo "    ${GREEN}recover${NC}                                Recreate sessions for orphaned worktrees"
  echo "    ${GREEN}prune${NC}                                  Remove orphaned worktrees (no active session)"
  echo ""
  echo "  ${YELLOW}Operations${NC}"
  echo "    ${GREEN}restart <main|feat|branch> [--no-watch]${NC}  Restart ES + Kibana (--no-watch: one-off, for QA/FSEvents)"
  echo "    ${GREEN}renew [--cluster-name <n>] [--session <t>] [--save]${NC}"
  echo "                                               Refresh remote ES credentials (--session: main|feat|<branch>)"
  echo "    ${GREEN}sync [target] [--remote|--local]${NC}      Regenerate kibana.dev.yml (target: main|feat|branch|all)"
  echo "    ${GREEN}clean [main|feat|name|all]${NC}            List or delete ES data folders"
  echo ""
  echo "  ${YELLOW}Info${NC}"
  echo "    ${GREEN}list${NC}                                   Sessions, worktrees & port assignments"
  echo "    ${GREEN}status${NC}                                 Health check — ping ES + Kibana"
  echo "    ${GREEN}setup${NC}                                  Interactive config wizard"
  echo "    ${GREEN}help${NC}                                   This help message"
  echo ""
  echo "  ${YELLOW}Quick start:${NC}"
  echo "    ./dev-start.sh setup                          # first-time config"
  echo "    ./dev-start.sh switch feature/my-branch       # set your feature branch"
  echo "    ./dev-start.sh                                # start everything"
  echo ""
  echo "  ${YELLOW}Examples:${NC}"
  echo "    ./dev-start.sh switch feature/slo-filters --remote"
  echo "    ./dev-start.sh new fix/slo-crash --full --remote"
  echo "    ./dev-start.sh restart feat"
  echo "    ./dev-start.sh renew                          # auto-detects cluster, updates all remote sessions"
  echo "    ./dev-start.sh renew --session feat            # only update feat session"
  echo "    ./dev-start.sh sync                           # after editing template"
  echo "    ./dev-start.sh sync main --remote              # switch main to remote ES"
  echo "    ./dev-start.sh sync main --local               # switch main back to local ES"
  echo "    ./dev-start.sh clean feat                     # wipe ES data"
  echo ""
}

cmd_setup() {
  echo ""
  echo "${BOLD}kibana-env-setup — configuration wizard${NC}"
  echo ""

  if [[ -f "$KIBANA_DEV_CONF" ]]; then
    echo "${YELLOW}⚠${NC}  Config file already exists at $KIBANA_DEV_CONF"
    echo "   Current values will be shown as defaults. Press Enter to keep them."
    echo ""
    source "$KIBANA_DEV_CONF"
  fi

  # ── Ask for paths ──────────────────────────────────────
  local default_kibana="${KIBANA_MAIN_DIR}"
  local default_worktrees="${WORKTREE_BASE}"
  local default_esdata="${ES_DATA_BASE}"

  printf "  Kibana repo path [${BLUE}${default_kibana}${NC}]: "
  read -r input_kibana
  input_kibana="${input_kibana:-$default_kibana}"

  printf "  Worktrees path   [${BLUE}${default_worktrees}${NC}]: "
  read -r input_worktrees
  input_worktrees="${input_worktrees:-$default_worktrees}"

  printf "  ES data path     [${BLUE}${default_esdata}${NC}]: "
  read -r input_esdata
  input_esdata="${input_esdata:-$default_esdata}"

  # ── Ask for ports ──────────────────────────────────────
  echo ""
  echo "  ${BOLD}Ports${NC} (press Enter to keep defaults)"

  printf "  kibana-main  Kibana port [${BLUE}${MAIN_KIBANA_PORT}${NC}]: "
  read -r input_main_kport
  input_main_kport="${input_main_kport:-$MAIN_KIBANA_PORT}"

  printf "  kibana-main  ES port     [${BLUE}${MAIN_ES_PORT}${NC}]: "
  read -r input_main_eport
  input_main_eport="${input_main_eport:-$MAIN_ES_PORT}"

  printf "  kibana-feat  Kibana port [${BLUE}${FEAT_KIBANA_PORT}${NC}]: "
  read -r input_feat_kport
  input_feat_kport="${input_feat_kport:-$FEAT_KIBANA_PORT}"

  printf "  kibana-feat  ES port     [${BLUE}${FEAT_ES_PORT}${NC}]: "
  read -r input_feat_eport
  input_feat_eport="${input_feat_eport:-$FEAT_ES_PORT}"

  # ── Ask for remote ES (optional) ────────────────────────
  echo ""
  echo "  ${BOLD}Remote ES${NC} (optional — press Enter to skip)"

  local default_cluster="${OBLT_CLUSTER_NAME}"
  printf "  oblt-cli cluster name [${BLUE}${default_cluster:-none}${NC}]: "
  read -r input_cluster
  input_cluster="${input_cluster:-$default_cluster}"

  # ── Validate Kibana repo ───────────────────────────────
  echo ""
  if [[ -d "$input_kibana/.git" ]] || [[ -d "$input_kibana/package.json" ]]; then
    echo "  ${GREEN}✓${NC} Kibana repo found at $input_kibana"
  else
    echo "  ${YELLOW}⚠${NC} No git repo found at $input_kibana — make sure to clone Kibana there first."
  fi

  # ── Write config ───────────────────────────────────────
  {
    cat <<EOF
# Generated by: dev-start.sh setup
# Edit this file or re-run setup to change settings.

# Paths
KIBANA_MAIN_DIR="$input_kibana"
WORKTREE_BASE="$input_worktrees"
ES_DATA_BASE="$input_esdata"

# Ports — kibana-main
MAIN_KIBANA_PORT=$input_main_kport
MAIN_ES_PORT=$input_main_eport

# Ports — kibana-feat
FEAT_KIBANA_PORT=$input_feat_kport
FEAT_ES_PORT=$input_feat_eport
EOF
    if [[ -n "$input_cluster" ]]; then
      cat <<EOF

# Remote ES (oblt-cli)
OBLT_CLUSTER_NAME="$input_cluster"
EOF
    fi
  } > "$KIBANA_DEV_CONF"

  echo ""
  echo "${GREEN}✓${NC} Config written to $KIBANA_DEV_CONF"

  # ── Create directories if needed ───────────────────────
  mkdir -p "$input_worktrees" 2>/dev/null && \
    echo "${GREEN}✓${NC} Worktrees directory ready: $input_worktrees" || true
  mkdir -p "$input_esdata" 2>/dev/null && \
    echo "${GREEN}✓${NC} ES data directory ready: $input_esdata" || true

  # ── Set up symlinks ────────────────────────────────────
  echo ""
  echo "${BOLD}Symlinks${NC}"
  local script_dir="${0:A:h}"

  # kbn-start.sh → ~/bin/
  mkdir -p "$HOME/bin"
  if [[ -L "$HOME/bin/kbn-start.sh" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/kbn-start.sh already linked"
  elif [[ -f "$script_dir/kbn-start.sh" ]]; then
    ln -s "$script_dir/kbn-start.sh" "$HOME/bin/kbn-start.sh"
    chmod +x "$script_dir/kbn-start.sh"
    echo "  ${GREEN}✓${NC} ~/bin/kbn-start.sh → $script_dir/kbn-start.sh"
  fi

  # run-checks → ~/bin/
  if [[ -L "$HOME/bin/run-checks" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/run-checks already linked"
  elif [[ -f "$script_dir/run-checks.sh" ]]; then
    ln -s "$script_dir/run-checks.sh" "$HOME/bin/run-checks"
    chmod +x "$script_dir/run-checks.sh"
    echo "  ${GREEN}✓${NC} ~/bin/run-checks → $script_dir/run-checks.sh"
  fi

  # run-data → ~/bin/
  if [[ -L "$HOME/bin/run-data" ]]; then
    echo "  ${GREEN}✓${NC} ~/bin/run-data already linked"
  elif [[ -f "$script_dir/run-data.sh" ]]; then
    ln -s "$script_dir/run-data.sh" "$HOME/bin/run-data"
    chmod +x "$script_dir/run-data.sh"
    echo "  ${GREEN}✓${NC} ~/bin/run-data → $script_dir/run-data.sh"
  fi

  # dev-start.sh → ~/
  if [[ -L "$HOME/dev-start.sh" ]]; then
    echo "  ${GREEN}✓${NC} ~/dev-start.sh already linked"
  elif [[ -f "$script_dir/dev-start.sh" ]]; then
    ln -s "$script_dir/dev-start.sh" "$HOME/dev-start.sh"
    chmod +x "$script_dir/dev-start.sh"
    echo "  ${GREEN}✓${NC} ~/dev-start.sh → $script_dir/dev-start.sh"
  fi

  echo ""
  echo "${GREEN}✓${NC} Setup complete!"
  echo ""
  echo "  Next steps:"
  echo "    ${GREEN}~/dev-start.sh switch feature/your-branch${NC}   ← set your first feature branch"
  echo "    ${GREEN}~/dev-start.sh${NC}                              ← start all sessions"
  echo ""
}

cmd_list() {
  echo ""
  echo "${BOLD}Active tmux sessions:${NC}"
  tmux list-sessions 2>/dev/null | grep "^kibana" | while read line; do
    echo "  ${GREEN}●${NC} $line"
  done

  echo ""
  echo "${BOLD}Git worktrees:${NC}"
  local wt_path
  git -C "$KIBANA_MAIN_DIR" worktree list 2>/dev/null | while read line; do
    wt_path=$(echo "$line" | awk '{print $1}')
    # Only show the main repo and worktrees under WORKTREE_BASE
    [[ "$wt_path" == "$KIBANA_MAIN_DIR" || "$wt_path" == "$WORKTREE_BASE"/* ]] || continue
    echo "  ${BLUE}↳${NC} $line"
  done

  echo ""
  echo "${BOLD}Port assignments:${NC}"
  local main_k_port main_es_display main_branch
  main_k_port=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
  main_es_display=$(get_es_display "$KIBANA_MAIN_DIR/config/kibana.dev.yml")
  main_branch=$(git -C "$KIBANA_MAIN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  printf "  %-30s →  Kibana :%-6s  ES %s\n" \
    "kibana-main ($main_branch)" "${main_k_port:-$MAIN_KIBANA_PORT}" "$main_es_display"

  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    local feat_k_port feat_es_display
    feat_k_port=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    feat_es_display=$(get_es_display "$FEAT_DIR/config/kibana.dev.yml")
    printf "  %-30s →  Kibana :%-6s  ES %s\n" \
      "kibana-feat ($FEAT_BRANCH)" "${feat_k_port:-$FEAT_KIBANA_PORT}" "$feat_es_display"
  else
    printf "  %-30s →  ${YELLOW}not configured — run: ./dev-start.sh switch <branch>${NC}\n" "kibana-feat"
  fi

  # Declare before the loop — zsh prints values if `local` is re-run on an
  # already-declared variable (second iteration onwards).
  local es_display
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
    # skip the current feat worktree — already shown above
    [[ "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
    # skip if no active tmux session for this worktree
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')
    tmux has-session -t "$session_name" 2>/dev/null || continue
    k_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
    es_display=$(get_es_display "$yml")
    printf "  %-30s →  Kibana :%-6s  ES %s\n" \
      "kibana-$wt_name" "$k_port" "$es_display"
  done

  # Port mismatch warnings
  local warnings=()

  # kibana-main
  if [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]]; then
    local chk_main_k chk_main_es
    chk_main_k=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    chk_main_es=$(grep -E "^ *- \"?http://localhost:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    if [[ -n "$chk_main_k" && "$chk_main_k" != "$MAIN_KIBANA_PORT" ]]; then
      warnings+=("kibana-main: kibana.dev.yml has Kibana port $chk_main_k but expected $MAIN_KIBANA_PORT — fix: manually update to $MAIN_KIBANA_PORT or delete the file and re-run: ~/dev-start.sh")
    fi
    if [[ -n "$chk_main_es" && "$chk_main_es" != "$MAIN_ES_PORT" ]]; then
      warnings+=("kibana-main: kibana.dev.yml has ES port $chk_main_es but expected $MAIN_ES_PORT — fix: manually update to $MAIN_ES_PORT or delete the file and re-run: ~/dev-start.sh")
    fi
  fi

  # kibana-feat
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      existing_k=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      existing_es=$(grep -E "^ *- \"?http://localhost:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
      if [[ -n "$existing_k" && "$existing_k" != "$FEAT_KIBANA_PORT" ]]; then
        warnings+=("kibana-feat: kibana.dev.yml has Kibana port $existing_k but expected $FEAT_KIBANA_PORT — run: ~/dev-start.sh switch $FEAT_BRANCH")
      fi
      if [[ -n "$existing_es" && "$existing_es" != "$FEAT_ES_PORT" ]]; then
        warnings+=("kibana-feat: kibana.dev.yml has ES port $existing_es but expected $FEAT_ES_PORT — run: ~/dev-start.sh switch $FEAT_BRANCH")
      fi
    fi
  fi

  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo ""
    echo "${BOLD}${YELLOW}⚠ Port mismatches detected:${NC}"
    for w in "${warnings[@]}"; do
      echo "  ${YELLOW}⚠${NC} $w"
    done
  fi

  echo ""
}

cmd_status() {
  echo ""
  echo "${BOLD}Health check:${NC}"
  echo ""

  local has_sessions=false

  # Helper: check a single session
  check_session() {
    local label="$1" yml="$2"
    has_sessions=true

    local kibana_port es_port es_host is_remote
    kibana_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')

    # Detect local vs remote
    es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    es_host=$(grep -E "^ *hosts: https?://" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    is_remote=false
    [[ -z "$es_port" ]] && is_remote=true

    # Check Kibana
    local kbn_status kbn_color
    local kbn_http
    kbn_http=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${kibana_port}/api/status" --max-time 3 2>/dev/null)
    [[ -z "$kbn_http" ]] && kbn_http="000"
    if [[ "$kbn_http" == "200" ]]; then
      kbn_status="up" ; kbn_color="$GREEN"
    elif [[ "$kbn_http" == "000" ]]; then
      kbn_status="down" ; kbn_color="$RED"
    else
      kbn_status="starting" ; kbn_color="$YELLOW"
    fi

    # Check ES
    local es_status es_color es_display
    if [[ "$is_remote" == true ]]; then
      es_display="$es_host"
      local es_http
      es_http=$(curl -s -o /dev/null -w "%{http_code}" "$es_host" --max-time 5 2>/dev/null)
      [[ -z "$es_http" ]] && es_http="000"
      # Some Elastic Cloud deployments return 503 for unauthenticated requests.
      # Fall back to an authenticated request before declaring an error.
      if [[ "$es_http" != "200" && "$es_http" != "401" && "$es_http" != "000" ]]; then
        local auth_user auth_pass
        auth_user=$(grep -E "^ *username:" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
        auth_pass=$(grep -E "^ *password:" "$yml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
        if [[ -n "$auth_user" && -n "$auth_pass" ]]; then
          local auth_http
          auth_http=$(curl -s -o /dev/null -w "%{http_code}" -u "${auth_user}:${auth_pass}" "$es_host" --max-time 5 2>/dev/null)
          [[ "$auth_http" == "200" ]] && es_http="200"
        fi
      fi
      if [[ "$es_http" == "200" ]]; then
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "401" ]]; then
        # 401 means ES is reachable but needs auth — that's up
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "000" ]]; then
        es_status="unreachable" ; es_color="$RED"
      else
        es_status="error ($es_http)" ; es_color="$YELLOW"
      fi
    else
      es_display=":$es_port"
      local es_http
      es_http=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${es_port}/" --max-time 3 2>/dev/null)
      [[ -z "$es_http" ]] && es_http="000"
      if [[ "$es_http" == "200" || "$es_http" == "401" ]]; then
        es_status="up" ; es_color="$GREEN"
      elif [[ "$es_http" == "000" ]]; then
        es_status="down" ; es_color="$RED"
      else
        es_status="starting" ; es_color="$YELLOW"
      fi
    fi

    echo "  ${BOLD}$label${NC}"
    echo "    Kibana :${kibana_port}  ${kbn_color}${kbn_status}${NC}"
    echo "    ES     ${es_display}  ${es_color}${es_status}${NC}"
    echo ""
  }

  # kibana-main
  if tmux has-session -t "kibana-main" 2>/dev/null && [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]]; then
    local main_branch
    main_branch=$(git -C "$KIBANA_MAIN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    check_session "kibana-main ($main_branch)" "$KIBANA_MAIN_DIR/config/kibana.dev.yml"
  fi

  # kibana-feat
  if tmux has-session -t "kibana-feat" 2>/dev/null && [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      check_session "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR/config/kibana.dev.yml"
    fi
  fi

  # Hotfix sessions
  local wt_name session_name
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
    [[ -n "${FEAT_DIR:-}" && "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')
    tmux has-session -t "$session_name" 2>/dev/null || continue
    check_session "$session_name" "$yml"
  done

  if [[ "$has_sessions" == false ]]; then
    echo "  ${YELLOW}No active sessions found.${NC}"
    echo "  Start with: ${GREEN}./dev-start.sh${NC}"
  fi

  echo ""
}

cmd_sync() {
  local target="all" force_remote=false force_local=false

  # Parse arguments: target and optional --remote / --local flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) force_remote=true; shift ;;
      --local)  force_local=true; shift ;;
      *)        target="$1"; shift ;;
    esac
  done

  if [[ "$force_remote" == true && "$force_local" == true ]]; then
    echo "${RED}Error:${NC} Cannot use both --remote and --local."
    return 1
  fi

  echo ""
  echo "${BOLD}Syncing kibana.dev.yml from template${NC}"
  if [[ "$force_remote" == true ]]; then
    echo "  (forced remote ES mode)"
  elif [[ "$force_local" == true ]]; then
    echo "  (forced local ES mode)"
  fi
  echo ""

  local synced=0

  # Helper: sync a single worktree
  sync_one() {
    local label="$1" dir="$2" kibana_port="$3" es_port="$4"

    if [[ ! -d "$dir" ]]; then
      echo "  ${YELLOW}⚠${NC} $label — directory not found: $dir"
      return
    fi

    local yml="$dir/config/kibana.dev.yml"
    local use_remote=false

    if [[ "$force_remote" == true ]]; then
      use_remote=true
    elif [[ "$force_local" == true ]]; then
      use_remote=false
    elif [[ -f "$yml" ]] && grep -q "Remote ES" "$yml" 2>/dev/null; then
      use_remote=true
    fi

    if [[ "$use_remote" == true ]]; then
      generate_remote_kibana_dev_yml "$dir" "$kibana_port"
    else
      generate_kibana_dev_yml "$dir" "$kibana_port" "$es_port"
    fi
    synced=$((synced + 1))
  }

  case "$target" in
    main)
      sync_one "kibana-main" "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"
      ;;
    feat)
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        sync_one "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      else
        echo "${RED}Error:${NC} No feat state found. Run ${GREEN}./dev-start.sh switch <branch>${NC} first."
        return 1
      fi
      ;;
    all)
      # kibana-main
      sync_one "kibana-main" "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"

      # kibana-feat
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        sync_one "kibana-feat ($FEAT_BRANCH)" "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      fi

      # Hotfix sessions — only those with an active tmux session
      local wt_name session_name
      for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
        [[ -f "$yml" ]] || continue
        wt_name=$(echo "$yml" | sed "s|$WORKTREE_BASE/||" | sed 's|/config/kibana.dev.yml||')
        [[ -n "${FEAT_DIR:-}" && "$WORKTREE_BASE/$wt_name" == "$FEAT_DIR" ]] && continue
        session_name=$(echo "kibana-$wt_name" | tr '.' '-')
        tmux has-session -t "$session_name" 2>/dev/null || continue
        local wt_port wt_es_port
        wt_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
        wt_es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
        sync_one "$session_name" "$WORKTREE_BASE/$wt_name" "${wt_port}" "${wt_es_port}"
      done
      ;;
    *)
      # Treat as branch name
      local short_name wt_dir
      short_name=$(echo "$target" | sed 's|.*/||')
      wt_dir="$WORKTREE_BASE/$short_name"
      if [[ -f "$wt_dir/config/kibana.dev.yml" ]]; then
        local wt_port wt_es_port
        wt_port=$(grep -E "^ *port:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
        wt_es_port=$(grep -E "^ *- \"?http://localhost:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
        sync_one "kibana-$short_name" "$wt_dir" "${wt_port}" "${wt_es_port}"
      elif [[ -d "$wt_dir" ]]; then
        # Worktree exists but has no kibana.dev.yml (e.g. created outside `new`) —
        # assign fresh free ports and generate it so it shows up in list/status.
        local new_ports new_k new_es
        echo "${BLUE}→${NC} No kibana.dev.yml for $short_name — generating with fresh ports..."
        new_ports=$(find_free_ports)
        new_k=$(echo "$new_ports" | awk '{print $1}')
        new_es=$(echo "$new_ports" | awk '{print $2}')
        sync_one "kibana-$short_name" "$wt_dir" "$new_k" "$new_es"
      else
        echo "${RED}Error:${NC} No worktree found at $wt_dir"
        return 1
      fi
      ;;
  esac

  if [[ $synced -gt 0 ]]; then
    echo ""
    echo "${GREEN}✓${NC} Synced $synced session(s). Run ${GREEN}./dev-start.sh restart <session>${NC} to apply."
  fi
  echo ""
}

cmd_switch() {
  local branch="" use_remote=false

  # Parse arguments: branch name and optional --remote flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) use_remote=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    echo "  Usage: ${GREEN}./dev-start.sh switch <branch> [--remote]${NC}"
    exit 1
  fi

  local short_name worktree_dir
  short_name=$(echo "$branch" | sed 's|.*/||')
  worktree_dir="$WORKTREE_BASE/$short_name"

  echo ""
  echo "${BOLD}Switching kibana-feat → $branch${NC}"
  echo ""

  # Auto-create branch from upstream main if it doesn't exist locally or on origin
  # Done first — before killing any session — so we fail safe if the branch can't be created
  if ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "$branch" &>/dev/null && \
     ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "refs/remotes/origin/$branch" &>/dev/null; then
    echo "${BLUE}→${NC} Branch '$branch' not found — fetching upstream and creating branch..."

    git -C "$KIBANA_MAIN_DIR" fetch upstream
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to fetch from upstream — check your upstream remote."
      exit 1
    fi

    git -C "$KIBANA_MAIN_DIR" branch "$branch" upstream/main
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create branch '$branch'."
      exit 1
    fi
    echo "${GREEN}✓${NC} Branch '$branch' created from upstream/main"
  fi

  if tmux has-session -t "kibana-feat" 2>/dev/null; then
    echo "${BLUE}→${NC} Stopping current kibana-feat session..."
    tmux kill-session -t "kibana-feat"
    echo "${GREEN}✓${NC} Session stopped."
  fi

  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -n "${FEAT_DIR:-}" && "$FEAT_DIR" != "$worktree_dir" && -d "$FEAT_DIR" ]]; then
      remove_fleet_containers "$FEAT_DIR"
      echo "${BLUE}→${NC} Removing old worktree at $FEAT_DIR..."
      if ! git -C "$KIBANA_MAIN_DIR" worktree remove "$FEAT_DIR" --force 2>/dev/null; then
        echo "${YELLOW}⚠${NC} git worktree remove failed (directory not empty) — force-deleting..."
        rm -rf "$FEAT_DIR"
        git -C "$KIBANA_MAIN_DIR" worktree prune 2>/dev/null
      fi
      echo "${GREEN}✓${NC} Old worktree removed."
    fi
  fi

  if [[ ! -d "$worktree_dir" ]]; then
    echo "${BLUE}→${NC} Creating worktree for ${BOLD}$branch${NC}..."
    mkdir -p "$WORKTREE_BASE"
    git -C "$KIBANA_MAIN_DIR" worktree add "$worktree_dir" "$branch"
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create worktree."
      exit 1
    fi
    echo "${GREEN}✓${NC} Worktree created at $worktree_dir"
  else
    echo "${BLUE}→${NC} Worktree already exists at $worktree_dir, reusing."
  fi

  if [[ "$use_remote" == true ]]; then
    generate_remote_kibana_dev_yml "$worktree_dir" "$FEAT_KIBANA_PORT"
  else
    generate_kibana_dev_yml "$worktree_dir" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
  fi
  generate_cursor_mcp_json "$worktree_dir" "$FEAT_KIBANA_PORT" "$FEAT_HOST"
  save_feat_state "$branch" "$worktree_dir"

  echo "${BLUE}→${NC} Creating kibana-feat session..."
  tmux new-session -d -s "kibana-feat" -c "$worktree_dir"
  build_kibana_session "kibana-feat" "$worktree_dir" \
    "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT" "$FEAT_HOST" "$short_name"

  echo ""
  echo "${GREEN}✓${NC} kibana-feat is now on ${BOLD}$branch${NC}"
  if [[ "$use_remote" == true ]]; then
    local remote_host
    remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
    echo "   Kibana  → http://localhost:${FEAT_KIBANA_PORT}  (auto-starts — remote ES)"
    echo "   ES      → ${BLUE}${remote_host}${NC}  (from ~/.kibana-remote-es.yml)"
  else
    echo "   Kibana  → http://localhost:${FEAT_KIBANA_PORT}  (auto-starts after ES is ready)"
    echo "   ES      → http://localhost:${FEAT_ES_PORT}"
  fi
  echo "   Cursor  → KIBANA_URL=http://${FEAT_HOST}:${FEAT_KIBANA_PORT}"
  echo ""

  tmux_attach "kibana-feat"
}

cmd_new() {
  local branch="" mode="--lightweight" use_remote=false

  # Parse arguments: branch name, --full, --remote
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)   mode="--full"; shift ;;
      --remote) use_remote=true; shift ;;
      *)        branch="$1"; shift ;;
    esac
  done

  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    echo "  Usage: ${GREEN}./dev-start.sh new <branch> [--full] [--remote]${NC}"
    exit 1
  fi

  local session short_name worktree_dir
  session=$(branch_to_session "$branch")
  short_name=$(echo "$branch" | sed 's|.*/||')
  worktree_dir="$WORKTREE_BASE/$short_name"

  if tmux has-session -t "$session" 2>/dev/null; then
    echo "${YELLOW}Session '$session' already exists. Attaching...${NC}"
    tmux_attach "$session"
    exit 0
  fi

  # Auto-create branch from upstream main if it doesn't exist locally or on origin
  if ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "$branch" &>/dev/null && \
     ! git -C "$KIBANA_MAIN_DIR" rev-parse --verify "refs/remotes/origin/$branch" &>/dev/null; then
    echo "${BLUE}→${NC} Branch '$branch' not found — fetching upstream and creating branch..."

    git -C "$KIBANA_MAIN_DIR" fetch upstream
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to fetch from upstream — check your upstream remote."
      exit 1
    fi

    git -C "$KIBANA_MAIN_DIR" branch "$branch" upstream/main
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create branch '$branch'."
      exit 1
    fi
    echo "${GREEN}✓${NC} Branch '$branch' created from upstream/main"
  fi

  if [[ ! -d "$worktree_dir" ]]; then
    echo "${BLUE}→${NC} Creating worktree for ${BOLD}$branch${NC}..."
    mkdir -p "$WORKTREE_BASE"
    git -C "$KIBANA_MAIN_DIR" worktree add "$worktree_dir" "$branch"
    if [[ $? -ne 0 ]]; then
      echo "${RED}Error:${NC} Failed to create worktree."
      exit 1
    fi
    echo "${GREEN}✓${NC} Worktree created at $worktree_dir"
  else
    echo "${BLUE}→${NC} Reusing existing worktree at $worktree_dir"
  fi

  local ports kibana_port es_port
  echo "${BLUE}→${NC} Finding available ports..."
  ports=$(find_free_ports)
  kibana_port=$(echo "$ports" | awk '{print $1}')
  es_port=$(echo "$ports" | awk '{print $2}')

  if [[ "$use_remote" == true ]]; then
    generate_remote_kibana_dev_yml "$worktree_dir" "$kibana_port"
  elif [[ -f "$worktree_dir/config/kibana.dev.yml" ]]; then
    echo "${YELLOW}⚠${NC} kibana.dev.yml already exists — keeping existing config."
    echo "${YELLOW}  Delete $worktree_dir/config/kibana.dev.yml and re-run to regenerate with fresh ports.${NC}"
    local existing_k
    existing_k=$(grep -E "^ *port:" "$worktree_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
    local existing_es
    existing_es=$(grep -E "^ *- \"?http://localhost:" "$worktree_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
    [[ -n "$existing_k" ]] && kibana_port="$existing_k"
    [[ -n "$existing_es" ]] && es_port="$existing_es"
  else
    generate_kibana_dev_yml "$worktree_dir" "$kibana_port" "$es_port"
  fi
  generate_cursor_mcp_json "$worktree_dir" "$kibana_port" "localhost"

  echo "${BLUE}→${NC} Creating tmux session ${BOLD}$session${NC}..."
  tmux new-session -d -s "$session" -c "$worktree_dir"

  if [[ "$mode" == "--full" ]]; then
    build_kibana_session "$session" "$worktree_dir" "$kibana_port" "$es_port" "localhost" "$short_name"
  else
    build_lightweight_session "$session" "$worktree_dir" "$kibana_port" "$es_port" "localhost" "$short_name"
  fi

  echo ""
  echo "${GREEN}✓${NC} Session '${BOLD}$session${NC}' ready"
  if [[ "$use_remote" == true ]]; then
    local remote_host
    remote_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
    echo "   Kibana  → http://localhost:${kibana_port}  (auto-starts — remote ES)"
    echo "   ES      → ${BLUE}${remote_host}${NC}  (from ~/.kibana-remote-es.yml)"
  else
    echo "   Kibana  → http://localhost:${kibana_port}  (auto-starts after ES is ready)"
    echo "   ES      → http://localhost:${es_port}"
  fi
  echo "   Cursor  → KIBANA_URL set to http://localhost:${kibana_port}"
  echo ""
  echo "  Switch sessions:  Ctrl-a s"
  echo ""

  tmux_attach "$session"
}

tmux_attach() {
  # Use switch-client when already inside tmux, attach-session otherwise.
  local session="$1"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

cmd_attach() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    exit 1
  fi

  local session
  session=$(branch_to_session "$branch")

  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "${RED}Error:${NC} No session found for '$branch' (looked for '$session')."
    echo "  Run ${GREEN}./dev-start.sh list${NC} to see active sessions."
    echo "  Run ${GREEN}./dev-start.sh new $branch${NC} to create one."
    exit 1
  fi

  tmux_attach "$session"
}

# Remove the persistent synthetics Fleet Server / Agent containers that
# `run-data synthetics` started for a worktree (fleet-server-<port> / elastic-agent-<port>).
# They use --restart unless-stopped, so they would otherwise outlive the worktree.
remove_fleet_containers() {
  local dir="$1" port
  command -v docker >/dev/null 2>&1 || return 0
  port=$(grep -E "^ *port:" "$dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
  [[ -z "$port" ]] && return 0
  if docker rm -f "fleet-server-$port" "elastic-agent-$port" >/dev/null 2>&1; then
    echo "${GREEN}✓${NC} Removed Fleet Server/Agent containers for :$port"
  fi
}

cmd_kill() {
  local branch="$1"
  if [[ -z "$branch" ]]; then
    echo "${RED}Error:${NC} Please provide a branch name."
    exit 1
  fi

  local session short_name worktree_dir
  session=$(branch_to_session "$branch")
  short_name=$(echo "$branch" | sed 's|.*/||')
  # Find worktree by matching branch name in git worktree list
  worktree_dir=$(git -C "$KIBANA_MAIN_DIR" worktree list 2>/dev/null \
    | grep "\[$short_name\]\|\[$branch\]" \
    | awk '{print $1}' | head -1)
  # Fall back to derived path if not found via git
  [[ -z "$worktree_dir" ]] && worktree_dir="$WORKTREE_BASE/$short_name"

  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session"
    echo "${GREEN}✓${NC} Killed session '$session'."
  else
    echo "${YELLOW}⚠${NC} No session found for '$session'."
  fi

  if [[ -d "$worktree_dir" ]]; then
    remove_fleet_containers "$worktree_dir"
    echo "${BLUE}→${NC} Removing worktree at $worktree_dir..."
    if ! git -C "$KIBANA_MAIN_DIR" worktree remove "$worktree_dir" --force 2>/dev/null; then
      echo "${YELLOW}⚠${NC} git worktree remove failed — force-deleting..."
      rm -rf "$worktree_dir"
      git -C "$KIBANA_MAIN_DIR" worktree prune 2>/dev/null
    fi
    echo "${GREEN}✓${NC} Worktree removed."
  else
    echo "${YELLOW}⚠${NC} No worktree found at $worktree_dir."
  fi
}

cmd_kill_all() {
  echo "${YELLOW}Killing all kibana-* sessions...${NC}"
  tmux list-sessions 2>/dev/null | grep "^kibana" | cut -d: -f1 | while read s; do
    tmux kill-session -t "$s"
    echo "${GREEN}✓${NC} Killed: $s"
  done
}

cmd_prune() {
  echo ""
  echo "${BOLD}Checking for orphaned worktrees${NC} (no active tmux session)..."
  echo ""

  # Get active tmux session names
  local active_sessions
  active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  # Load feat state to know which worktree is the current feat
  local feat_dir=""
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    feat_dir="${FEAT_DIR:-}"
  fi

  # Collect orphaned worktrees into parallel indexed variables (zsh-compatible)
  local orphan_count=0
  local orphan_dirs=""    # newline-separated list of dirs
  local orphan_labels=""  # newline-separated list of labels

  for wt_dir in "$WORKTREE_BASE"/*/; do
    [[ -d "$wt_dir" ]] || continue
    local wt_name
    wt_name=$(basename "$wt_dir")

    # Skip if this is the current feat worktree
    if [[ "$WORKTREE_BASE/$wt_name" == "$feat_dir" ]]; then
      continue
    fi

    # Check if there's an active tmux session for this worktree
    # Special case: worktrees/main is NOT used by kibana-main (which uses KIBANA_MAIN_DIR)
    local session_name
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')
    if [[ "$wt_name" != "main" ]] && echo "$active_sessions" | grep -q "^${session_name}$"; then
      continue
    fi

    # This worktree has no active session — it's orphaned
    local branch_name
    branch_name=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local size
    size=$(du -sh "$wt_dir" 2>/dev/null | awk '{print $1}')
    orphan_count=$((orphan_count + 1))
    orphan_dirs="${orphan_dirs}${wt_dir}
"
    orphan_labels="${orphan_labels}${wt_name} (${branch_name}, ${size})
"
  done

  if [[ $orphan_count -eq 0 ]]; then
    echo "  ${GREEN}✓${NC} No orphaned worktrees found."
    echo ""
    return
  fi

  echo "  Found $orphan_count orphaned worktree(s):"
  echo ""
  local idx=1
  echo "$orphan_labels" | while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    local dir
    dir=$(echo "$orphan_dirs" | sed -n "${idx}p")
    echo "    ${BLUE}${idx}.${NC} $label"
    echo "       $dir"
    idx=$((idx + 1))
  done
  echo ""

  read -r "?Remove all orphaned worktrees? [y/N/number to remove one]: " answer

  case "$answer" in
    y|Y)
      echo "$orphan_dirs" | while IFS= read -r wt_dir; do
        [[ -z "$wt_dir" ]] && continue
        local wt_name
        wt_name=$(basename "$wt_dir")
        echo "${BLUE}→${NC} Removing $wt_name..."
        git -C "$KIBANA_MAIN_DIR" worktree remove "$wt_dir" --force 2>/dev/null \
          || rm -rf "$wt_dir"
        echo "${GREEN}✓${NC} Removed."
      done
      git -C "$KIBANA_MAIN_DIR" worktree prune 2>/dev/null
      echo ""
      echo "${GREEN}✓${NC} All orphaned worktrees removed."
      ;;
    [0-9]*)
      local pick_dir
      pick_dir=$(echo "$orphan_dirs" | sed -n "${answer}p")
      if [[ -n "$pick_dir" && -d "$pick_dir" ]]; then
        local wt_name
        wt_name=$(basename "$pick_dir")
        echo "${BLUE}→${NC} Removing $wt_name..."
        git -C "$KIBANA_MAIN_DIR" worktree remove "$pick_dir" --force 2>/dev/null \
          || rm -rf "$pick_dir"
        git -C "$KIBANA_MAIN_DIR" worktree prune 2>/dev/null
        echo "${GREEN}✓${NC} Removed."
      else
        echo "${RED}Error:${NC} Invalid number."
      fi
      ;;
    *)
      echo "  Skipped."
      ;;
  esac
  echo ""
}

recover_orphaned_sessions() {
  # Find worktrees that exist but have no matching tmux session, and recreate them.
  # Called by cmd_main (automatic) and cmd_recover (explicit).

  local active_sessions
  active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  # Load feat state to skip the current feat worktree (it's managed separately)
  local feat_dir=""
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    feat_dir="${FEAT_DIR:-}"
  fi

  local recovered=0
  for wt_dir in "$WORKTREE_BASE"/*/; do
    [[ -d "$wt_dir" ]] || continue
    local wt_name
    wt_name=$(basename "$wt_dir")

    # Skip if this is the current feat worktree (managed by kibana-feat session)
    [[ "$WORKTREE_BASE/$wt_name" == "$feat_dir" ]] && continue

    # Skip "main" worktree — kibana-main uses KIBANA_MAIN_DIR, not a worktree
    [[ "$wt_name" == "main" ]] && continue

    # Derive session name the same way branch_to_session does
    local session_name
    session_name=$(echo "kibana-$wt_name" | tr '.' '-')

    # Skip if session already exists
    echo "$active_sessions" | grep -q "^${session_name}$" && continue

    # ── Orphaned worktree found — recover it ──
    echo "${BLUE}→${NC} Recovering session ${BOLD}$session_name${NC} from worktree $wt_name..."

    # Read ports from existing kibana.dev.yml, or assign fresh ones
    local kibana_port="" es_port="" use_remote=false
    if [[ -f "$wt_dir/config/kibana.dev.yml" ]]; then
      kibana_port=$(grep -E "^ *port:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      es_port=$(grep -E "^ *- \"?http://localhost:" "$wt_dir/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
      # Detect remote ES config (generated with --remote flag)
      if grep -q "# Remote ES" "$wt_dir/config/kibana.dev.yml" 2>/dev/null; then
        use_remote=true
      fi
    fi

    # If ports weren't found (no config or remote ES), find free ones
    if [[ -z "$kibana_port" ]]; then
      local ports
      ports=$(find_free_ports)
      kibana_port=$(echo "$ports" | awk '{print $1}')
      es_port=$(echo "$ports" | awk '{print $2}')
    fi
    if [[ -z "$es_port" && "$use_remote" == false ]]; then
      local ports
      ports=$(find_free_ports)
      kibana_port=$(echo "$ports" | awk '{print $1}')
      es_port=$(echo "$ports" | awk '{print $2}')
    fi

    # Regenerate cursor MCP config
    generate_cursor_mcp_json "$wt_dir" "$kibana_port" "localhost"

    # Create session and build windows
    tmux new-session -d -s "$session_name" -c "$wt_dir"
    build_lightweight_session "$session_name" "$wt_dir" "$kibana_port" "${es_port:-0}" "localhost" "$wt_name"

    if [[ "$use_remote" == true ]]; then
      echo "${GREEN}✓${NC} Recovered: $session_name  Kibana :$kibana_port  (remote ES)"
    else
      echo "${GREEN}✓${NC} Recovered: $session_name  Kibana :$kibana_port  ES :$es_port"
    fi
    recovered=$((recovered + 1))
  done

  if [[ $recovered -gt 0 ]]; then
    echo ""
    echo "${GREEN}✓${NC} Recovered $recovered orphaned session(s)."
  fi
  # Store count so callers can check it (return codes are limited to 0-255)
  RECOVERED_COUNT=$recovered
}

cmd_recover() {
  echo ""
  echo "${BOLD}Recovering orphaned worktree sessions...${NC}"
  echo ""
  recover_orphaned_sessions
  if [[ ${RECOVERED_COUNT:-0} -eq 0 ]]; then
    echo "  ${GREEN}✓${NC} No orphaned worktrees found — all sessions are running."
  fi
  echo ""
}

cmd_restart() {
  local no_watch=false
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-watch) no_watch=true; shift ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
        else
          echo "${RED}Error:${NC} Unexpected argument: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$target" ]]; then
    echo "${RED}Error:${NC} Please specify which session to restart."
    echo ""
    echo "  Usage: ${GREEN}./dev-start.sh restart main|feat|<branch> [--no-watch]${NC}"
    echo ""
    echo "  Examples:"
    echo "    ${GREEN}./dev-start.sh restart feat${NC}"
    echo "    ${GREEN}./dev-start.sh restart feat --no-watch${NC}   # skip file watcher (QA / FSEvents workaround)"
    echo "    ${GREEN}./dev-start.sh restart main${NC}"
    echo "    ${GREEN}./dev-start.sh restart slo-crash${NC}"
    return 1
  fi

  # Resolve target → session name + directory
  local session="" dir=""
  case "$target" in
    main)
      session="kibana-main"
      dir="$KIBANA_MAIN_DIR"
      ;;
    feat)
      session="kibana-feat"
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        dir="$FEAT_DIR"
      else
        echo "${RED}Error:${NC} No feat state found. Run ${GREEN}./dev-start.sh switch <branch>${NC} first."
        return 1
      fi
      ;;
    *)
      session=$(branch_to_session "$target")
      local short_name
      short_name=$(echo "$target" | sed 's|.*/||')
      dir="$WORKTREE_BASE/$short_name"
      ;;
  esac

  # Verify the session exists
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "${RED}Error:${NC} Session '$session' is not running."
    echo "  Check active sessions with: ${GREEN}./dev-start.sh list${NC}"
    return 1
  fi

  # Read ports and detect local vs remote from existing config
  local yml="$dir/config/kibana.dev.yml"
  if [[ ! -f "$yml" ]]; then
    echo "${RED}Error:${NC} No kibana.dev.yml found at $dir/config/"
    return 1
  fi

  local kibana_port es_port host data_folder is_remote
  kibana_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
  es_port=$(grep -E "^ *- \"?http://localhost:" "$yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
  is_remote=false

  if [[ -z "$es_port" ]]; then
    is_remote=true
    es_port="9200"  # placeholder — kbn-start.sh detects remote ES from kibana.dev.yml and skips local ES
  fi

  # Determine host and data folder based on session type
  case "$target" in
    main) host="$MAIN_HOST"; data_folder="$MAIN_DATA_FOLDER" ;;
    feat)
      host="$FEAT_HOST"
      data_folder=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
      ;;
    *)
      host="localhost"
      data_folder=$(echo "$target" | sed 's|.*/||')
      ;;
  esac

  echo ""
  echo "${BOLD}Restarting $session${NC}"

  # Verify the servers window has 2 panes — if not, rebuild the session from scratch
  local pane_count
  pane_count=$(tmux list-panes -t "${session}:servers" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$pane_count" -ne 2 ]]; then
    echo "${YELLOW}⚠${NC} servers window has $pane_count pane(s) instead of 2 — rebuilding session..."
    tmux kill-session -t "$session"

    # Recreate the session with the full layout
    tmux new-session -d -s "$session" -c "$dir"
    build_kibana_session "$session" "$dir" \
      "$kibana_port" "$es_port" "$host" "$data_folder"

    echo ""
    echo "${GREEN}✓${NC} Session ${BOLD}$session${NC} rebuilt from scratch."
    if [[ "$is_remote" == true ]]; then
      echo "   Kibana  → http://localhost:${kibana_port}  (remote ES)"
    else
      echo "   Kibana  → http://localhost:${kibana_port}"
      echo "   ES      → http://localhost:${es_port}"
    fi
    echo ""
    return
  fi

  # ── Stop everything: kill processes by port, then ensure clean panes ──

  # Kill Kibana process by port (pane 1)
  echo "${BLUE}→${NC} Stopping Kibana (port $kibana_port)..."
  if lsof -ti :${kibana_port} &>/dev/null; then
    lsof -ti :${kibana_port} | xargs kill 2>/dev/null || true
    local wait_count=0
    while lsof -ti :${kibana_port} &>/dev/null && [[ $wait_count -lt 15 ]]; do
      sleep 2
      wait_count=$((wait_count + 1))
    done
    # Force-kill if still hanging
    if lsof -ti :${kibana_port} &>/dev/null; then
      echo "${YELLOW}⚠${NC} Kibana didn't exit cleanly, force-killing..."
      lsof -ti :${kibana_port} | xargs kill -9 2>/dev/null || true
      sleep 1
    fi
  fi

  # Kill ES process by port (pane 0) — local only
  if [[ "$is_remote" != true ]]; then
    echo "${BLUE}→${NC} Stopping ES (port $es_port)..."
    if lsof -ti :${es_port} &>/dev/null; then
      lsof -ti :${es_port} | xargs kill 2>/dev/null || true
      local wait_count=0
      while lsof -ti :${es_port} &>/dev/null && [[ $wait_count -lt 10 ]]; do
        sleep 2
        wait_count=$((wait_count + 1))
      done
    fi
  fi

  # Also kill the kbn-start tail/watcher if still running in pane 0
  tmux send-keys -t "${session}:servers.0" C-c
  sleep 1

  # Ensure both panes are at a clean shell prompt
  tmux send-keys -t "${session}:servers.0" C-c
  tmux send-keys -t "${session}:servers.1" C-c
  sleep 1
  tmux send-keys -t "${session}:servers.0" "" Enter
  tmux send-keys -t "${session}:servers.1" "" Enter
  sleep 1

  # Re-launch kbn-start in the left pane
  echo "${BLUE}→${NC} Re-launching kbn-start..."
  local kbn_start_cmd="$KBN_START $data_folder --kibana-port $kibana_port --es-port ${es_port} --host $host"
  if [[ "$no_watch" == true ]]; then
    kbn_start_cmd="KBN_EXTRA_ARGS=\"${KBN_EXTRA_ARGS} --no-watch\" $kbn_start_cmd"
    echo "${YELLOW}ℹ${NC}  Using --no-watch for this restart only (file watcher disabled)"
  fi
  tmux send-keys -t "${session}:servers.0" \
    "$kbn_start_cmd" \
    Enter

  echo ""
  echo "${GREEN}✓${NC} Restart initiated for ${BOLD}$session${NC}"
  if [[ "$is_remote" == true ]]; then
    echo "   Kibana  → http://localhost:${kibana_port}  (remote ES)"
  else
    echo "   Kibana  → http://localhost:${kibana_port}"
    echo "   ES      → http://localhost:${es_port}"
  fi
  echo ""
}

# Helper: prompt to create a new oblt-cli cluster, parse the name, save it
# Returns 0 if cluster creation was initiated, 1 otherwise
offer_cluster_create() {
  printf "  Create a new cluster? [y/N] "
  read -r reply
  if [[ "$reply" != [yY] ]]; then
    echo "  Aborted."
    return 1
  fi

  echo ""
  echo "${BLUE}→${NC} Creating cluster..."
  local create_output
  create_output=$(eval "$OBLT_CLUSTER_CREATE_CMD" 2>&1)
  local create_rc=$?

  # Show the output so the user can see the GitHub PR link and Slack notice
  echo "$create_output"
  echo ""

  if [[ $create_rc -ne 0 ]]; then
    echo "${RED}Error:${NC} Cluster creation failed (exit code $create_rc)."
    return 1
  fi

  # Parse the new cluster name from "Cluster creation is requested : <name>"
  local new_cluster
  new_cluster=$(echo "$create_output" | sed -n 's/.*Cluster creation is requested *: *//p' | tr -d '[:space:]')

  if [[ -z "$new_cluster" ]]; then
    echo "${YELLOW}⚠${NC}  Could not parse the new cluster name from oblt-cli output."
    echo "  Once the cluster is ready, run:"
    echo "    ${GREEN}./dev-start.sh renew --cluster-name <name> --save${NC}"
    return 1
  fi

  echo "${GREEN}✓${NC} New cluster: ${BOLD}$new_cluster${NC}"
  save_cluster_name_to_conf "$new_cluster"

  echo ""
  echo "  ${YELLOW}⏳${NC} Cluster is provisioning — you'll get a Slack notification when it's ready."
  echo "  Then run: ${GREEN}./dev-start.sh renew${NC}"
  return 0
}

# Helper: destroy an old cluster and create a new one
# Usage: offer_cluster_replace <cluster_name>
# Returns 0 if creation was initiated, 1 otherwise
offer_cluster_replace() {
  local old_cluster="$1"

  echo ""
  echo "${BLUE}→${NC} Destroying old cluster '${old_cluster}'..."
  if ! oblt-cli cluster destroy --cluster-name "$old_cluster" 2>&1; then
    echo "${RED}Error:${NC} Failed to destroy cluster '$old_cluster'."
    echo "  You may need to destroy it manually:"
    echo "    ${GREEN}oblt-cli cluster destroy --cluster-name $old_cluster${NC}"
    echo ""
  else
    echo "${GREEN}✓${NC} Cluster '$old_cluster' destroyed."
    echo ""
  fi

  offer_cluster_create
  return $?
}

# Helper: check version mismatch between remote ES and local Kibana sessions
# Detects compatible sessions and offers to replace or add a cluster
# Usage: handle_version_mismatch <es_version> <cluster_name> <es_host_url>
# Returns 0 if user action was taken, 1 if skipped
handle_version_mismatch() {
  local es_version="$1" cluster_name="$2" es_host_url="$3"
  local es_mm
  es_mm=$(major_minor "$es_version")

  echo "${YELLOW}⚠${NC}  Version mismatch: ES is ${BOLD}$es_version${NC} but local Kibana needs a matching major.minor."
  echo ""

  # Collect all remote sessions and their Kibana versions
  local compatible_sessions=()
  local all_sessions_mismatched=true

  # Check kibana-main
  if [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]] && \
     grep -q "Remote ES" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null; then
    local main_kbn_ver main_kbn_mm
    main_kbn_ver=$(get_kibana_version "$KIBANA_MAIN_DIR")
    main_kbn_mm=$(major_minor "$main_kbn_ver")
    if [[ -n "$main_kbn_ver" && "$main_kbn_mm" == "$es_mm" ]]; then
      compatible_sessions+=("kibana-main (Kibana $main_kbn_ver — compatible)")
      all_sessions_mismatched=false
    fi
  fi

  # Check kibana-feat
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    if [[ -n "${FEAT_DIR:-}" && -f "$FEAT_DIR/config/kibana.dev.yml" ]] && \
       grep -q "Remote ES" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null; then
      local feat_kbn_ver feat_kbn_mm feat_name
      feat_kbn_ver=$(get_kibana_version "$FEAT_DIR")
      feat_kbn_mm=$(major_minor "$feat_kbn_ver")
      feat_name=$(basename "$FEAT_DIR")
      if [[ -n "$feat_kbn_ver" && "$feat_kbn_mm" == "$es_mm" ]]; then
        compatible_sessions+=("kibana-feat/$feat_name (Kibana $feat_kbn_ver — compatible)")
        all_sessions_mismatched=false
      fi
    fi
  fi

  # Check hotfix worktrees
  # Note: declare locals before the loop — zsh prints values if `local` is
  # called again on an already-declared variable (second iteration onwards).
  local wt_dir wt_name wt_kbn_ver wt_kbn_mm
  for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
    [[ -f "$yml" ]] || continue
    grep -q "Remote ES" "$yml" 2>/dev/null || continue
    wt_dir=$(dirname "$(dirname "$yml")")
    wt_name=$(basename "$wt_dir")
    # Skip feat worktree (already handled above)
    [[ -n "${FEAT_DIR:-}" && "$wt_dir" == "$FEAT_DIR" ]] && continue
    wt_kbn_ver=$(get_kibana_version "$wt_dir")
    wt_kbn_mm=$(major_minor "$wt_kbn_ver")
    if [[ -n "$wt_kbn_ver" && "$wt_kbn_mm" == "$es_mm" ]]; then
      compatible_sessions+=("kibana-$wt_name (Kibana $wt_kbn_ver — compatible)")
      all_sessions_mismatched=false
    fi
  done

  # Check if other clusters already exist (user may have created one manually)
  local other_clusters=()
  if command -v oblt-cli &>/dev/null; then
    local all_clusters
    all_clusters=$(oblt-cli cluster list 2>&1 | sed -n '/CLUSTER NAME/,$ p' | tail -n +2 | sed 's/[^a-zA-Z0-9 _-]/ /g' | awk 'NF && $1 ~ /[a-z]/ {print $1}')
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      # Exclude the current (mismatched) cluster
      [[ "$c" == "$cluster_name" ]] && continue
      other_clusters+=("$c")
    done <<< "$all_clusters"
  fi

  # Case 1 & 2: No compatible sessions — safe to destroy + create
  if [[ "$all_sessions_mismatched" == true ]]; then
    if [[ ${#other_clusters[@]} -gt 0 ]]; then
      echo "  Other clusters available:"
      local idx=1
      for c in "${other_clusters[@]}"; do
        echo "    ${GREEN}${idx})${NC} Switch to ${BOLD}$c${NC}"
        (( idx++ ))
      done
      echo "    ${GREEN}${idx})${NC} Destroy old cluster and create a new one"
      (( idx++ ))
      echo "    ${GREEN}${idx})${NC} Skip — do nothing"
      echo ""
      printf "  Choice [1-${idx}]: "
      read -r choice
      if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#other_clusters[@]} ]]; then
        local selected="${other_clusters[$((choice))]}"
        echo ""
        echo "${BLUE}→${NC} Switching to cluster '${BOLD}$selected${NC}'..."
        save_cluster_name_to_conf "$selected"
        # Re-run renew with the new cluster to fetch its credentials
        cmd_renew --cluster-name "$selected"
        return $?
      elif [[ "$choice" == "$(( ${#other_clusters[@]} + 1 ))" ]]; then
        offer_cluster_replace "$cluster_name"
        return $?
      fi
      echo "  Skipped."
      return 1
    else
      printf "  Destroy old cluster and create a new one? [y/N] "
      read -r reply
      if [[ "$reply" == [yY] ]]; then
        offer_cluster_replace "$cluster_name"
        return $?
      fi
      echo "  Skipped."
      return 1
    fi
  fi

  # Case 3: Some sessions still match the old cluster
  echo "  These sessions still use this cluster (ES $es_version):"
  for s in "${compatible_sessions[@]}"; do
    echo "    ${BLUE}↳${NC} $s"
  done
  echo ""
  echo "  Options:"
  local opt_num=1
  if [[ ${#other_clusters[@]} -gt 0 ]]; then
    for c in "${other_clusters[@]}"; do
      echo "    ${GREEN}${opt_num})${NC} Switch to ${BOLD}$c${NC}  ${GREEN}[recommended]${NC}"
      (( opt_num++ ))
    done
    echo "    ${GREEN}${opt_num})${NC} Create a ${BOLD}new${NC} cluster and keep the old one"
    (( opt_num++ ))
  else
    echo "    ${GREEN}${opt_num})${NC} Create a ${BOLD}new${NC} cluster and keep the old one  ${GREEN}[recommended]${NC}"
    (( opt_num++ ))
  fi
  local destroy_num=$opt_num
  echo "    ${GREEN}${opt_num})${NC} Destroy old cluster and create new (breaks sessions above)"
  (( opt_num++ ))
  local skip_num=$opt_num
  echo "    ${GREEN}${opt_num})${NC} Skip — do nothing"
  echo ""
  printf "  Choice [1-${opt_num}]: "
  read -r choice
  # Handle switch-to-existing-cluster choices
  if [[ ${#other_clusters[@]} -gt 0 && "$choice" =~ ^[0-9]+$ && \
        "$choice" -ge 1 && "$choice" -le ${#other_clusters[@]} ]]; then
    local selected="${other_clusters[$((choice))]}"
    echo ""
    echo "${BLUE}→${NC} Switching to cluster '${BOLD}$selected${NC}'..."
    save_cluster_name_to_conf "$selected"
    cmd_renew --cluster-name "$selected"
    return $?
  fi
  # Handle create / destroy / skip
  local create_num=$(( ${#other_clusters[@]} + 1 ))
  case "$choice" in
    "$create_num")
      offer_cluster_create
      return $?
      ;;
    "$destroy_num")
      offer_cluster_replace "$cluster_name"
      return $?
      ;;
    *)
      echo "  Skipped."
      return 1
      ;;
  esac
}

# Helper: save/update OBLT_CLUSTER_NAME in ~/.kibana-dev.conf
save_cluster_name_to_conf() {
  local name="$1"
  if [[ -f "$KIBANA_DEV_CONF" ]]; then
    if grep -q "^OBLT_CLUSTER_NAME=" "$KIBANA_DEV_CONF" 2>/dev/null; then
      sed "s|^OBLT_CLUSTER_NAME=.*|OBLT_CLUSTER_NAME=\"$name\"|" "$KIBANA_DEV_CONF" > "$KIBANA_DEV_CONF.tmp" && mv "$KIBANA_DEV_CONF.tmp" "$KIBANA_DEV_CONF"
    elif grep -q "^# *OBLT_CLUSTER_NAME=" "$KIBANA_DEV_CONF" 2>/dev/null; then
      sed "s|^# *OBLT_CLUSTER_NAME=.*|OBLT_CLUSTER_NAME=\"$name\"|" "$KIBANA_DEV_CONF" > "$KIBANA_DEV_CONF.tmp" && mv "$KIBANA_DEV_CONF.tmp" "$KIBANA_DEV_CONF"
    else
      echo "" >> "$KIBANA_DEV_CONF"
      echo "# Remote ES (oblt-cli)" >> "$KIBANA_DEV_CONF"
      echo "OBLT_CLUSTER_NAME=\"$name\"" >> "$KIBANA_DEV_CONF"
    fi
  else
    echo "# ~/.kibana-dev.conf — generated by dev-start.sh renew" > "$KIBANA_DEV_CONF"
    echo "OBLT_CLUSTER_NAME=\"$name\"" >> "$KIBANA_DEV_CONF"
  fi
  echo "${GREEN}✓${NC} Saved cluster name to $KIBANA_DEV_CONF"
}

cmd_renew() {
  local cluster_name=""
  local save_config=false
  local session_filter=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster-name) cluster_name="$2"; shift 2 ;;
      --session)      session_filter="$2"; shift 2 ;;
      --save)         save_config=true; shift ;;
      *)
        echo "${RED}Error:${NC} Unknown argument '$1'"
        echo "  Usage: ${GREEN}./dev-start.sh renew [--cluster-name <name>] [--session <target>] [--save]${NC}"
        return 1
        ;;
    esac
  done

  # Fall back to saved cluster name from config
  if [[ -z "$cluster_name" ]]; then
    cluster_name="$OBLT_CLUSTER_NAME"
  fi

  # Auto-detect from oblt-cli cluster list
  if [[ -z "$cluster_name" ]] && command -v oblt-cli &>/dev/null; then
    echo "${BLUE}→${NC} No cluster name provided, detecting from oblt-cli..."
    local detected
    detected=$(oblt-cli cluster list 2>&1 | sed -n '/CLUSTER NAME/,$ p' | tail -n +2 | sed 's/[^a-zA-Z0-9 _-]/ /g' | awk 'NF && $1 ~ /[a-z]/ {print $1}')
    local cluster_count
    cluster_count=$(echo "$detected" | grep -c '[a-z]')

    if [[ "$cluster_count" -eq 1 ]]; then
      cluster_name=$(echo "$detected" | grep '[a-z]')
      echo "${GREEN}✓${NC} Found cluster: ${BOLD}$cluster_name${NC}"
    elif [[ "$cluster_count" -gt 1 ]]; then
      echo "${YELLOW}⚠${NC} Multiple clusters found:"
      echo "$detected" | grep '[a-z]' | while read -r c; do
        echo "    $c"
      done
      echo ""
      echo "  Specify which one: ${GREEN}./dev-start.sh renew --cluster-name <name>${NC}"
      return 1
    fi
  fi

  if [[ -z "$cluster_name" ]]; then
    # No cluster found — offer to create one
    if ! command -v oblt-cli &>/dev/null; then
      echo "${RED}Error:${NC} No cluster name provided, auto-detect found nothing, and oblt-cli is not installed."
      echo "  Install it first: ${GREEN}https://github.com/elastic/observability-test-environments${NC}"
      return 1
    fi

    echo "${YELLOW}⚠${NC}  No active cluster found."
    echo ""
    echo "  Command: ${GREEN}$OBLT_CLUSTER_CREATE_CMD${NC}"
    echo ""
    offer_cluster_create
    return $?
  fi

  # Check that oblt-cli is available
  if ! command -v oblt-cli &>/dev/null; then
    echo "${RED}Error:${NC} oblt-cli not found in PATH."
    echo "  Install it first: ${GREEN}https://github.com/elastic/observability-test-environments${NC}"
    return 1
  fi

  echo "${BLUE}→${NC} Fetching kibana config from cluster '${BOLD}$cluster_name${NC}'..."

  # Checksum before fetch (to detect if credentials actually changed)
  local old_checksum=""
  if [[ -f "$REMOTE_ES_CONFIG" ]]; then
    old_checksum=$(md5 -q "$REMOTE_ES_CONFIG" 2>/dev/null || md5sum "$REMOTE_ES_CONFIG" 2>/dev/null | awk '{print $1}')
  fi

  # Fetch fresh kibana config from oblt-cli
  if ! oblt-cli cluster secrets kibana-config \
    --cluster-name "$cluster_name" \
    --output-file "$REMOTE_ES_CONFIG" 2>/dev/null; then
    echo "${RED}Error:${NC} Failed to fetch kibana config for cluster '$cluster_name'."
    echo "  (The cluster may have been destroyed, or credentials have expired.)"
    echo ""

    # Before offering to create, check if a different cluster is already running
    local fallback_detected
    fallback_detected=$(oblt-cli cluster list 2>&1 | sed -n '/CLUSTER NAME/,$ p' | tail -n +2 | sed 's/[^a-zA-Z0-9 _-]/ /g' | awk 'NF && $1 ~ /[a-z]/ {print $1}')
    local fallback_count
    fallback_count=$(echo "$fallback_detected" | grep -c '[a-z]')

    if [[ "$fallback_count" -eq 1 ]]; then
      local fallback_name
      fallback_name=$(echo "$fallback_detected" | grep '[a-z]')
      if [[ "$fallback_name" != "$cluster_name" ]]; then
        echo "${GREEN}✓${NC} Found a different active cluster: ${BOLD}$fallback_name${NC}"
        save_cluster_name_to_conf "$fallback_name"
        cmd_renew --cluster-name "$fallback_name"
        return $?
      fi
    elif [[ "$fallback_count" -gt 1 ]]; then
      echo "  Multiple clusters found — specify which one:"
      echo "$fallback_detected" | grep '[a-z]' | while read -r c; do
        echo "    ${GREEN}$c${NC}"
      done
      echo ""
      echo "  Run: ${GREEN}./dev-start.sh renew --cluster-name <name>${NC}"
      return 1
    fi

    echo "  Or check your Google Cloud auth:"
    echo "    ${GREEN}gcloud auth login${NC}"
    echo ""
    offer_cluster_create
    return $?
  fi

  # Compare checksums to see if credentials actually changed
  local new_checksum=""
  new_checksum=$(md5 -q "$REMOTE_ES_CONFIG" 2>/dev/null || md5sum "$REMOTE_ES_CONFIG" 2>/dev/null | awk '{print $1}')
  local credentials_changed=true
  if [[ -n "$old_checksum" && "$old_checksum" == "$new_checksum" ]]; then
    credentials_changed=false
    echo "${GREEN}✓${NC} Credentials unchanged — already using this cluster."
  else
    echo "${GREEN}✓${NC} Remote ES config updated: $REMOTE_ES_CONFIG"
  fi

  # Save cluster name to config if requested
  if [[ "$save_config" == true ]]; then
    save_cluster_name_to_conf "$cluster_name"
    echo "  Next time you can just run: ${GREEN}./dev-start.sh renew${NC}"
  fi

  # Regenerate kibana.dev.yml for active remote sessions
  # Run even when credentials_changed=false — a session may still point to a
  # different (old) cluster and need its kibana.dev.yml regenerated.
  {
    local regenerated=()
    local skipped=()
    local up_to_date=()

    # --session filter: resolve target to match against session labels
    # "main" → kibana-main, "feat" → kibana-feat, "<name>" → kibana-<name>
    # Empty means all remote sessions (original behaviour).
    local filter_label=""
    if [[ -n "$session_filter" ]]; then
      case "$session_filter" in
        main) filter_label="kibana-main" ;;
        feat) filter_label="kibana-feat" ;;
        *)    filter_label="kibana-$(echo "$session_filter" | sed 's|.*/||' | tr '.' '-')" ;;
      esac
    fi

    # Helper: should we process this session?
    should_process() {
      [[ -z "$filter_label" ]] || [[ "$1" == "$filter_label" ]]
    }

    # Get the new cluster's ES version for compatibility checks.
    # If we can't determine it, regenerate all sessions (safe default — same as before).
    local new_es_host new_es_ver new_es_mm
    new_es_host=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
    new_es_ver=$(get_remote_es_version "$new_es_host" "$REMOTE_ES_CONFIG")
    new_es_mm=$(major_minor "$new_es_ver")

    # Helper: check if a session's Kibana version is compatible with the new cluster
    is_session_compatible() {
      local session_dir="$1"
      # If we couldn't get the ES version, assume compatible (regenerate all)
      [[ -z "$new_es_ver" ]] && return 0
      local kbn_ver kbn_mm
      kbn_ver=$(get_kibana_version "$session_dir")
      [[ -z "$kbn_ver" ]] && return 0  # can't determine — assume compatible
      kbn_mm=$(major_minor "$kbn_ver")
      [[ "$kbn_mm" == "$new_es_mm" ]]
    }

    # Helper: check if a session's kibana.dev.yml points to a different ES host
    # than the current remote config (i.e. it was created against an older cluster).
    # Returns 0 (true) if the session needs regenerating, 1 if already up-to-date.
    is_session_stale() {
      local yml_path="$1"
      [[ "$credentials_changed" == true ]] && return 0  # global creds changed → always regenerate
      local session_host
      session_host=$(grep -E "^ *hosts:" "$yml_path" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')
      [[ -z "$session_host" ]] && return 0  # can't determine — regenerate to be safe
      [[ "$session_host" != "$new_es_host" ]]
    }

    # Check kibana-main
    if should_process "kibana-main" && \
       [[ -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]] && \
       grep -q "Remote ES" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null; then
      if ! is_session_stale "$KIBANA_MAIN_DIR/config/kibana.dev.yml"; then
        up_to_date+=("kibana-main")
      elif is_session_compatible "$KIBANA_MAIN_DIR"; then
        local main_port
        main_port=$(grep -E "^ *port:" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
        generate_remote_kibana_dev_yml "$KIBANA_MAIN_DIR" "${main_port:-$MAIN_KIBANA_PORT}"
        regenerated+=("kibana-main")
      else
        local skip_ver
        skip_ver=$(get_kibana_version "$KIBANA_MAIN_DIR")
        skipped+=("kibana-main (Kibana ${skip_ver:-unknown})")
      fi
    fi

    # Check kibana-feat
    if should_process "kibana-feat" && [[ -f "$STATE_FILE" ]]; then
      source "$STATE_FILE"
      if [[ -n "${FEAT_DIR:-}" && -f "$FEAT_DIR/config/kibana.dev.yml" ]] && \
         grep -q "Remote ES" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null; then
        if ! is_session_stale "$FEAT_DIR/config/kibana.dev.yml"; then
          up_to_date+=("kibana-feat")
        elif is_session_compatible "$FEAT_DIR"; then
          local feat_port
          feat_port=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
          generate_remote_kibana_dev_yml "$FEAT_DIR" "${feat_port:-$FEAT_KIBANA_PORT}"
          regenerated+=("kibana-feat")
        else
          local skip_ver_feat
          skip_ver_feat=$(get_kibana_version "$FEAT_DIR")
          skipped+=("kibana-feat (Kibana ${skip_ver_feat:-unknown})")
        fi
      fi
    fi

    # Check hotfix sessions
    # Note: declare locals before the loop — zsh prints values if `local` is
    # called again on an already-declared variable (second iteration onwards).
    local wt_dir wt_name wt_session_name wt_port wt_skip_ver
    for yml in "$WORKTREE_BASE"/*/config/kibana.dev.yml; do
      [[ -f "$yml" ]] || continue
      grep -q "Remote ES" "$yml" 2>/dev/null || continue
      wt_dir=$(dirname "$(dirname "$yml")")
      wt_name=$(basename "$wt_dir")
      wt_session_name="kibana-$(echo "$wt_name" | tr '.' '-')"
      # Skip feat worktree (already handled above)
      [[ -n "${FEAT_DIR:-}" && "$wt_dir" == "$FEAT_DIR" ]] && continue
      should_process "$wt_session_name" || continue
      if ! is_session_stale "$yml"; then
        up_to_date+=("$wt_session_name")
      elif is_session_compatible "$wt_dir"; then
        wt_port=$(grep -E "^ *port:" "$yml" 2>/dev/null | head -1 | awk '{print $2}')
        generate_remote_kibana_dev_yml "$wt_dir" "${wt_port}"
        regenerated+=("$wt_session_name")
      else
        wt_skip_ver=$(get_kibana_version "$wt_dir")
        skipped+=("$wt_session_name (Kibana ${wt_skip_ver:-unknown})")
      fi
    done

    if [[ ${#regenerated[@]} -gt 0 ]]; then
      echo ""
      echo "${GREEN}✓${NC} Regenerated kibana.dev.yml for remote sessions:"
      for s in "${regenerated[@]}"; do
        echo "  ${BLUE}↳${NC} $s"
      done
      echo ""
      echo "  Run ${GREEN}./dev-start.sh restart <session>${NC} to pick up the new credentials."
    elif [[ -n "$session_filter" && ${#skipped[@]} -eq 0 && ${#up_to_date[@]} -eq 0 ]]; then
      echo ""
      echo "${YELLOW}⚠${NC}  No remote session matched '${session_filter}'."
      echo "  Is it currently using remote ES?  Check with: ${GREEN}./dev-start.sh list${NC}"
    fi

    if [[ ${#skipped[@]} -gt 0 ]]; then
      echo ""
      echo "${YELLOW}⚠${NC}  Skipped sessions incompatible with new cluster (ES ${new_es_ver}):"
      for s in "${skipped[@]}"; do
        echo "  ${BLUE}↳${NC} $s"
      done
    fi

    if [[ ${#up_to_date[@]} -gt 0 && ${#regenerated[@]} -eq 0 && ${#skipped[@]} -eq 0 ]]; then
      echo ""
      echo "${GREEN}✓${NC} All remote sessions already point to this cluster."
    fi
  }

  # ── Health check: verify the remote ES cluster is actually reachable ──
  local es_host_url
  es_host_url=$(grep -E "^ *hosts:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | sed 's|.*hosts: *||' | tr -d '"' | tr -d ' ')

  if [[ -n "$es_host_url" ]]; then
    local es_http
    es_http=$(curl -s -o /dev/null -w "%{http_code}" "$es_host_url" --max-time 10 2>/dev/null)
    [[ -z "$es_http" ]] && es_http="000"

    # Some Elastic Cloud deployments return 503 for unauthenticated requests
    # instead of 401. Fall back to an authenticated request before giving up.
    if [[ "$es_http" != "200" && "$es_http" != "401" && "$es_http" != "000" ]]; then
      local es_user es_pass
      es_user=$(grep -E "^ *username:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
      es_pass=$(grep -E "^ *password:" "$REMOTE_ES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d ' ')
      if [[ -n "$es_user" && -n "$es_pass" ]]; then
        local es_http_auth
        es_http_auth=$(curl -s -o /dev/null -w "%{http_code}" -u "${es_user}:${es_pass}" "$es_host_url" --max-time 10 2>/dev/null)
        if [[ "$es_http_auth" == "200" ]]; then
          es_http="200"
        fi
      fi
    fi

    if [[ "$es_http" == "200" || "$es_http" == "401" ]]; then
      echo "${GREEN}✓${NC} Cluster health: reachable (HTTP $es_http)"

      # ── Version check: detect ES ↔ Kibana major.minor mismatch ──
      local es_version
      es_version=$(get_remote_es_version "$es_host_url" "$REMOTE_ES_CONFIG")
      if [[ -n "$es_version" ]]; then
        local es_mm kbn_version kbn_mm
        es_mm=$(major_minor "$es_version")
        kbn_version=$(get_kibana_version "$KIBANA_MAIN_DIR")
        kbn_mm=$(major_minor "$kbn_version")
        if [[ -n "$kbn_version" && -n "$es_mm" && "$es_mm" != "$kbn_mm" ]]; then
          # Check if ignoreVersionMismatch is enabled (in remote config or main session yml)
          local ignore_mismatch=false
          if grep -q "ignoreVersionMismatch.*true" "$REMOTE_ES_CONFIG" 2>/dev/null || \
             grep -q "ignoreVersionMismatch.*true" "$KIBANA_MAIN_DIR/config/kibana.dev.yml" 2>/dev/null; then
            ignore_mismatch=true
          fi
          if [[ "$ignore_mismatch" == true ]]; then
            echo "${BLUE}ℹ${NC}  Version note: ES ${es_version} ↔ Kibana ${kbn_version} (ignoreVersionMismatch enabled)"
          else
            echo ""
            handle_version_mismatch "$es_version" "$cluster_name" "$es_host_url"
          fi
        else
          echo "${GREEN}✓${NC} Version check: ES ${es_version} ↔ Kibana ${kbn_version:-unknown}"
        fi
      fi
    else
      if [[ "$es_http" == "000" ]]; then
        echo "${RED}✗${NC} Cluster health: ${RED}unreachable${NC} — $es_host_url"
      else
        echo "${YELLOW}⚠${NC}  Cluster health: ${YELLOW}unhealthy${NC} (HTTP $es_http) — $es_host_url"
      fi
      echo ""
      echo "  The cluster may be down or destroyed."
      echo "  Check with: ${GREEN}oblt-cli cluster list${NC}"
      echo "  Destroy:    ${GREEN}oblt-cli cluster destroy --cluster-name $cluster_name${NC}"
      echo "  Create new: ${GREEN}./dev-start.sh renew${NC}  (after destroying the old one)"
    fi
  fi

  echo ""
  echo "${GREEN}Done!${NC} Use ${GREEN}--remote${NC} to connect:"
  echo "  ${GREEN}./dev-start.sh switch <branch> --remote${NC}"
}

cmd_clean() {
  local target="${1:-}"

  if [[ -z "$target" ]]; then
    echo ""
    echo "${BOLD}ES data folders in $ES_DATA_BASE:${NC}"
    if [[ -d "$ES_DATA_BASE" ]]; then
      local total_size
      total_size=$(du -sh "$ES_DATA_BASE" 2>/dev/null | awk '{print $1}')
      for folder in "$ES_DATA_BASE"/*/; do
        [[ -d "$folder" ]] || continue
        local name size
        name=$(basename "$folder")
        size=$(du -sh "$folder" 2>/dev/null | awk '{print $1}')
        echo "  ${BLUE}↳${NC} $name  ($size)"
      done
      echo ""
      echo "  Total: $total_size"
    else
      echo "  ${YELLOW}(no ES data directory found)${NC}"
    fi
    echo ""
    echo "Usage:"
    echo "  ${GREEN}./dev-start.sh clean main${NC}     → delete main-cluster data"
    echo "  ${GREEN}./dev-start.sh clean feat${NC}     → delete feat worktree data"
    echo "  ${GREEN}./dev-start.sh clean <name>${NC}   → delete specific data folder"
    echo "  ${GREEN}./dev-start.sh clean all${NC}      → delete ALL ES data"
    echo ""
    return
  fi

  local folder_name
  case "$target" in
    main)
      folder_name="$MAIN_DATA_FOLDER"
      ;;
    feat)
      if [[ -f "$STATE_FILE" ]]; then
        source "$STATE_FILE"
        folder_name=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
      else
        echo "${RED}Error:${NC} No feat state found. Provide the folder name directly."
        echo "  Run ${GREEN}./dev-start.sh clean${NC} to see available folders."
        return 1
      fi
      ;;
    all)
      if [[ -d "$ES_DATA_BASE" ]]; then
        local total_size
        total_size=$(du -sh "$ES_DATA_BASE" 2>/dev/null | awk '{print $1}')
        echo "${BLUE}→${NC} Removing ALL ES data ($total_size)..."
        rm -rf "$ES_DATA_BASE"
        echo "${GREEN}✓${NC} All ES data deleted. Clusters will start fresh."
      else
        echo "${YELLOW}⚠${NC} No ES data directory found at $ES_DATA_BASE"
      fi
      return
      ;;
    *)
      folder_name="$target"
      ;;
  esac

  local data_dir="$ES_DATA_BASE/$folder_name"
  if [[ -d "$data_dir" ]]; then
    local size
    size=$(du -sh "$data_dir" 2>/dev/null | awk '{print $1}')
    echo "${BLUE}→${NC} Removing ES data for '$folder_name' ($size)..."
    rm -rf "$data_dir"
    echo "${GREEN}✓${NC} Deleted $data_dir — ES will start with a fresh cluster."
  else
    echo "${YELLOW}⚠${NC} No data folder found at $data_dir"
    echo "  Run ${GREEN}./dev-start.sh clean${NC} to see available folders."
  fi
}

cmd_main() {
  if [[ ! -f "$KBN_START" ]]; then
    echo "${RED}Error:${NC} kbn-start.sh not found at $KBN_START"
    echo ""
    echo "  Install it first:"
    echo "    mkdir -p ~/bin"
    echo "    cp kbn-start.sh ~/bin/kbn-start.sh"
    echo "    chmod +x ~/bin/kbn-start.sh"
    exit 1
  fi

  load_feat_state

  # kibana-main
  if ! tmux has-session -t "kibana-main" 2>/dev/null; then
    echo "${BLUE}→${NC} Creating ${BOLD}kibana-main${NC}  Kibana :$MAIN_KIBANA_PORT  ES :$MAIN_ES_PORT..."
    [[ ! -f "$KIBANA_MAIN_DIR/config/kibana.dev.yml" ]] && \
      generate_kibana_dev_yml "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT"
    generate_cursor_mcp_json "$KIBANA_MAIN_DIR" "$MAIN_KIBANA_PORT" "$MAIN_HOST"
    tmux new-session -d -s "kibana-main" -c "$KIBANA_MAIN_DIR"
    build_kibana_session "kibana-main" "$KIBANA_MAIN_DIR" \
      "$MAIN_KIBANA_PORT" "$MAIN_ES_PORT" "$MAIN_HOST" "$MAIN_DATA_FOLDER"
    echo "${GREEN}✓${NC} Session: kibana-main"
  else
    echo "${YELLOW}↩${NC} Session kibana-main already running, skipping."
  fi

  # kibana-feat
  if ! tmux has-session -t "kibana-feat" 2>/dev/null; then
    local feat_short
    feat_short=$(echo "$FEAT_BRANCH" | sed 's|.*/||')
    echo "${BLUE}→${NC} Creating ${BOLD}kibana-feat${NC} ($FEAT_BRANCH)  Kibana :$FEAT_KIBANA_PORT  ES :$FEAT_ES_PORT..."
    if [[ -f "$FEAT_DIR/config/kibana.dev.yml" ]]; then
      local existing_k existing_es
      existing_k=$(grep -E "^ *port:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | awk '{print $2}')
      existing_es=$(grep -E "^ *- \"?http://localhost:" "$FEAT_DIR/config/kibana.dev.yml" 2>/dev/null | head -1 | sed 's|.*http://localhost:||' | tr -d ' "')
      if { [[ -n "$existing_k" && "$existing_k" != "$FEAT_KIBANA_PORT" ]] || \
           [[ -n "$existing_es" && "$existing_es" != "$FEAT_ES_PORT" ]]; }; then
        echo "${YELLOW}⚠${NC} kibana.dev.yml has wrong ports (Kibana: $existing_k, ES: $existing_es) — regenerating..."
        generate_kibana_dev_yml "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
      fi
    else
      generate_kibana_dev_yml "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT"
    fi
    generate_cursor_mcp_json "$FEAT_DIR" "$FEAT_KIBANA_PORT" "$FEAT_HOST"
    tmux new-session -d -s "kibana-feat" -c "$FEAT_DIR"
    build_kibana_session "kibana-feat" "$FEAT_DIR" \
      "$FEAT_KIBANA_PORT" "$FEAT_ES_PORT" "$FEAT_HOST" "$feat_short"
    echo "${GREEN}✓${NC} Session: kibana-feat"
  else
    echo "${YELLOW}↩${NC} Session kibana-feat already running, skipping."
  fi

  # ── Recover orphaned worktree sessions ──
  recover_orphaned_sessions

  echo ""
  echo "${GREEN}✓${NC} All sessions ready:"
  echo "   kibana-feat  ($FEAT_BRANCH)"
  echo "     Kibana  → http://localhost:${FEAT_KIBANA_PORT}"
  echo "     Cursor  → KIBANA_URL=http://${FEAT_HOST}:${FEAT_KIBANA_PORT}"
  echo "   kibana-main"
  echo "     Kibana  → http://localhost:${MAIN_KIBANA_PORT}"
  echo "     Cursor  → KIBANA_URL=http://${MAIN_HOST}:${MAIN_KIBANA_PORT}"
  echo ""
  echo "  Kibana auto-starts in each session once ES is ready."
  echo ""
  echo "  ${BOLD}Ctrl-a s${NC}  → session switcher"
  echo "  ${BOLD}Ctrl-a w${NC}  → window overview"
  echo ""

  tmux_attach "kibana-feat"
}
# ── END COMMANDS ──────────────────────────────────────────


# ── FIRST-RUN DETECTION ───────────────────────────────────
# If no config file and not running setup/help, nudge the user
if [[ ! -f "$KIBANA_DEV_CONF" && "${1:-main}" != "setup" && "${1:-main}" != "renew" && "${1:-main}" != "restart" && "${1:-main}" != "help" && "${1:-}" != "--help" ]]; then
  echo ""
  echo "${YELLOW}⚠${NC}  No config file found. Run the setup wizard to configure paths and ports:"
  echo "     ${GREEN}./dev-start.sh setup${NC}"
  echo ""
  echo "   Using defaults for now. Press Ctrl-C to cancel, or wait to continue..."
  sleep 3
fi

# ── ROUTER ────────────────────────────────────────────────
case "${1:-main}" in
  main)        cmd_main ;;
  setup)       cmd_setup ;;
  restart)     shift; cmd_restart "$@" ;;
  renew)       shift; cmd_renew "$@" ;;
  switch)      shift; cmd_switch "$@" ;;
  new)         shift; cmd_new "$@" ;;
  attach)      cmd_attach "$2" ;;
  list)        cmd_list ;;
  status)      cmd_status ;;
  sync)        shift; cmd_sync "$@" ;;
  clean)       cmd_clean "$2" ;;
  kill)        cmd_kill "$2" ;;
  kill-all)    cmd_kill_all ;;
  recover)     cmd_recover ;;
  prune)       cmd_prune ;;
  help|--help) print_help ;;
  *)
    echo "${RED}Unknown command:${NC} $1"
    print_help
    exit 1
    ;;
esac
