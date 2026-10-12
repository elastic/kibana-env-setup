#!/usr/bin/env bash
# ============================================================
#  test-pkg-manager.sh — yarn vs pnpm detection per worktree
#
#  Newer Kibana branches use pnpm, older ones yarn. dev-start.sh
#  (detect_pkg_manager) and kbn-start.sh (inline PM detection)
#  must agree, so the second is checked for the same pattern.
# ============================================================

_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
source "$_SELF_DIR/test-helpers.sh"

eval "$(sed -n '/^detect_pkg_manager()/,/^}/p' "$PROJECT_DIR/dev-start.sh")"

describe "detect_pkg_manager"

it "returns pnpm when package.json declares packageManager pnpm@…"
  wt="$TEST_DIR/pm-pnpm-field"
  mkdir -p "$wt"
  echo '{ "version": "9.5.6", "packageManager": "pnpm@12.4.2" }' > "$wt/package.json"
  assert_eq "pnpm" "$(detect_pkg_manager "$wt")"

it "returns pnpm when only pnpm-lock.yaml exists"
  wt="$TEST_DIR/pm-pnpm-lock"
  mkdir -p "$wt"
  echo '{ "version": "9.5.6" }' > "$wt/package.json"
  touch "$wt/pnpm-lock.yaml"
  assert_eq "pnpm" "$(detect_pkg_manager "$wt")"

it "returns yarn for a yarn-based worktree"
  wt="$TEST_DIR/pm-yarn"
  mkdir -p "$wt"
  echo '{ "version": "9.6.0", "packageManager": "yarn@1.22.22" }' > "$wt/package.json"
  assert_eq "yarn" "$(detect_pkg_manager "$wt")"

it "kbn-start.sh uses the same detection pattern as dev-start.sh"
  assert_file_contains "$PROJECT_DIR/kbn-start.sh" '"packageManager" \*: \*"pnpm@'

print_summary
