#!/usr/bin/env zsh
# ============================================================
#  run-data.sh — data ingestion helpers for Kibana dev
#
#  USAGE:
#    run-data slo [good|bad|mixed]            → ingest SLO fake_stack data (default: good)
#    run-data synthetics                     → create synthetics private location
#    run-data synthetics monitors            → create ~40 monitors + mock data (idempotent, uses existing locations)
#    run-data synthetics monitors --minimal → create 4 monitors (1 per type) + mock data
#    run-data synthetics monitors --allow-unenrolled → also use private locations with no enrolled agent (no Docker needed)
#    run-data synthetics break <scenario>    → trigger a Synthetics failure scenario
#    run-data synthetics fix <scenario>      → restore from a failure scenario
#    run-data synthetics fix public-locations → migrate monitors off broken public locations
#    run-data synthetics reset               → wipe all Fleet + Synthetics state
#
#  Reads Kibana port and ES host from config/kibana.dev.yml automatically.
#  Works with both local ES (localhost) and remote ES (oblt-cli / cloud).
#  Must be run from a Kibana repo directory (worktree or main checkout).
# ============================================================

# ── Guard: must be inside a Kibana repo ───────────────────
if [[ ! -f ".nvmrc" ]] || [[ ! -f "package.json" ]]; then
  echo "❌  Must be run from a Kibana repo directory (worktree or main checkout)."
  echo "    e.g. cd ~/Documents/Development/worktrees/<branch>"
  exit 1
fi

YML="config/kibana.dev.yml"
if [[ ! -f "$YML" ]]; then
  echo "❌  $YML not found. Run dev-start.sh to generate it."
  exit 1
fi

# ── Read Kibana port from config ──────────────────────────
KIBANA_PORT=$(grep -E "^ *port:" "$YML" 2>/dev/null | head -1 | awk '{print $2}')
if [[ -z "$KIBANA_PORT" ]]; then
  echo "❌  Could not read Kibana port from $YML."
  exit 1
fi

# ── Read ES host from config (local or remote) ───────────
# Match both formats:
#   Template format:  elasticsearch.hosts:\n  - "http://..."
#   oblt-cli format:  elasticsearch:\n  hosts: https://...
ES_HOST=$(grep -E "^ *(- \"?|hosts: *)https?://" "$YML" 2>/dev/null | head -1 | sed 's|^ *- *||; s|^ *hosts: *||' | tr -d '"' | tr -d ' ')
if [[ -z "$ES_HOST" ]]; then
  echo "❌  Could not read ES host from $YML."
  exit 1
fi

# ── Read ES password from config ──────────────────────────
# Supports both flat keys (elasticsearch.password:) and nested (password: under elasticsearch:)
ES_PASSWORD=$(grep -E "^ *(elasticsearch\.)?password:" "$YML" 2>/dev/null \
  | grep -v "^#" | grep -v "kibana.password" \
  | head -1 | sed 's|.*password: *||' | tr -d '"' | tr -d ' ')

# Defaults for local dev
ES_PASSWORD="${ES_PASSWORD:-changeme}"

# Detect if remote ES (not localhost)
IS_REMOTE=false
if [[ "$ES_HOST" != *"localhost"* && "$ES_HOST" != *"127.0.0.1"* ]]; then
  IS_REMOTE=true
fi

# For data ingestion we default to the "elastic" superuser — service accounts
# like kibana_system_user can't write data indices. Override via env for
# clusters whose superuser isn't `elastic`: oblt-cli clusters use `admin`
# (see `loginAssistanceMessage` in config/kibana.dev.yml), and the config's
# elasticsearch.password is kibana_system_user's, not the superuser's — so
# without this override the heartbeat/API-key calls 401 on a remote cluster.
#   e.g. DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data ...
DATA_USERNAME="${DATA_USERNAME:-elastic}"
DATA_PASSWORD="${DATA_PASSWORD:-$ES_PASSWORD}"

echo "📋  Config from $YML:"
echo "    Kibana → http://localhost:${KIBANA_PORT}"
echo "    ES     → ${ES_HOST}"
echo "    User   → ${DATA_USERNAME}"
if [[ "$IS_REMOTE" == true ]]; then
  echo "    Mode   → 🌐 Remote ES (concurrency reduced)"
fi
echo ""

# ── NVM setup ─────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
nvm use

# ── Wait for Kibana to be ready ───────────────────────────
wait_for_kibana() {
  local url="http://localhost:${KIBANA_PORT}/api/status"
  echo "⏳  Waiting for Kibana on port ${KIBANA_PORT}..."
  while ! curl -s -o /dev/null -w "%{http_code}" -u "${DATA_USERNAME}:${DATA_PASSWORD}" "$url" 2>/dev/null | grep -q "200"; do
    sleep 5
  done
  echo "✅  Kibana is ready on port ${KIBANA_PORT}."
}

# ── Commands ──────────────────────────────────────────────
case "$1" in
  slo)
    wait_for_kibana
    # Use gentler settings for remote ES to avoid timeouts
    local epc=50 payload=10000 conc=5
    if [[ "$IS_REMOTE" == true ]]; then
      epc=10 payload=1000 conc=1
    fi
    # Optional second arg: good (default), bad, mixed
    local template="${2:-good}"
    if [[ "$template" != "good" && "$template" != "bad" && "$template" != "mixed" ]]; then
      echo "❌  Unknown event template: $template. Use: good, bad, mixed"
      exit 1
    fi
    echo "📊  SLO data template: $template"
    node x-pack/scripts/data_forge.js \
      --events-per-cycle "$epc" \
      --lookback now-1d \
      --dataset fake_stack \
      --event-template "$template" \
      --payload-size "$payload" \
      --concurrency "$conc" \
      --kibana-url "http://localhost:${KIBANA_PORT}" \
      --kibana-username "${DATA_USERNAME}" \
      --kibana-password "${DATA_PASSWORD}" \
      --elasticsearch-host "${ES_HOST}" \
      --elasticsearch-username "${DATA_USERNAME}" \
      --elasticsearch-password "${DATA_PASSWORD}"
    ;;

  synthetics)
    wait_for_kibana
    local KIBANA_URL="http://localhost:${KIBANA_PORT}"
    local AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"
    local ES_AUTH="${DATA_USERNAME}:${DATA_PASSWORD}"

    # ── Helpers for synthetics break/fix ──────────────────────

    _synth_extract() {
      echo "$1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = $2
    for item in items:
        val = item.get('$3', '')
        if val:
            print(val)
except: pass
" 2>/dev/null
    }

    # Helper: run a command with a hard timeout (macOS has no `timeout` by default).
    # A wedged container/daemon can make docker calls hang forever; this kills the client call.
    _rd_timeout() {
      setopt local_options no_monitor no_notify
      local secs=$1; shift
      "$@" &
      local pid=$!
      ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
      local watcher=$!
      wait "$pid" 2>/dev/null
      local rc=$?
      kill "$watcher" 2>/dev/null
      wait "$watcher" 2>/dev/null
      return $rc
    }

    _synth_find_agent() {
      curl -s "$KIBANA_URL/api/fleet/agents?perPage=100" \
        -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('items', []):
    if a.get('policy_id') != 'fleet-server-policy':
        print(a['id']); break
" 2>/dev/null
    }

    _synth_find_private_location() {
      curl -s "$KIBANA_URL/api/synthetics/private_locations" \
        -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
        -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
locs = data if isinstance(data, list) else []
for loc in locs:
    if not loc.get('isServiceManaged', True):
        print(loc['id']); break
" 2>/dev/null
    }

    _synth_find_agent_container() {
      # Find the synthetics agent container (not Fleet Server)
      docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | while read cid cname cimg; do
        if [[ "$cname" != *"fleet"* && "$cname" != *"Fleet"* ]] && \
           [[ "$cimg" == *"elastic-agent"* || "$cname" == *"elastic-agent"* ]]; then
          echo "$cid"; return
        fi
      done
    }

    _synth_find_fleet_container() {
      docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null | while read cid cname; do
        if [[ "$cname" == *"fleet-server"* || "$cname" == *"fleet_server"* ]]; then
          echo "$cid"; return
        fi
      done
    }

    _synth_find_package_policy() {
      curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=10" \
        -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
if items: print(items[0]['id'])
" 2>/dev/null
    }

    _synth_find_private_monitor() {
      curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
        -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
        -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []):
    for loc in m.get('locations', []):
        if not loc.get('isServiceManaged', True):
            print(m['config_id']); exit()
" 2>/dev/null
    }

    # ============================================================
    #  BREAK — inject Synthetics failure scenarios
    # ============================================================
    _synth_break() {
      local scenario="$1"
      case "$scenario" in

        agent-offline)
          echo "💥  Scenario: Agent Offline"
          echo "   Stopping the synthetics agent Docker container..."
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No synthetics agent container found. Is it running?"
            return 1
          fi
          docker stop "$cid"
          echo "   ✅ Container $cid stopped. Agent will appear offline in ~5 min."
          echo "   Restore: run-data synthetics fix agent-offline"
          ;;

        revision-mismatch)
          echo "💥  Scenario: Policy Revision Mismatch"
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No synthetics agent container found."
            return 1
          fi
          echo "   Step 1: Stopping agent container $cid..."
          docker stop "$cid"

          local loc_id
          loc_id=$(_synth_find_private_location)
          if [[ -z "$loc_id" ]]; then
            echo "   ❌ No private location found. Run 'run-data synthetics' first."
            return 1
          fi
          echo "   Step 2: Creating monitor to bump policy revision..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "http",
              "name": "[BREAK] revision-mismatch probe",
              "urls": "https://example.com",
              "schedule": { "number": "10", "unit": "m" },
              "locations": [{ "id": "'"$loc_id"'", "isServiceManaged": false }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -n "$new_id" ]]; then
            echo "   ✅ Monitor $new_id created. Agent stopped on old policy revision → mismatch."
          else
            echo "   ❌ Failed to create monitor: $resp"
          fi
          echo "   Restore: run-data synthetics fix revision-mismatch"
          ;;

        zero-data)
          echo "💥  Scenario: Private Location Monitor with Zero Check Results"
          local cid
          cid=$(_synth_find_agent_container)
          if [[ -n "$cid" ]]; then
            echo "   Stopping agent to prevent data collection..."
            docker stop "$cid"
          fi
          local loc_id
          loc_id=$(_synth_find_private_location)
          if [[ -z "$loc_id" ]]; then
            echo "   ❌ No private location found. Run 'run-data synthetics' first."
            return 1
          fi
          echo "   Creating monitor on private location (agent down → zero data)..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "browser",
              "name": "[BREAK] zero-data monitor",
              "urls": "https://elastic.co",
              "schedule": { "number": "10", "unit": "m" },
              "locations": [{ "id": "'"$loc_id"'", "isServiceManaged": false }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -n "$new_id" ]]; then
            echo "   ✅ Monitor $new_id created with no agent to run it → zero check results."
          else
            echo "   ❌ Failed to create monitor: $resp"
          fi
          echo "   Restore: run-data synthetics fix zero-data"
          ;;

        fleet-degraded)
          echo "💥  Scenario: Fleet Server Degraded"
          local cid
          cid=$(_synth_find_fleet_container)
          if [[ -z "$cid" ]]; then
            echo "   ❌ No Fleet Server container found."
            return 1
          fi
          echo "   Stopping Fleet Server container $cid..."
          docker stop "$cid"
          echo "   ✅ Fleet Server stopped. Agent will show DEGRADED/OFFLINE."
          echo "   Restore: run-data synthetics fix fleet-degraded"
          ;;

        orphaned-data)
          echo "💥  Scenario: Orphaned Monitor Data in ES"
          echo "   Creating temporary monitor on public location..."
          local resp
          resp=$(curl -s -X POST "$KIBANA_URL/api/synthetics/monitors" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -H "Content-Type: application/json" -u "$AUTH" \
            -d '{
              "type": "browser",
              "name": "[BREAK] orphan-data monitor",
              "urls": "https://google.com",
              "schedule": { "number": "3", "unit": "m" },
              "locations": [{ "id": "us_central_qa", "label": "US Central QA", "isServiceManaged": true }]
            }' 2>/dev/null)
          local new_id
          new_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
          if [[ -z "$new_id" ]]; then
            echo "   ❌ Failed to create monitor: $resp"
            return 1
          fi
          echo "   Monitor $new_id created. Waiting 3 minutes for data..."
          local elapsed=0
          while [[ $elapsed -lt 180 ]]; do
            sleep 30
            elapsed=$((elapsed + 30))
            echo "   ⏳ ${elapsed}s / 180s..."
          done
          echo "   Deleting monitor (data stays in ES)..."
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$new_id" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Monitor deleted. Orphaned data remains for monitor.id=$new_id."
          echo "   Restore: run-data synthetics fix orphaned-data"
          ;;

        policy-disabled)
          echo "💥  Scenario: Package Policy Disabled (Monitor-Fleet Desync)"
          local pp_id
          pp_id=$(_synth_find_package_policy)
          if [[ -z "$pp_id" ]]; then
            echo "   ❌ No synthetics package policies found."
            return 1
          fi
          echo "   Disabling package policy $pp_id via Fleet API..."
          local pp_body
          pp_body=$(curl -s "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
item = data.get('item', data)
item['enabled'] = False
for k in ['revision', 'created_at', 'created_by', 'updated_at', 'updated_by',
           'version', 'spaceIds', 'elasticsearch']:
    item.pop(k, None)
json.dump(item, sys.stdout)
" 2>/dev/null)
          if [[ -z "$pp_body" ]]; then
            echo "   ❌ Failed to fetch package policy."
            return 1
          fi
          local put_resp
          put_resp=$(curl -s -X PUT "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" -d "$pp_body" 2>/dev/null)
          if echo "$put_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'item' in d" 2>/dev/null; then
            echo "   ✅ Package policy $pp_id disabled. Monitor still shows enabled in Kibana."
          else
            echo "   ❌ Failed to disable: $(echo "$put_resp" | head -3)"
          fi
          echo "   Restore: run-data synthetics fix policy-disabled"
          ;;

        orphaned-policy)
          echo "💥  Scenario: Orphaned Package Policy"
          local monitor_id
          monitor_id=$(_synth_find_private_monitor)
          if [[ -z "$monitor_id" ]]; then
            echo "   ❌ No private location monitors found."
            return 1
          fi
          echo "   Deleting monitor SO from ES (bypassing Fleet cleanup)..."
          local del_resp
          del_resp=$(curl -s -X POST \
            "$KIBANA_URL/api/console/proxy?path=.kibana*%2F_delete_by_query&method=POST" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" \
            -d '{"query":{"bool":{"should":[
              {"term":{"synthetics-monitor.config_id":"'"$monitor_id"'"}},
              {"term":{"synthetics-monitor-multi-space.config_id":"'"$monitor_id"'"}}
            ]}}}' 2>/dev/null)
          local deleted
          deleted=$(echo "$del_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null)
          echo "   Deleted $deleted SO doc(s) for monitor $monitor_id."
          echo "   ✅ Package policy remains in Fleet but monitor is gone → orphaned."
          echo "   Restore: run-data synthetics fix orphaned-policy"
          ;;

        agent-unenrolled)
          echo "💥  Scenario: Agent Unenrolled (Monitors Still Configured)"
          local agent_id
          agent_id=$(_synth_find_agent)
          if [[ -z "$agent_id" ]]; then
            echo "   ❌ No synthetics agent found."
            return 1
          fi
          echo "   Force-unenrolling agent $agent_id..."
          curl -s -X POST "$KIBANA_URL/api/fleet/agents/$agent_id/unenroll" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" -d '{"force":true,"revoke":true}' > /dev/null 2>&1
          echo "   ✅ Agent unenrolled. Private location has 0 agents but monitors still exist."
          echo "   Restore: run-data synthetics fix agent-unenrolled"
          ;;

        service-disabled)
          echo "💥  Scenario: Synthetics Service Disabled"
          echo "   Disabling Synthetics service (invalidates API key)..."
          curl -s -X DELETE "$KIBANA_URL/internal/synthetics/service/enablement" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Synthetics service disabled. Public location monitors stop syncing."
          echo "   Restore: run-data synthetics fix service-disabled"
          ;;

        all)
          echo "💥💥💥  CHAOS MODE — triggering all failure scenarios"
          echo ""
          for s in agent-offline revision-mismatch zero-data fleet-degraded orphaned-data \
                   policy-disabled orphaned-policy agent-unenrolled service-disabled; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            _synth_break "$s"
            echo ""
          done
          echo "💥💥💥  All scenarios triggered."
          ;;

        help|*)
          echo "Available break scenarios:"
          echo "  agent-offline      Stop the synthetics agent container"
          echo "  revision-mismatch  Stop agent + add monitor (policy rev diverges)"
          echo "  zero-data          Create monitor on private loc with agent down"
          echo "  fleet-degraded     Stop Fleet Server container"
          echo "  orphaned-data      Create + delete monitor (data remains in ES)"
          echo "  policy-disabled    Disable Fleet package policy (monitor still enabled)"
          echo "  orphaned-policy    Delete monitor SO (package policy remains)"
          echo "  agent-unenrolled   Unenroll agent (monitors still configured)"
          echo "  service-disabled   Disable Synthetics service (API key invalidated)"
          echo "  all                Trigger all scenarios (chaos mode)"
          [[ "$scenario" != "help" ]] && return 1
          ;;
      esac
    }

    # ============================================================
    #  FIX — restore from Synthetics failure scenarios
    # ============================================================
    _synth_fix() {
      local scenario="$1"
      shift
      case "$scenario" in

        public-locations)
          echo "🔧  Fix: Broken public Synthetics locations (expired TLS / sync 401)"
          local setup_dir="${0:A:h}"
          QA_BASE_URL="$KIBANA_URL" \
          QA_ADMIN_USERNAME="$DATA_USERNAME" \
          QA_ADMIN_PASSWORD="$DATA_PASSWORD" \
          node "$setup_dir/qa/fix-broken-public-locations.mjs" --reset "$@"
          ;;

        agent-offline)
          echo "🔧  Fix: Agent Offline"
          echo "   Starting stopped elastic-agent containers..."
          local started=0
          for cid in $(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Image}}' 2>/dev/null \
                       | grep elastic-agent | awk '{print $1}'); do
            docker start "$cid"
            started=$((started + 1))
          done
          if [[ $started -gt 0 ]]; then
            echo "   ✅ Started $started container(s). Agent should come online within ~1 min."
          else
            echo "   ⚠ No stopped elastic-agent containers. May need: run-data synthetics"
          fi
          ;;

        revision-mismatch)
          echo "🔧  Fix: Policy Revision Mismatch"
          echo "   Cleaning up [BREAK] monitors..."
          curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []):
    if '[BREAK]' in m.get('name', ''):
        print(m['config_id'])
" 2>/dev/null | while read mid; do
            curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$mid" \
              -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
              -u "$AUTH" > /dev/null 2>&1
            echo "   Deleted monitor $mid"
          done
          echo "   Restarting agent containers..."
          _synth_fix agent-offline
          echo "   ✅ Agent will sync to latest policy revision on next check-in."
          ;;

        zero-data)
          echo "🔧  Fix: Zero Check Results"
          _synth_fix revision-mismatch
          echo "   ✅ Agent will produce data on next schedule interval."
          ;;

        fleet-degraded)
          echo "🔧  Fix: Fleet Server Degraded"
          echo "   Starting stopped Fleet Server containers..."
          local started=0
          for cid in $(docker ps -a --filter "status=exited" --format '{{.ID}} {{.Names}}' 2>/dev/null \
                       | grep -i fleet | awk '{print $1}'); do
            docker start "$cid"
            started=$((started + 1))
          done
          if [[ $started -gt 0 ]]; then
            echo "   ✅ Started $started Fleet Server container(s)."
          else
            echo "   ⚠ No stopped Fleet Server containers. May need: run-data synthetics"
          fi
          ;;

        orphaned-data)
          echo "🔧  Fix: Orphaned Monitor Data"
          echo "   Finding monitor IDs in ES with no matching Kibana config..."
          local active_ids
          active_ids=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []): print(m['config_id'])
" 2>/dev/null)

          local es_ids
          es_ids=$(curl -s -k "$ES_HOST/synthetics-*/_search" \
            -H "Content-Type: application/json" -u "$ES_AUTH" \
            -d '{"size":0,"aggs":{"ids":{"terms":{"field":"monitor.id","size":200}}}}' 2>/dev/null \
            | python3 -c "
import sys, json
data = json.load(sys.stdin)
for b in data.get('aggregations',{}).get('ids',{}).get('buckets',[]): print(b['key'])
" 2>/dev/null)

          local cleaned=0
          for eid in ${(f)es_ids}; do
            [[ -z "$eid" ]] && continue
            if ! echo "$active_ids" | grep -q "$eid"; then
              echo "   Deleting orphaned data for monitor.id=$eid..."
              curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query" \
                -H "Content-Type: application/json" -u "$ES_AUTH" \
                -d '{"query":{"term":{"monitor.id":"'"$eid"'"}}}' > /dev/null 2>&1
              cleaned=$((cleaned + 1))
            fi
          done
          echo "   ✅ Cleaned $cleaned orphaned monitor dataset(s)."
          ;;

        policy-disabled)
          echo "🔧  Fix: Package Policy Disabled"
          echo "   Re-enabling disabled synthetics package policies..."
          curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=100" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if not item.get('enabled', True):
        print(item['id'])
" 2>/dev/null | while read pp_id; do
            local body
            body=$(curl -s "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
              -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
item = data.get('item', data)
item['enabled'] = True
for k in ['revision', 'created_at', 'created_by', 'updated_at', 'updated_by',
           'version', 'spaceIds', 'elasticsearch']:
    item.pop(k, None)
json.dump(item, sys.stdout)
" 2>/dev/null)
            curl -s -X PUT "$KIBANA_URL/api/fleet/package_policies/$pp_id" \
              -H "kbn-xsrf: true" -H "Content-Type: application/json" \
              -H "elastic-api-version: 2023-10-31" \
              -u "$AUTH" -d "$body" > /dev/null 2>&1
            echo "   Re-enabled $pp_id"
          done
          echo "   ✅ Package policies re-enabled."
          ;;

        orphaned-policy)
          echo "🔧  Fix: Orphaned Package Policy"
          echo "   Finding package policies with no matching monitor..."
          local monitor_ids
          monitor_ids=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=100" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('monitors', []): print(m['config_id'])
" 2>/dev/null)

          curl -s "$KIBANA_URL/api/fleet/package_policies?kuery=fleet-package-policies.package.name:synthetics&perPage=100" \
            -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    print(item['id'])
" 2>/dev/null | while read pp_id; do
            # Package policy ID pattern: {monitorConfigId}-{locationId}
            # Check if any active monitor ID is a prefix of this package policy ID
            local is_orphan=true
            for mid in ${(f)monitor_ids}; do
              [[ -z "$mid" ]] && continue
              if [[ "$pp_id" == "$mid"* ]]; then
                is_orphan=false
                break
              fi
            done
            if [[ "$is_orphan" == true ]]; then
              echo "   Deleting orphaned package policy $pp_id..."
              curl -s -X DELETE "$KIBANA_URL/internal/synthetics/monitor/policy/$pp_id" \
                -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
            fi
          done
          echo "   ✅ Orphaned package policies cleaned."
          ;;

        agent-unenrolled)
          echo "🔧  Fix: Agent Unenrolled"
          echo "   Re-enrolling requires the full synthetics setup..."
          node x-pack/scripts/synthetics_private_location.js \
            --elasticsearch-host "${ES_HOST}" \
            --kibana-url "$KIBANA_URL" \
            --kibana-username "${DATA_USERNAME}" \
            --kibana-password "${DATA_PASSWORD}"
          echo "   ✅ Agent re-enrolled."
          ;;

        service-disabled)
          echo "🔧  Fix: Synthetics Service Disabled"
          echo "   Re-enabling Synthetics service..."
          curl -s -X PUT "$KIBANA_URL/internal/synthetics/service/enablement" \
            -H "kbn-xsrf: true" -u "$AUTH" > /dev/null 2>&1
          echo "   ✅ Synthetics service re-enabled. Public location monitors will resume."
          ;;

        all)
          echo "🔧🔧🔧  FULL RESTORE — fixing all scenarios"
          echo ""
          # Order matters: re-enable service first, fix policies, then restart containers last
          for s in service-disabled policy-disabled orphaned-policy orphaned-data \
                   fleet-degraded agent-offline revision-mismatch zero-data agent-unenrolled; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            _synth_fix "$s"
            echo ""
          done
          echo "🔧🔧🔧  All scenarios restored."
          ;;

        help|*)
          echo "Available fix scenarios:"
          echo "  agent-offline      Restart stopped agent containers"
          echo "  revision-mismatch  Clean [BREAK] monitors + restart agent"
          echo "  zero-data          Clean [BREAK] monitors + restart agent"
          echo "  fleet-degraded     Restart Fleet Server containers"
          echo "  orphaned-data      Delete orphaned check data from ES"
          echo "  policy-disabled    Re-enable disabled package policies"
          echo "  orphaned-policy    Delete package policies with no monitor"
          echo "  agent-unenrolled   Re-enroll agent (full synthetics setup)"
          echo "  service-disabled   Re-enable Synthetics service"
          echo "  public-locations   Migrate monitors off broken public locations (TLS/auth sync errors)"
          echo "  all                Fix everything"
          [[ "$scenario" != "help" ]] && return 1
          ;;
      esac
    }

    # ── Route synthetics subcommands ──────────────────────────
    case "$2" in
      break)
        if [[ -z "$3" ]]; then
          echo "Usage: run-data synthetics break <scenario>"
          _synth_break help
          exit 1
        fi
        _synth_break "$3"
        ;;
      fix)
        if [[ -z "$3" ]]; then
          echo "Usage: run-data synthetics fix <scenario>"
          _synth_fix help
          exit 1
        fi
        _synth_fix "$3" "${@:4}"
        ;;
      reset)
        echo "🧹  Reset — clearing all Fleet + Synthetics state"
        echo ""

        # 0. Stop and remove Fleet Server / Elastic Agent Docker containers
        #    Do this first so containers shut down cleanly before we invalidate
        #    their API keys and wipe the Fleet state they depend on.
        echo "▶ Stopping Fleet Server and Elastic Agent containers..."
        local docker_count=0
        local cname   # declared once, outside the loop: zsh prints "cname=<value>" if `local` is re-run on a set var
        if ! _rd_timeout 10 docker info >/dev/null 2>&1; then
          echo "   ⚠ Docker daemon not responding (docker info timed out/failed)."
          echo "     Restart Docker Desktop, then re-run reset. Skipping container cleanup."
        else
        for cid in $(_rd_timeout 15 docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null \
                     | grep -iE 'fleet.server|elastic.agent' | awk '{print $1}'); do
          cname=$(_rd_timeout 10 docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
          if ! _rd_timeout 20 docker stop -t 5 "$cid" >/dev/null 2>&1; then
            echo "   ⚠ docker stop timed out for $cname ($cid) — forcing kill"
            _rd_timeout 10 docker kill "$cid" >/dev/null 2>&1
          fi
          if _rd_timeout 20 docker rm -f "$cid" >/dev/null 2>&1; then
            echo "   Stopped & removed: $cname ($cid)"
          else
            echo "   ⚠ Could not remove $cname ($cid) — restart Docker Desktop and re-run reset"
          fi
          docker_count=$((docker_count + 1))
        done
        fi
        if [[ $docker_count -eq 0 ]]; then
          echo "   No Fleet/Agent containers running"
        fi
        echo ""

        # Helper: extract IDs from JSON using python3 (avoids fragile grep on nested JSON)
        extract_ids() {
          echo "$1" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = $2
    for item in items:
        val = item.get('$3', '')
        if val:
            print(val)
except: pass
" 2>/dev/null
        }

        # 1. Delete all synthetics monitors (via Kibana API)
        echo "▶ Deleting synthetics monitors..."
        local monitors_response monitor_count=0
        monitors_response=$(curl -s "$KIBANA_URL/api/synthetics/monitors?perPage=200" \
          -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
          -u "$AUTH" 2>/dev/null)
        local monitor_ids
        monitor_ids=$(extract_ids "$monitors_response" "data.get('monitors', [])" "config_id")
        for mid in ${(f)monitor_ids}; do
          [[ -z "$mid" ]] && continue
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/monitors/$mid" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" > /dev/null 2>&1
          monitor_count=$((monitor_count + 1))
        done
        echo "   Deleted $monitor_count monitor(s)"

        # 2. Delete synthetics private locations (via Kibana API)
        echo "▶ Deleting synthetics private locations..."
        local locations loc_count=0
        locations=$(curl -s "$KIBANA_URL/api/synthetics/private_locations" \
          -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
          -u "$AUTH" 2>/dev/null)
        local loc_ids
        loc_ids=$(extract_ids "$locations" "data if isinstance(data, list) else []" "id")
        for loc_id in ${(f)loc_ids}; do
          [[ -z "$loc_id" ]] && continue
          curl -s -X DELETE "$KIBANA_URL/api/synthetics/private_locations/$loc_id" \
            -H "kbn-xsrf: true" -H "elastic-api-version: 2023-10-31" \
            -u "$AUTH" > /dev/null 2>&1
          loc_count=$((loc_count + 1))
        done
        echo "   Deleted $loc_count private location(s)"

        # 3. Force-unenroll all Fleet agents (via Fleet API)
        echo "▶ Unenrolling Fleet agents..."
        local all_agents_response agent_count=0
        all_agents_response=$(curl -s "$KIBANA_URL/api/fleet/agents?perPage=1000" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local all_agent_ids
        all_agent_ids=$(extract_ids "$all_agents_response" "data.get('items', data.get('list', []))" "id")
        for aid in ${(f)all_agent_ids}; do
          [[ -z "$aid" ]] && continue
          curl -s -X POST "$KIBANA_URL/api/fleet/agents/$aid/unenroll" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" -d '{"force":true,"revoke":true}' > /dev/null 2>&1
          agent_count=$((agent_count + 1))
        done
        echo "   Unenrolled $agent_count agent(s)"

        # 3b. Delete stale agent records from .fleet-agents (restricted system index — must use console proxy)
        echo "   Deleting stale agent records from .fleet-agents..."
        local fleet_agents_del
        fleet_agents_del=$(curl -s -X POST \
          "$KIBANA_URL/api/console/proxy?path=.fleet-agents-7%2F_delete_by_query%3Fconflicts%3Dproceed&method=POST" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" -d '{"query":{"match_all":{}}}' 2>/dev/null)
        local agents_deleted
        agents_deleted=$(echo "$fleet_agents_del" | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null)
        echo "   Deleted $agents_deleted stale agent record(s)"

        # 4. Delete Fleet agent policies (via Fleet API)
        echo "▶ Deleting Fleet agent policies..."
        local policies_response policy_count=0
        policies_response=$(curl -s "$KIBANA_URL/api/fleet/agent_policies?perPage=100" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        local policy_ids
        policy_ids=$(extract_ids "$policies_response" "data.get('items', [])" "id")
        for pid in ${(f)policy_ids}; do
          [[ -z "$pid" ]] && continue
          curl -s -X POST "$KIBANA_URL/api/fleet/agent_policies/delete" \
            -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -u "$AUTH" -d "{\"agentPolicyId\":\"$pid\",\"force\":true}" > /dev/null 2>&1
          policy_count=$((policy_count + 1))
        done
        echo "   Deleted $policy_count agent policy/policies"

        # 5. Delete Fleet internal state from ES system indices
        echo ""
        echo "▶ Clearing Fleet system index data..."
        local proxy_response
        proxy_response=$(curl -s -X POST \
          "$KIBANA_URL/api/console/proxy?path=.kibana_ingest_*%2F_delete_by_query&method=POST" \
          -H "kbn-xsrf: true" -H "Content-Type: application/json" \
          -u "$AUTH" \
          -d '{"query":{"prefix":{"type":"fleet"}}}' 2>/dev/null)
        if echo "$proxy_response" | grep -q '"deleted"'; then
          local deleted_count
          deleted_count=$(echo "$proxy_response" | grep -o '"deleted":[0-9]*' | sed 's/"deleted"://')
          echo "   Deleted $deleted_count Fleet record(s) from .kibana_ingest_*"
        else
          echo "   ⚠ Could not clear .kibana_ingest_* — Fleet signing keys may still exist."
          echo "     Run manually in Dev Tools (http://localhost:${KIBANA_PORT}/app/dev_tools#/console):"
          echo "     POST .kibana_ingest_*/_delete_by_query"
          echo '     {"query":{"prefix":{"type":"fleet"}}}'
        fi

        # 6. Delete .fleet-* ES indices and data streams
        echo ""
        echo "▶ Deleting .fleet-* ES indices and data streams..."
        local idx_count=0

        local fleet_ds
        fleet_ds=$(curl -s -k "$ES_HOST/_data_stream/.fleet*" -u "$ES_AUTH" 2>/dev/null \
          | python3 -c "import sys,json; [print(ds['name']) for ds in json.load(sys.stdin).get('data_streams',[])]" 2>/dev/null)
        for ds in ${(f)fleet_ds}; do
          [[ -z "$ds" ]] && continue
          curl -s -k -X DELETE "$ES_HOST/_data_stream/$ds" \
            -H "X-elastic-product-origin: fleet" -u "$ES_AUTH" > /dev/null 2>&1
          idx_count=$((idx_count + 1))
        done

        local fleet_indices
        fleet_indices=$(curl -s -k "$ES_HOST/_cat/indices/.fleet*?h=index" \
          -u "$ES_AUTH" 2>/dev/null | tr -d ' ')
        for idx in ${(f)fleet_indices}; do
          [[ -z "$idx" ]] && continue
          curl -s -k -X DELETE "$ES_HOST/$idx" -u "$ES_AUTH" > /dev/null 2>&1
          idx_count=$((idx_count + 1))
        done

        if [[ $idx_count -gt 0 ]]; then
          echo "   Deleted $idx_count .fleet-* index/data stream(s)"
        else
          echo "   No .fleet-* indices found"
        fi

        # 7. Disable Synthetics service (invalidate API key)
        echo ""
        echo "▶ Disabling Synthetics service (invalidating API key)..."
        local synth_http
        synth_http=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
          "$KIBANA_URL/internal/synthetics/service/enablement" \
          -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null)
        if [[ "$synth_http" == "200" ]]; then
          echo "   Synthetics service disabled and API key invalidated."
        elif [[ "$synth_http" == "404" ]]; then
          echo "   Synthetics service was not enabled (nothing to disable)."
        else
          echo "   ⚠ Could not disable Synthetics service (HTTP $synth_http)."
        fi

        # 8. Delete orphaned synthetics data from ES
        echo ""
        echo "▶ Cleaning orphaned synthetics data..."
        local synth_doc_count
        synth_doc_count=$(curl -s -k "$ES_HOST/synthetics-*/_count" -u "$ES_AUTH" 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
        if [[ "$synth_doc_count" -gt 0 ]] 2>/dev/null; then
          echo "   Found $synth_doc_count orphaned doc(s). Deleting..."
          curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query?conflicts=proceed" \
            -H "Content-Type: application/json" -u "$ES_AUTH" \
            -d '{"query":{"match_all":{}}}' > /dev/null 2>&1
          echo "   Deleted $synth_doc_count doc(s) from synthetics-* data streams."
        else
          echo "   No orphaned synthetics data found."
        fi

        echo ""
        echo "✅  Fleet + Synthetics state cleared. Restart Kibana so preconfiguration runs fresh:"
        echo "    ~/dev-start.sh restart main    # or feat, or <branch>"
        ;;
      monitors)
        echo "🖥  Creating Synthetics monitors + mock data..."
        # Resolve the generate-monitors.js script path
        # It lives alongside run-data.sh (which may be symlinked)
        # $0:A resolves symlinks (zsh-native realpath), :h takes dirname
        local SCRIPT_DIR="${0:A:h}"
        local monitor_flags=()
        local mflag
        for mflag in "${@:3}"; do
          case "$mflag" in
            --minimal|--allow-unenrolled) monitor_flags+=("$mflag") ;;
          esac
        done
        node "$SCRIPT_DIR/generate-monitors.js" \
          --kibana-url "$KIBANA_URL" \
          --kibana-username "${DATA_USERNAME}" \
          --kibana-password "${DATA_PASSWORD}" \
          --elasticsearch-host "${ES_HOST}" \
          --elasticsearch-username "${DATA_USERNAME}" \
          --elasticsearch-password "${DATA_PASSWORD}" \
          "${monitor_flags[@]}"
        ;;
      "")
        # ── Pre-flight checks (local AND remote) ─────────────────────────
        # The Kibana script launches Fleet Server in Docker and waits ~120s for it to
        # become healthy. Most failures come from the things checked below.

        # 1. Docker daemon must answer (otherwise: exit code 125 from `docker run`)
        if ! _rd_timeout 10 docker info >/dev/null 2>&1; then
          echo "❌  Docker daemon not responding. Start/restart Docker Desktop, then re-run."
          return 1
        fi

        # 2. Stale Fleet/Agent containers hold port 8220 / the container name (exit 125)
        local stale
        stale=$(_rd_timeout 15 docker ps -a --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null \
                | grep -iE 'fleet.server|elastic.agent')
        if [[ -n "$stale" ]]; then
          echo "⚠  Found existing Fleet/Agent container(s) that may block port 8220:"
          echo "$stale" | sed 's/^/     /'
          echo "   If setup fails, run: run-data synthetics reset"
          echo ""
        fi

        # 2b. Refresh the elastic-agent images. The Kibana script runs `<kibana version>-SNAPSHOT`
        #     tags, and `docker run` uses the LOCAL cached copy forever — a stale snapshot caused
        #     "seccomp policy is already registered" crashes (synthetics/* components FAILED,
        #     monitors stuck Pending). Both images are needed: `elastic-agent` (Fleet Server)
        #     and `elastic-agent-complete` (synthetics agent). Throttled to once per 12h;
        #     set RUN_DATA_SKIP_PULL=1 to skip.
        local agent_ver
        agent_ver=$(curl -s --max-time 10 -u "$AUTH" "$KIBANA_URL/api/status" 2>/dev/null \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['version']['number'] + '-SNAPSHOT')" 2>/dev/null)
        if [[ -n "$agent_ver" && "${RUN_DATA_SKIP_PULL:-0}" != "1" ]]; then
          local pull_stamp="${TMPDIR:-/tmp}/run-data-agent-pull-${agent_ver}.stamp" img pulled=false
          if [[ -z "$(find "$pull_stamp" -mmin -720 2>/dev/null)" ]]; then
            for img in elastic-agent elastic-agent-complete; do
              echo "Pulling docker.elastic.co/elastic-agent/${img}:${agent_ver} …"
              if _rd_timeout 600 docker pull -q "docker.elastic.co/elastic-agent/${img}:${agent_ver}" >/dev/null 2>&1; then
                pulled=true
              else
                echo "⚠  Could not pull ${img}:${agent_ver} (offline, expired 'docker login docker.elastic.co', or tag gone)."
                echo "   Continuing with the locally cached image, which may be stale."
              fi
            done
            [[ "$pulled" == true ]] && touch "$pull_stamp"
            echo ""
          fi
        fi

        # 3. Remote only: verify ES is reachable (catches TLS/network errors early)
        if [[ "$IS_REMOTE" == true ]]; then
          local es_check
          es_check=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -u "${DATA_USERNAME}:${DATA_PASSWORD}" "${ES_HOST}" 2>&1)
          if [[ "$es_check" != "200" ]]; then
            echo "⚠  ES connectivity check failed (${ES_HOST}):"
            curl -s --max-time 10 -u "${DATA_USERNAME}:${DATA_PASSWORD}" "${ES_HOST}" 2>&1
            echo ""
            echo "   Fleet Server agent enrollment will likely fail."
            echo ""
          fi
        fi

        # 4. Ensure Fleet is set up (creates fleet-server-policy if missing).
        #    Required after `reset` or on fresh clusters — idempotent, safe to call always.
        #    Without it Fleet Server loops on "Waiting on policy with Fleet Server
        #    integration: fleet-server-policy" until the ~120s timeout kills it (exit 143).
        echo "Ensuring Fleet is initialised…"
        local fleet_resp
        fleet_resp=$(curl -s -X POST "${KIBANA_URL}/api/fleet/setup" \
          -H "kbn-xsrf: true" -H "content-type: application/json" \
          -u "${DATA_USERNAME}:${DATA_PASSWORD}" --max-time 30 2>&1)
        if echo "$fleet_resp" | grep -q '"isInitialized":true'; then
          echo "✓ Fleet is ready"
        else
          echo "⚠  Fleet setup response: $fleet_resp"
        fi

        # 5. Wait (up to 60s) for fleet-server-policy to exist before launching Fleet Server
        local fsp_code="" fsp_try
        for fsp_try in {1..30}; do
          fsp_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            "${KIBANA_URL}/api/fleet/agent_policies/fleet-server-policy" \
            -H "kbn-xsrf: true" -u "${DATA_USERNAME}:${DATA_PASSWORD}" 2>/dev/null)
          [[ "$fsp_code" == "200" ]] && break
          sleep 2
        done
        if [[ "$fsp_code" == "200" ]]; then
          echo "✓ fleet-server-policy exists"
        else
          echo "⚠  fleet-server-policy not found (HTTP ${fsp_code:-none}). Fleet Server will likely time out."
          echo "   Try restarting Kibana so Fleet preconfiguration runs, then re-run."
        fi
        echo ""

        node x-pack/scripts/synthetics_private_location.js \
          --elasticsearch-host "${ES_HOST}" \
          --kibana-url "$KIBANA_URL" \
          --kibana-username "${DATA_USERNAME}" \
          --kibana-password "${DATA_PASSWORD}" 2>&1
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          echo ""
          echo "❌  synthetics_private_location.js failed (exit code $exit_code)"
          echo "   Common causes:"
          echo "     125  docker run failed: Docker down, stale container/port 8220, image pull failed"
          echo "     143  Fleet Server timed out (~120s): fleet-server-policy missing (restart Kibana),"
          echo "          ES/Kibana unreachable from the container, or snapshot image/version mismatch"
          echo "     Debug: docker events (look for kill signal=15), or stream logs while it runs:"
          echo "       docker logs -f \$(docker ps -q --filter ancestor=<elastic-agent image>)"
          echo "   See kibana-dev-env/references/troubleshooting.md → \"Synthetics private location fails\""
        else
          # 6. Verify the synthetics agent is actually healthy. Enrollment can succeed while the
          #    agent's synthetics/* components crash (stale image) — monitors then sit Pending,
          #    and mock data from generate-monitors.js would hide that by faking Up results.
          echo ""
          echo "Verifying synthetics agent health (up to 90s)…"
          local agent_status="" ag_try
          for ag_try in {1..30}; do
            agent_status=$(curl -s --max-time 5 "$KIBANA_URL/api/fleet/agents?perPage=100" \
              -H "kbn-xsrf: true" -u "$AUTH" 2>/dev/null | python3 -c "
import sys, json
try:
    items = json.load(sys.stdin).get('items', [])
    s = [a.get('status') for a in items if a.get('policy_id') != 'fleet-server-policy']
    print(s[0] if s else 'none')
except Exception:
    print('none')
" 2>/dev/null)
            [[ "$agent_status" == "online" ]] && break
            sleep 3
          done
          case "$agent_status" in
            online)
              echo "✓ Synthetics agent is healthy — monitors will run." ;;
            none)
              echo "⚠  No synthetics agent enrolled. Check Fleet → Agents." ;;
            *)
              echo "⚠  Synthetics agent status: ${agent_status} (not healthy)."
              echo "   Open Fleet → Agents → the agent → Components. If synthetics/* are FAILED with"
              echo "   'seccomp policy is already registered', the cached agent image is stale/broken:"
              echo "     docker pull docker.elastic.co/elastic-agent/elastic-agent-complete:<ver>-SNAPSHOT"
              echo "   then 'run-data synthetics reset', restart Kibana and re-run." ;;
          esac
        fi
        return $exit_code
        ;;
      heartbeat)
        # ── k8s autodiscovery heartbeat monitors ──────────────
        # Elastic Agent (k8s provider + synthetics inputs) writes pings to
        # synthetics-* with NO saved object — the input the read-only "heartbeat
        # monitor" surfacing consumes. See references/heartbeat-autodiscovery.md.
        local HB_NS_DEFAULT="otel-demo"       # namespace whose Services we monitor
        local HB_AGENT_NS="kube-system"        # where the Agent runs
        local HB_MANIFEST="/tmp/kbn-dev-agent-synthetics.yaml"
        local HB_KEY_NAME="kbn-dev-synthetics-agent"  # ES API key name for the Agent output
        local HB_VERSION HB_IMAGE
        HB_VERSION=$(grep -m1 '"version"' package.json | sed 's/.*: *"//; s/".*//')
        HB_IMAGE="docker.elastic.co/elastic-agent/elastic-agent:${HB_VERSION}-SNAPSHOT"

        _hb_need() {
          command -v "$1" >/dev/null 2>&1 || { echo "❌  '$1' not found in PATH."; return 1; }
        }

        # Minikube quick-start + gotchas. otel_demo.js does NOT auto-start
        # minikube — it asserts `Running` first (assert_minikube_available.ts),
        # so you must start it yourself. Always use `minikube start`, never the
        # Docker Desktop container controls (that causes a stale kubeconfig:
        # `kubeconfig: Misconfigured`, kubelet/apiserver Stopped, port drift).
        _hb_minikube_info() {
          echo "🐳  Minikube quick start (Docker must be running first):"
          echo "      minikube start --driver=docker --memory=4096 --cpus=4"
          echo "      minikube status        # host/kubelet/apiserver → Running, kubeconfig → Configured"
          echo "      kubectl get nodes      # 1 node, Ready"
          echo ""
          echo "    Stale kubeconfig ('Misconfigured' / kubelet Stopped after a Docker restart)?"
          echo "      minikube update-context && minikube start --driver=docker"
          echo "    Never start/stop the minikube container from Docker Desktop — use 'minikube ...' only."
          echo "    Clean rebuild if wedged:  minikube delete && minikube start --driver=docker --memory=4096 --cpus=4"
          echo ""
          echo "    Then deploy the demo (provides Services to monitor):"
          echo "      node ./scripts/otel_demo.js --config config/kibana.dev.yml"
        }

        # Emit the Agent manifest (ConfigMap + Deployment + RBAC) with the
        # current ES host / api key / image substituted in. Uses a quoted
        # heredoc + token replacement so the k8s ${...} vars stay literal.
        _hb_write_manifest() {
          local es_host="$1" api_key="$2" image="$3" agent_ns="$4"
          local safe_key="${api_key//&/\\&}"
          cat <<'YAML' | sed \
            -e "s|__ES_HOST__|${es_host}|g" \
            -e "s|__API_KEY__|${safe_key}|g" \
            -e "s|__IMAGE__|${image}|g" \
            -e "s|__AGENT_NS__|${agent_ns}|g"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-synthetics-datastreams
  namespace: __AGENT_NS__
  labels:
    app.kubernetes.io/name: elastic-agent-synthetics
data:
  agent.yml: |-
    outputs:
      default:
        type: elasticsearch
        hosts:
          - __ES_HOST__
        api_key: __API_KEY__
        ssl.verification_mode: none
    agent:
      monitoring:
        enabled: false
    providers.kubernetes:
      node: ${NODE_NAME}
      scope: cluster
      resources:
        service.enabled: true
        pod.enabled: false
    inputs:
      - name: autodiscover-tcp-synthetic
        condition: ${kubernetes.annotations.co.elastic.monitor/type} == 'tcp'
        type: synthetics/tcp
        meta:
          package:
            name: synthetics
            version: 1.8.0
        data_stream:
          namespace: default
        use_output: default
        streams:
          - data_stream:
              type: synthetics
              dataset: tcp
            type: tcp
            enabled: true
            name: ${kubernetes.annotations.co.elastic.monitor/name}
            hosts: ${kubernetes.annotations.co.elastic.monitor/hosts}
            schedule: ${kubernetes.annotations.co.elastic.monitor/schedule}
            timeout: ${kubernetes.annotations.co.elastic.monitor/timeout}
            tags: ["${kubernetes.namespace}", "k8s-autodiscover"]
            fields_under_root: true
            fields:
              monitor.id: "${kubernetes.annotations.co.elastic.monitor/id}"
      - name: autodiscover-http-synthetic
        condition: ${kubernetes.annotations.co.elastic.monitor/type} == 'http'
        type: synthetics/http
        meta:
          package:
            name: synthetics
            version: 1.8.0
        data_stream:
          namespace: default
        use_output: default
        streams:
          - data_stream:
              type: synthetics
              dataset: http
            type: http
            enabled: true
            name: ${kubernetes.annotations.co.elastic.monitor/name}
            hosts: ${kubernetes.annotations.co.elastic.monitor/hosts}
            schedule: ${kubernetes.annotations.co.elastic.monitor/schedule}
            timeout: ${kubernetes.annotations.co.elastic.monitor/timeout}
            tags: ["${kubernetes.namespace}", "k8s-autodiscover"]
            fields_under_root: true
            fields:
              monitor.id: "${kubernetes.annotations.co.elastic.monitor/id}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elastic-agent-synthetics
  namespace: __AGENT_NS__
  labels:
    app.kubernetes.io/name: elastic-agent-synthetics
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: elastic-agent-synthetics
  template:
    metadata:
      labels:
        app.kubernetes.io/name: elastic-agent-synthetics
    spec:
      serviceAccountName: elastic-agent-synthetics
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: elastic-agent
          image: __IMAGE__
          args: ["-c", "/etc/elastic-agent/agent.yml", "-e"]
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: ELASTIC_NETINFO
              value: "false"
          securityContext:
            runAsUser: 0
          resources:
            limits:
              memory: 1200Mi
            requests:
              cpu: 100m
              memory: 400Mi
          volumeMounts:
            - name: datastreams
              mountPath: /etc/elastic-agent/agent.yml
              readOnly: true
              subPath: agent.yml
      volumes:
        - name: datastreams
          configMap:
            defaultMode: 0644
            name: agent-synthetics-datastreams
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: elastic-agent-synthetics
  namespace: __AGENT_NS__
  labels:
    app.kubernetes.io/name: elastic-agent-synthetics
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: elastic-agent-synthetics
  labels:
    app.kubernetes.io/name: elastic-agent-synthetics
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - namespaces
      - events
      - pods
      - services
      - configmaps
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources:
      - statefulsets
      - deployments
      - replicasets
      - daemonsets
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: elastic-agent-synthetics
subjects:
  - kind: ServiceAccount
    name: elastic-agent-synthetics
    namespace: __AGENT_NS__
roleRef:
  kind: ClusterRole
  name: elastic-agent-synthetics
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: elastic-agent-synthetics
  namespace: __AGENT_NS__
  labels:
    app.kubernetes.io/name: elastic-agent-synthetics
rules:
  - apiGroups:
      - coordination.k8s.io
    resources:
      - leases
    verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: elastic-agent-synthetics
  namespace: __AGENT_NS__
subjects:
  - kind: ServiceAccount
    name: elastic-agent-synthetics
    namespace: __AGENT_NS__
roleRef:
  kind: Role
  name: elastic-agent-synthetics
  apiGroup: rbac.authorization.k8s.io
YAML
        }

        # One http monitor on `frontend`, tcp monitors on a few backends.
        _hb_annotate_services() {
          local ns="$1"
          _hb_one() { local svc="$1"; shift; kubectl annotate --overwrite -n "$ns" service "$svc" "$@"; }
          _hb_one frontend \
            co.elastic.monitor/type=http \
            co.elastic.monitor/id=otel-frontend-http \
            co.elastic.monitor/name="otel frontend (http)" \
            co.elastic.monitor/hosts="http://frontend.${ns}.svc.cluster.local:8080" \
            co.elastic.monitor/schedule="@every 30s" \
            co.elastic.monitor/timeout=10s 2>&1 || true
          local spec
          for spec in "product-catalog:3550:otel-product-catalog-tcp" \
                      "cart:7070:otel-cart-tcp" \
                      "currency:7285:otel-currency-tcp"; do
            local svc="${spec%%:*}" rest="${spec#*:}"
            local port="${rest%%:*}" id="${rest#*:}"
            _hb_one "$svc" \
              co.elastic.monitor/type=tcp \
              co.elastic.monitor/id="$id" \
              co.elastic.monitor/name="otel ${svc} (tcp)" \
              co.elastic.monitor/hosts="${svc}.${ns}.svc.cluster.local:${port}" \
              co.elastic.monitor/schedule="@every 30s" \
              co.elastic.monitor/timeout=10s 2>&1 || true
          done
        }

        # deploy/annotate/verify extracted so the one-shot `up` can reuse them.
        _hb_deploy() {
          _hb_need kubectl || return 1
          _hb_need minikube || return 1
          _hb_need docker || return 1

          if ! minikube status >/dev/null 2>&1; then
            echo "❌  minikube is not running (otel_demo.js won't auto-start it)."
            echo ""
            _hb_minikube_info
            return 1
          fi
          if ! kubectl get ns "$HB_NS_DEFAULT" >/dev/null 2>&1; then
            echo "⚠  Namespace '$HB_NS_DEFAULT' not found — it provides the Services to monitor."
            echo "    node ./scripts/otel_demo.js --config config/kibana.dev.yml"
            echo "   Continuing; you can annotate Services in another namespace manually."
          fi
          # Inside minikube, localhost/127.0.0.1 is the Agent pod itself, not the Mac.
          # For local ES, hand the Agent host.minikube.internal instead (manifest only;
          # the script's own curl calls keep using $ES_HOST).
          local AGENT_ES_HOST="$ES_HOST"
          if [[ "$IS_REMOTE" != true ]]; then
            AGENT_ES_HOST="${ES_HOST//localhost/host.minikube.internal}"
            AGENT_ES_HOST="${AGENT_ES_HOST//127.0.0.1/host.minikube.internal}"
            echo "⚠  ES host is local ($ES_HOST). Agent will use $AGENT_ES_HOST instead."
            echo "   ES must listen beyond loopback: set ES_BIND_ALL=true in ~/.kibana-dev.conf and"
            echo "   restart ES, otherwise the in-cluster Agent gets 'connection refused'."
          fi

          echo "▶ Installing synthetics integration package…"
          curl -s -X POST "$KIBANA_URL/api/fleet/epm/packages/synthetics" \
            -u "$AUTH" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
            -d '{"force":true}' >/dev/null 2>&1
          echo "   done."

          # ES lets multiple keys share a name, so re-running deploy would otherwise
          # leave orphaned keys behind. Invalidate any prior key of this name first.
          echo "▶ Invalidating any existing '$HB_KEY_NAME' API keys…"
          curl -s -k -X DELETE "$ES_HOST/_security/api_key" -u "$ES_AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$HB_KEY_NAME\"}" >/dev/null 2>&1

          echo "▶ Creating scoped ES API key for the Agent output…"
          local key_resp key_pair
          key_resp=$(curl -s -k -X POST "$ES_HOST/_security/api_key" -u "$ES_AUTH" \
            -H "Content-Type: application/json" -d "{
              \"name\":\"$HB_KEY_NAME\",
              \"role_descriptors\":{\"synthetics_writer\":{\"cluster\":[\"monitor\"],
              \"indices\":[{\"names\":[\"synthetics-*\"],\"privileges\":[\"auto_configure\",\"create_doc\"]}]}}
            }" 2>/dev/null)
          key_pair=$(echo "$key_resp" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d['id']+':'+d['api_key'])" 2>/dev/null)
          if [[ -z "$key_pair" ]]; then
            echo "❌  Could not create API key. Response:"; echo "$key_resp"; return 1
          fi
          echo "   API key created."

          echo "▶ Generating manifest → $HB_MANIFEST"
          echo "   image: $HB_IMAGE"
          echo "   es:    $AGENT_ES_HOST"
          _hb_write_manifest "$AGENT_ES_HOST" "$key_pair" "$HB_IMAGE" "$HB_AGENT_NS" > "$HB_MANIFEST"

          echo "▶ Applying manifest…"
          kubectl apply -f "$HB_MANIFEST"
          # The rotated key lands in the configmap, so `apply` reports the Deployment
          # "unchanged" and the running pod keeps the OLD (just-invalidated) key —
          # silently going stale. Force a new pod so it loads the fresh key.
          echo "▶ Restarting agent to load the fresh key…"
          kubectl rollout restart deployment/elastic-agent-synthetics -n "$HB_AGENT_NS"
          kubectl rollout status deployment/elastic-agent-synthetics -n "$HB_AGENT_NS" --timeout=120s || true
        }

        _hb_do_annotate() {
          _hb_need kubectl || return 1
          local ns="${1:-$HB_NS_DEFAULT}"
          echo "▶ Annotating Services in namespace '$ns' (co.elastic.monitor/*)…"
          _hb_annotate_services "$ns"
        }

        _hb_verify() {
          echo "▶ Checking synthetics-* for autodiscovery pings…"
          local cnt sample
          cnt=$(curl -s -k "$ES_HOST/synthetics-*/_count" -u "$ES_AUTH" \
            -H "Content-Type: application/json" \
            -d '{"query":{"term":{"tags":"k8s-autodiscover"}}}' 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
          echo "   k8s-autodiscover pings: ${cnt:-0}"
          sample=$(curl -s -k "$ES_HOST/synthetics-*/_search" -u "$ES_AUTH" \
            -H "Content-Type: application/json" \
            -d '{"size":1,"sort":[{"@timestamp":"desc"}],"query":{"term":{"tags":"k8s-autodiscover"}}}' 2>/dev/null)
          echo "$sample" | python3 -c "
import sys, json
from datetime import datetime, timezone
d = json.load(sys.stdin)
hits = d.get('hits', {}).get('hits', [])
if not hits:
    print('   No pings yet — wait ~1 min, or check: run-data synthetics heartbeat status')
    sys.exit(0)
s = hits[0]['_source']
ts = s.get('@timestamp')
print('   latest monitor.id :', s.get('monitor', {}).get('id'))
print('   monitor.status    :', s.get('monitor', {}).get('status'))
print('   observer.geo.name :', (s.get('observer', {}) or {}).get('geo', {}).get('name', '<absent>'))
print('   meta.space_id     :', (s.get('meta', {}) or {}).get('space_id', '<absent>'))
print('   latest @timestamp :', ts)
# Staleness verdict: autodiscovery monitors ping ~every 30-60s, so anything
# older than a few minutes means the Agent stopped shipping (e.g. dead API key).
if ts:
    age = (datetime.now(timezone.utc) - datetime.fromisoformat(ts.replace('Z', '+00:00'))).total_seconds()
    mins = age / 60
    if age <= 180:
        print(f'   freshness         : ✅ FRESH (last ping {age:.0f}s ago)')
    else:
        print(f'   freshness         : ⚠️  STALE (last ping {mins:.1f} min ago) — Agent likely not shipping.')
        print('                       Check: run-data synthetics heartbeat status  (look for 401/invalidated API key)')
        print('                       Fix:   run-data synthetics heartbeat deploy  (fresh key + rolling restart)')
" 2>/dev/null || { echo "   Could not parse a sample doc:"; echo "$sample" | head -c 300; }
        }

        # Shared "what you'll see in the UI" note for the break scenarios — the
        # whole point is that the monitor keeps looking healthy while data stops.
        _hb_break_symptom() {
          echo "   Expected in the Synthetics UI (the gap tracked in elastic/kibana#281750):"
          echo "     • the monitor(s) still show as Up (green) in the overview — no staleness signal"
          echo "     • flyout 'Last test run' stops advancing and the Duration chart flatlines"
          echo "   Confirm from ES:  run-data synthetics heartbeat verify   (flips to ⚠️ STALE after ~3 min)"
        }

        case "$3" in
          up|all)
            # One-shot: minikube → otel demo → deploy → annotate → verify.
            _hb_need minikube || exit 1
            _hb_need kubectl || exit 1
            _hb_need docker || exit 1
            _hb_need node || exit 1
            local ns="${4:-$HB_NS_DEFAULT}"

            echo "══ 1/5  minikube ══"
            if minikube status >/dev/null 2>&1; then
              echo "✓ minikube already running."
            else
              echo "▶ Starting minikube…"
              minikube start --driver=docker --memory=4096 --cpus=4 \
                || { echo "❌  minikube start failed."; echo ""; _hb_minikube_info; exit 1; }
            fi

            echo ""
            echo "══ 2/5  OpenTelemetry demo (Services to monitor) ══"
            if kubectl get ns "$ns" >/dev/null 2>&1; then
              echo "✓ namespace '$ns' already present — skipping otel demo deploy."
            else
              echo "▶ Deploying otel demo via ./scripts/otel_demo.js…"
              # otel_demo.js reads KIBANA_* / ELASTICSEARCH_* env, NOT the yml's
              # kibana_system_user creds — reuse the superuser DATA_* here so it
              # authenticates on oblt-cli (admin) clusters.
              KIBANA_USERNAME="$DATA_USERNAME" KIBANA_PASSWORD="$DATA_PASSWORD" \
              ELASTICSEARCH_USERNAME="$DATA_USERNAME" ELASTICSEARCH_PASSWORD="$DATA_PASSWORD" \
                node ./scripts/otel_demo.js --config "$YML" \
                || { echo "❌  otel_demo.js failed (see error above)."; exit 1; }
            fi

            echo ""
            echo "══ 3/5  deploy Elastic Agent ══"
            _hb_deploy || exit 1

            echo ""
            echo "══ 4/5  annotate Services ══"
            _hb_do_annotate "$ns" || exit 1

            echo ""
            echo "══ 5/5  wait for first pings + verify ══"
            echo "⏳  Waiting ${HB_WAIT:-75}s for autodiscovery to emit pings…"
            sleep "${HB_WAIT:-75}"
            _hb_verify
            echo ""
            echo "✅  Heartbeat flow complete. Open the Synthetics overview to see the monitors."
            echo "    Re-check anytime: run-data synthetics heartbeat verify"
            ;;

          deploy)
            _hb_deploy || exit 1
            echo ""
            echo "✅  Agent deployed. Next: run-data synthetics heartbeat annotate"
            ;;

          annotate)
            _hb_do_annotate "${4:-}" || exit 1
            echo ""
            echo "✅  Annotated. Pings land within ~1 min. Next — verify:"
            if [[ "$IS_REMOTE" == true ]]; then
              echo "    DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data synthetics heartbeat verify"
              echo "    (remote ES needs the superuser — admin pw is in config's loginAssistanceMessage)"
            else
              echo "    run-data synthetics heartbeat verify"
            fi
            ;;

          verify)
            _hb_verify
            ;;

          break)
            # Realistic ways an autodiscovery Agent stops shipping in the wild.
            # `dead-key` is the star: pod stays Running yet data silently stops.
            _hb_need kubectl || exit 1
            local scenario="${4:-dead-key}"
            case "$scenario" in
              dead-key)
                echo "▶ [break: dead-key] Invalidating the Agent API key '$HB_KEY_NAME' — leaving the pod running…"
                curl -s -k -X DELETE "$ES_HOST/_security/api_key" -u "$ES_AUTH" \
                  -H "Content-Type: application/json" \
                  -d "{\"name\":\"$HB_KEY_NAME\"}" >/dev/null 2>&1
                echo "   Pod stays Running but its key is dead → it silently stops shipping (401s)."
                _hb_break_symptom
                echo "   Fix:  run-data synthetics heartbeat fix dead-key"
                ;;
              agent-down)
                echo "▶ [break: agent-down] Scaling the Agent deployment to 0 replicas…"
                kubectl scale deployment/elastic-agent-synthetics -n "$HB_AGENT_NS" --replicas=0 2>&1 || true
                echo "   No Agent pod → no new pings."
                _hb_break_symptom
                echo "   Fix:  run-data synthetics heartbeat fix agent-down"
                ;;
              unannotate)
                local ns="${5:-$HB_NS_DEFAULT}"
                echo "▶ [break: unannotate] Removing co.elastic.monitor/* annotations from Services in '$ns'…"
                local svc
                for svc in frontend product-catalog cart currency; do
                  kubectl annotate -n "$ns" service "$svc" \
                    co.elastic.monitor/type- co.elastic.monitor/id- co.elastic.monitor/name- \
                    co.elastic.monitor/hosts- co.elastic.monitor/schedule- co.elastic.monitor/timeout- \
                    >/dev/null 2>&1 || true
                done
                echo "   Autodiscovery targets gone → those monitors stop being probed."
                _hb_break_symptom
                echo "   Fix:  run-data synthetics heartbeat fix unannotate [namespace]"
                ;;
              help|*)
                echo "Usage: run-data synthetics heartbeat break <dead-key|agent-down|unannotate> [namespace]"
                echo "  dead-key    Invalidate the Agent API key, keep the pod running (silent staleness; default)"
                echo "  agent-down  Scale the Agent deployment to 0 replicas (no pings)"
                echo "  unannotate  Strip co.elastic.monitor/* annotations from otel-demo Services [namespace]"
                exit 1
                ;;
            esac
            ;;

          fix)
            local scenario="${4:-dead-key}"
            case "$scenario" in
              dead-key)
                echo "▶ [fix: dead-key] Redeploying the Agent with a fresh key…"
                _hb_deploy || exit 1
                ;;
              agent-down)
                _hb_need kubectl || exit 1
                echo "▶ [fix: agent-down] Scaling the Agent back to 1 replica…"
                kubectl scale deployment/elastic-agent-synthetics -n "$HB_AGENT_NS" --replicas=1 2>&1 || true
                kubectl rollout status deployment/elastic-agent-synthetics -n "$HB_AGENT_NS" --timeout=120s || true
                ;;
              unannotate)
                _hb_do_annotate "${5:-}" || exit 1
                ;;
              help|*)
                echo "Usage: run-data synthetics heartbeat fix <dead-key|agent-down|unannotate> [namespace]"
                exit 1
                ;;
            esac
            echo ""
            echo "✅  Restored. Pings resume within ~1 min — confirm with:"
            echo "    run-data synthetics heartbeat verify"
            ;;

          clear)
            # Data-only wipe: drop the pings so monitors vanish from the UI, but
            # keep the Agent + Service annotations so they repopulate on the next
            # check. Use `reset` for a full teardown.
            echo "▶ Deleting k8s-autodiscover pings from synthetics-* (keeping Agent + annotations)…"
            local del
            del=$(curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query?conflicts=proceed" \
              -u "$ES_AUTH" -H "Content-Type: application/json" \
              -d '{"query":{"term":{"tags":"k8s-autodiscover"}}}' 2>/dev/null \
              | python3 -c "import sys,json; print(json.load(sys.stdin).get('deleted',0))" 2>/dev/null)
            echo "   deleted pings: ${del:-0}"
            echo "✅  Cleared. Monitors drop from the UI until the Agent re-pings (~1 min)."
            echo "    Agent + annotations left in place — use 'reset' for a full teardown."
            ;;

          status)
            _hb_need kubectl || exit 1
            echo "▶ Agent pod:"
            kubectl get pods -n "$HB_AGENT_NS" \
              -l app.kubernetes.io/name=elastic-agent-synthetics 2>&1
            echo ""
            echo "▶ Recent agent logs:"
            kubectl logs -n "$HB_AGENT_NS" deploy/elastic-agent-synthetics --tail=20 2>&1 \
              | grep -vi _encode || true
            ;;

          reset)
            _hb_need kubectl || exit 1
            local ns="${4:-$HB_NS_DEFAULT}"
            echo "▶ Deleting Agent deployment + RBAC…"
            if [[ -f "$HB_MANIFEST" ]]; then
              kubectl delete -f "$HB_MANIFEST" --ignore-not-found 2>&1 || true
            else
              kubectl delete deployment,configmap,serviceaccount,role,rolebinding \
                elastic-agent-synthetics -n "$HB_AGENT_NS" --ignore-not-found 2>&1 || true
              kubectl delete clusterrole,clusterrolebinding elastic-agent-synthetics \
                --ignore-not-found 2>&1 || true
            fi
            echo "▶ Removing annotations from Services in '$ns'…"
            local svc
            for svc in frontend product-catalog cart currency; do
              kubectl annotate -n "$ns" service "$svc" \
                co.elastic.monitor/type- co.elastic.monitor/id- co.elastic.monitor/name- \
                co.elastic.monitor/hosts- co.elastic.monitor/schedule- co.elastic.monitor/timeout- \
                >/dev/null 2>&1 || true
            done
            echo "▶ Deleting k8s-autodiscover pings from synthetics-*…"
            curl -s -k -X POST "$ES_HOST/synthetics-*/_delete_by_query?conflicts=proceed" \
              -u "$ES_AUTH" -H "Content-Type: application/json" \
              -d '{"query":{"term":{"tags":"k8s-autodiscover"}}}' >/dev/null 2>&1
            echo "▶ Invalidating the Agent API key…"
            curl -s -k -X DELETE "$ES_HOST/_security/api_key" -u "$ES_AUTH" \
              -H "Content-Type: application/json" \
              -d "{\"name\":\"$HB_KEY_NAME\"}" >/dev/null 2>&1
            echo "✅  Heartbeat autodiscovery teardown complete."
            ;;

          *)
            echo "Usage: run-data synthetics heartbeat <up|deploy|annotate|verify|break|fix|clear|status|reset> [namespace]"
            echo ""
            echo "  up          One-shot: start minikube → otel demo → deploy → annotate → verify"
            echo "  deploy      Install synthetics pkg, create API key, deploy Agent to minikube"
            echo "  annotate    Annotate otel-demo Services to drive autodiscovered monitors"
            echo "  verify      Check synthetics-* pings landed (+ location/space fields)"
            echo "  break <s>   Inject a failure (dead-key|agent-down|unannotate) to repro silent staleness"
            echo "  fix <s>     Restore from a break scenario (dead-key|agent-down|unannotate)"
            echo "  clear       Delete only the ping data (monitors vanish from UI; Agent repopulates)"
            echo "  status      Show Agent pod + recent logs"
            echo "  reset       Delete Agent, annotations, pings, and API key (full teardown)"
            echo ""
            echo "  up handles the prereqs for you (minikube + otel demo); the individual"
            echo "  subcommands assume minikube is running and the otel demo is deployed."
            echo "  On remote/oblt-cli ES pass the superuser, e.g.:"
            echo "    DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data synthetics heartbeat up"
            echo "  Override the post-annotate wait with HB_WAIT=<seconds> (default 75)."
            echo "  See references/heartbeat-autodiscovery.md for the full runbook."
            echo ""
            _hb_minikube_info
            exit 1
            ;;
        esac
        ;;

      *)
        echo "Usage: run-data synthetics [monitors|break|fix|reset|heartbeat] [scenario]"
        echo ""
        echo "  (no args)   Create private location (default setup)"
        echo "  monitors              Create ~40 monitors + mock data (idempotent)"
        echo "  monitors --minimal    Create 4 monitors (1 per type) + mock data"
        echo "  break <s>   Trigger failure scenario <s>"
        echo "  fix <s>     Restore from failure scenario <s>"
        echo "  reset       Wipe all Fleet + Synthetics state"
        echo "  heartbeat <c>  k8s autodiscovery heartbeat monitors (up/deploy/annotate/verify/clear/status/reset)"
        echo ""
        echo "Run 'run-data synthetics break help' for scenario list."
        echo "Run 'run-data synthetics heartbeat' for the heartbeat subcommands."
        exit 1
        ;;
    esac
    ;;

  *)
    echo "Usage: run-data [slo|synthetics]"
    exit 1
    ;;
esac
