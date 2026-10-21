#!/usr/bin/env bash
# ============================================================
#  test-config-generation.sh — tests for kibana.dev.yml generation
#
#  Tests both local (template-based) and remote (--remote flag)
#  config generation, including port substitution, server block
#  stripping, and correct YAML structure.
# ============================================================

# Resolve script dir (works in bash and zsh)
_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"

# ── Setup: source functions from dev-start.sh ─────────────
# We source just the functions we need, not the whole script
# (which would trigger the router at the bottom)
TEMPLATE="$PROJECT_DIR/kibana.dev.yml.template"

# Colors needed by the functions
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Extract functions from dev-start.sh
eval "$(sed -n '/^generate_kibana_dev_yml()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"
eval "$(sed -n '/^generate_remote_kibana_dev_yml()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"


# ══════════════════════════════════════════════════════════
#  LOCAL CONFIG GENERATION
# ══════════════════════════════════════════════════════════

describe "generate_kibana_dev_yml (local ES)"

it "generates kibana.dev.yml in the target directory"
  worktree="$TEST_DIR/worktree-local-1"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_exists "$worktree/config/kibana.dev.yml"

it "substitutes Kibana port correctly"
  worktree="$TEST_DIR/worktree-local-2"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5603 9202 > /dev/null 2>&1
  port=$(grep -E "^ *port:" "$worktree/config/kibana.dev.yml" | head -1 | awk '{print $2}')
  assert_eq "5603" "$port"

it "substitutes ES port correctly"
  worktree="$TEST_DIR/worktree-local-3"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "http://localhost:9200"

it "does not leave any unreplaced placeholders"
  worktree="$TEST_DIR/worktree-local-4"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_not_contains "$worktree/config/kibana.dev.yml" "__KIBANA_PORT__|__ES_PORT__|__FLEET_SERVER_PORT__"

it "sets elasticsearch.username to kibana"
  worktree="$TEST_DIR/worktree-local-6"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" 'elasticsearch.username: "kibana"'

it "uses different ports for feat vs main"
  wt_feat="$TEST_DIR/worktree-feat"
  wt_main="$TEST_DIR/worktree-main"
  mkdir -p "$wt_feat" "$wt_main"
  generate_kibana_dev_yml "$wt_feat" 5601 9200 > /dev/null 2>&1
  generate_kibana_dev_yml "$wt_main" 5602 9201 > /dev/null 2>&1
  feat_port=$(grep -E "^ *port:" "$wt_feat/config/kibana.dev.yml" | head -1 | awk '{print $2}')
  main_port=$(grep -E "^ *port:" "$wt_main/config/kibana.dev.yml" | head -1 | awk '{print $2}')
  assert_eq "5601:5602" "$feat_port:$main_port" "feat should be 5601, main should be 5602"

it "includes Fleet configuration"
  worktree="$TEST_DIR/worktree-local-fleet"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "xpack.fleet.agentPolicies"


# ══════════════════════════════════════════════════════════
#  REMOTE CONFIG GENERATION
# ══════════════════════════════════════════════════════════

describe "generate_remote_kibana_dev_yml (remote ES)"

# Create a mock remote ES config
MOCK_REMOTE="$TEST_DIR/mock-remote-es.yml"
cat > "$MOCK_REMOTE" <<'REMOTE_EOF'
## Latest from 01/04/2026

elasticsearch:
  hosts: https://test-cluster.es.us-west2.gcp.elastic-cloud.com:443
  username: kibana_system_user
  password: test-password-123
  ssl:
    verificationMode: none

server:
  host: 0.0.0.0
  restrictInternalApis: false

monitoring.ui.logs.index: remote_cluster:filebeat-*,filebeat-*
xpack:
  encryptedSavedObjects:
    encryptionKey: test-encryption-key
  security:
    encryptionKey: test-security-key
REMOTE_EOF

# Point the function at our mock
REMOTE_ES_CONFIG="$MOCK_REMOTE"

it "generates kibana.dev.yml from remote config"
  worktree="$TEST_DIR/worktree-remote-1"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_exists "$worktree/config/kibana.dev.yml"

it "sets the correct Kibana port"
  worktree="$TEST_DIR/worktree-remote-2"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  port=$(grep -E "^ *port:" "$worktree/config/kibana.dev.yml" | head -1 | awk '{print $2}')
  assert_eq "5601" "$port"

it "includes the remote ES host"
  worktree="$TEST_DIR/worktree-remote-3"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "test-cluster.es.us-west2.gcp.elastic-cloud.com"

it "includes the remote ES credentials (username + password)"
  worktree="$TEST_DIR/worktree-remote-4"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "kibana_system_user"
  # Also check password is present (same file, same generation)
  grep -q "test-password-123" "$worktree/config/kibana.dev.yml" || { fail "password not found in generated config"; }

it "strips the server: block from remote config"
  worktree="$TEST_DIR/worktree-remote-strip"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  # Should NOT contain the oblt-cli server block (host: 0.0.0.0)
  assert_file_not_contains "$worktree/config/kibana.dev.yml" "host: 0.0.0.0"

it "only has one server: block (the generated one)"
  worktree="$TEST_DIR/worktree-remote-oneserver"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  count=$(grep -c "^server:" "$worktree/config/kibana.dev.yml")
  assert_eq "1" "$count" "should have exactly one server: block"

it "preserves encryption keys from remote config"
  worktree="$TEST_DIR/worktree-remote-enc"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "test-encryption-key"

it "preserves monitoring config from remote"
  worktree="$TEST_DIR/worktree-remote-mon"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_contains "$worktree/config/kibana.dev.yml" "monitoring.ui.logs.index"

it "does not include localhost ES references"
  worktree="$TEST_DIR/worktree-remote-nolocalhost"
  mkdir -p "$worktree"
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  # The generated file should not have the template's localhost ES block
  assert_file_not_contains "$worktree/config/kibana.dev.yml" "http://localhost:9200"

it "fails gracefully when remote config file is missing"
  worktree="$TEST_DIR/worktree-remote-missing"
  mkdir -p "$worktree"
  old_config="$REMOTE_ES_CONFIG"
  REMOTE_ES_CONFIG="$TEST_DIR/nonexistent-file.yml"
  output=$(generate_remote_kibana_dev_yml "$worktree" 5601 2>&1) || true
  REMOTE_ES_CONFIG="$old_config"
  assert_contains "$output" "Remote ES config not found"


# ══════════════════════════════════════════════════════════
#  SWITCHING BETWEEN LOCAL AND REMOTE
# ══════════════════════════════════════════════════════════

describe "switching between local and remote"

it "local config replaces remote config cleanly"
  worktree="$TEST_DIR/worktree-switch-1"
  mkdir -p "$worktree"
  # Start with remote
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  # Switch to local
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  assert_file_not_contains "$worktree/config/kibana.dev.yml" "test-cluster.es.us-west2.gcp.elastic-cloud.com"

it "remote config replaces local config cleanly"
  worktree="$TEST_DIR/worktree-switch-2"
  mkdir -p "$worktree"
  # Start with local
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  # Switch to remote
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  assert_file_not_contains "$worktree/config/kibana.dev.yml" "http://localhost:9200"

it "port stays consistent after local→remote→local"
  worktree="$TEST_DIR/worktree-switch-3"
  mkdir -p "$worktree"
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  generate_remote_kibana_dev_yml "$worktree" 5601 > /dev/null 2>&1
  generate_kibana_dev_yml "$worktree" 5601 9200 > /dev/null 2>&1
  port=$(grep -E "^ *port:" "$worktree/config/kibana.dev.yml" | head -1 | awk '{print $2}')
  assert_eq "5601" "$port"


# ── Print results ─────────────────────────────────────────
print_summary
