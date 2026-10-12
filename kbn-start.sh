#!/usr/bin/env bash
# ============================================================
#  kbn-start.sh — Bootstrap + start ES, then auto-launch Kibana
#                 once ES is ready.
#
#  Called automatically by dev-start.sh. Run from the LEFT pane
#  of a servers window. Kibana fires in the RIGHT pane once ES
#  reports ready.
#
#  USAGE:
#    kbn-start.sh [data-folder] [-E key=value ...]
#                 [--kibana-port N] [--es-port N] [--host hostname]
#
#  ENVIRONMENT:
#    KBN_EXTRA_ARGS  — extra flags appended to `yarn start` / `pnpm start`
#                      (package manager is auto-detected per worktree)
#                      (set in ~/.kibana-dev.conf to persist across launches)
#
#  EXAMPLES:
#    kbn-start.sh main-cluster --kibana-port 5602 --es-port 9201 --host kibana-main.local
#    kbn-start.sh feat-cluster --kibana-port 5601 --es-port 9200 --host kibana-feat.local
#    kbn-start.sh slo-crash    --kibana-port 5603 --es-port 9202
#    KBN_EXTRA_ARGS="--mockIdpPlugin.enabled=false" kbn-start.sh main
# ============================================================
set -euo pipefail

# ── User config (same file as dev-start.sh) ──────────────
KIBANA_DEV_CONF="$HOME/.kibana-dev.conf"
[[ -f "$KIBANA_DEV_CONF" ]] && source "$KIBANA_DEV_CONF"

ES_DATA_BASE="${ES_DATA_BASE:-$HOME/Documents/Development/es_data}"
TRIGGER_STRING="succ kbn/es setup complete"

# ── DEFAULTS ──────────────────────────────────────────────
ES_DATA_FOLDER="main-cluster"
KIBANA_PORT=5601
ES_PORT=9200
KIBANA_HOST="localhost"
ES_FLAGS=""
KBN_EXTRA_ARGS="${KBN_EXTRA_ARGS:-}"
# ── END DEFAULTS ──────────────────────────────────────────

# ── ARGUMENT PARSING ──────────────────────────────────────
if [[ $# -gt 0 && "$1" != -* ]]; then
  ES_DATA_FOLDER="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kibana-port) KIBANA_PORT="$2";  shift 2 ;;
    --es-port)     ES_PORT="$2";      shift 2 ;;
    --host)        KIBANA_HOST="$2";  shift 2 ;;
    -E)
      if [[ $# -gt 1 ]]; then
        ES_FLAGS="$ES_FLAGS -E $2"; shift 2
      else
        echo "Error: -E requires a value" >&2; exit 1
      fi
      ;;
    *)
      echo "Error: Unknown argument '$1'" >&2
      echo "Usage: kbn-start.sh [data-folder] [-E key=value ...] [--kibana-port N] [--es-port N] [--host hostname]" >&2
      exit 1
      ;;
  esac
done

ES_DATA_PATH="$ES_DATA_BASE/$ES_DATA_FOLDER"
LOGFILE="/tmp/es-${ES_DATA_FOLDER}.log"
ES_TRANSPORT_PORT=$((ES_PORT + 100))
# ── END ARGUMENT PARSING ──────────────────────────────────


# ── TMUX PANE DETECTION ───────────────────────────────────
# $TMUX_PANE is set by tmux to the pane ID where this script is actually running.
# This is more reliable than display-message which reports the *focused* pane
# (which can differ from the executing pane when launched via tmux send-keys).
TMUX_CURRENT_PANE="${TMUX_PANE}"
TMUX_CURRENT_INDEX=$(tmux list-panes -t "$TMUX_CURRENT_PANE" -F '#{pane_id} #{pane_index}' | awk -v id="$TMUX_CURRENT_PANE" '$1 == id { print $2 }')

# Find the next pane (with a higher index) to use as the Kibana pane
TMUX_TARGET_PANE=$(tmux list-panes -t "$TMUX_CURRENT_PANE" -F '#{pane_index} #{pane_id}' | awk -v current="$TMUX_CURRENT_INDEX" '
  $1 > current {
    if (target == "" || $1 < best) { target = $2; best = $1 }
  }
  END { if (target != "") print target }
')

# Fallback: any pane that isn't the current one
if [[ -z "${TMUX_TARGET_PANE:-}" ]]; then
  TMUX_TARGET_PANE=$(tmux list-panes -t "$TMUX_CURRENT_PANE" -F '#{pane_id}' | awk -v current="$TMUX_CURRENT_PANE" '
    $1 != current { print $1; exit }
  ')
fi

# Last resort: use the current pane (single-pane window)
if [[ -z "${TMUX_TARGET_PANE:-}" ]]; then
  TMUX_TARGET_PANE="$TMUX_CURRENT_PANE"
fi
# ── END TMUX PANE DETECTION ───────────────────────────────


echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  kbn-start                                          │"
echo "  │  ES     → http://localhost:${ES_PORT}                    │"
echo "  │  Kibana → http://${KIBANA_HOST}:${KIBANA_PORT}           │"
echo "  │  Data   → ${ES_DATA_PATH}     │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""

echo "▶ Switching node version..."
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

# ── Package manager (yarn vs pnpm) ────────────────────────
# Newer Kibana branches (e.g. 9.5.x) use pnpm; older ones (e.g. 9.6.0 at the time
# of writing) still use yarn. Decide per worktree: pnpm when package.json declares
# "packageManager": "pnpm@..." or a pnpm-lock.yaml exists, otherwise yarn.
# (Same logic lives in dev-start.sh for the FTR windows — keep them in sync.)
PM="yarn"
if grep -qE '"packageManager" *: *"pnpm@' package.json 2>/dev/null || [[ -f pnpm-lock.yaml ]]; then
  PM="pnpm"
  # pnpm ships via Corepack; shims are per Node version, so enable it if missing.
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "▶ pnpm not found — running corepack enable..."
    corepack enable
  fi
fi

echo "▶ Running ${PM} kbn bootstrap..."
${PM} kbn bootstrap

# ── Detect remote ES from kibana.dev.yml ──────────────────
KIBANA_DEV_YML="config/kibana.dev.yml"
USE_REMOTE_ES=false
if [[ -f "$KIBANA_DEV_YML" ]]; then
  # Match both formats:
  #   Template format:  elasticsearch.hosts:\n  - "http://..."
  #   oblt-cli format:  elasticsearch:\n  hosts: https://...
  ES_HOST_LINE=$(grep -E "^ *(- \"?|hosts: *)https?://" "$KIBANA_DEV_YML" 2>/dev/null \
    | grep -v "localhost" \
    | grep -v "127\.0\.0\.1" \
    | head -1 \
    | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' ' || true)
  if [[ -n "$ES_HOST_LINE" ]]; then
    USE_REMOTE_ES=true
  fi
fi

if [[ "$USE_REMOTE_ES" == true ]]; then
  echo "▶ Remote ES detected: ${ES_HOST_LINE}"
  echo "  Skipping local ES — starting Kibana directly..."
  echo ""
  tmux send-keys -t "$TMUX_TARGET_PANE" \
    "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use" \
    C-m
  sleep 2
  tmux send-keys -t "$TMUX_TARGET_PANE" \
    "${PM} start --no-base-path --host=${KIBANA_HOST} --port=${KIBANA_PORT} ${KBN_EXTRA_ARGS}" \
    C-m
  echo "✅  Kibana starting on http://${KIBANA_HOST}:${KIBANA_PORT} → ES: ${ES_HOST_LINE}"
  echo "    (ES host is configured in ${KIBANA_DEV_YML})"
else
  echo "▶ Starting local ES... (Kibana will auto-start once ES is ready)"
  (
    tail -n 0 -F "$LOGFILE" | while read -r line; do
      if [[ "$line" == *"$TRIGGER_STRING"* ]]; then
        tmux send-keys -t "$TMUX_TARGET_PANE" \
          "export NVM_DIR=\"\$HOME/.nvm\" && [[ -s \"\$NVM_DIR/nvm.sh\" ]] && source \"\$NVM_DIR/nvm.sh\" && nvm use" \
          C-m
        sleep 2
        tmux send-keys -t "$TMUX_TARGET_PANE" \
          "${PM} start --no-base-path --host=${KIBANA_HOST} --port=${KIBANA_PORT} --elasticsearch.hosts=http://localhost:${ES_PORT} ${KBN_EXTRA_ARGS}" \
          C-m
        break
      fi
    done
  ) &

  ${PM} es snapshot \
    --license trial \
    -E node.name="${ES_DATA_FOLDER}" \
    -E http.port="${ES_PORT}" \
    -E transport.port="${ES_TRANSPORT_PORT}" \
    -E discovery.type=single-node \
    -E path.data="${ES_DATA_PATH}" \
    ${ES_FLAGS} \
    2>&1 | tee -a "$LOGFILE"
fi
