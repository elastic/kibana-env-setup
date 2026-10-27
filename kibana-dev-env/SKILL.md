---
name: kibana-dev-env
description: >
  Kibana local development environment manager — tmux sessions, git worktrees,
  ES + Kibana lifecycle, remote ES credentials, scoped checks, data ingestion,
  and Synthetics failure scenario injection. Use this skill whenever the developer
  mentions: starting Kibana, switching branches, managing worktrees, running ES
  locally or remotely, creating SLOs, setting up synthetics private locations,
  ingesting test data, breaking/fixing Synthetics state, triggering failure
  scenarios, running scoped lint/typecheck/jest, checking session health, or
  anything related to their local Kibana dev workflow. Also trigger when the
  developer asks about ports, tmux sessions, kibana.dev.yml, remote ES
  configuration, oblt-cli credentials, or bootstrapping their environment.
---

# Kibana Dev Environment

This skill manages a tmux-based Kibana development environment that supports multiple
concurrent branches via git worktrees, each with isolated ES + Kibana instances on
separate ports. It handles the full lifecycle: session creation, branch switching,
server restart, credential renewal, health checks, data ingestion, and scoped code
quality checks.

## Installation

The `scripts/` folder contains all the scripts and config templates needed to run
this environment. All scripts must stay together in the same directory — `dev-start.sh`
locates templates and helpers relative to its own location.

```bash
# From the scripts/ folder, make the scripts executable
chmod +x scripts/*.sh

# Create your config (edit paths and ports to match your machine)
cp scripts/kibana-dev.conf.example ~/.kibana-dev.conf

# Run the setup wizard
scripts/dev-start.sh setup
```

When running commands on behalf of the developer, always use the absolute path to
`scripts/dev-start.sh` based on where this skill is installed. Do not ask the
developer to set up aliases or symlinks — just use the full path directly.

## Important: always use `dev-start.sh`

Never suggest raw tmux commands (`tmux attach`, `tmux send-keys`, etc.) to the
developer. Always use the `dev-start.sh` CLI — it wraps all tmux operations and
handles port assignments, config generation, and process lifecycle automatically.
Similarly, `kbn-start.sh` handles `yarn start` with the correct port arguments —
never suggest running `yarn start` directly without port flags. Newer Kibana branches
(e.g. 9.5.x) use **pnpm** instead of yarn; `kbn-start.sh` detects this per worktree
(`"packageManager": "pnpm@…"` in `package.json` or a `pnpm-lock.yaml`) and uses
`pnpm kbn bootstrap` / `pnpm es snapshot` / `pnpm start`, running `corepack enable`
if pnpm is missing. Don't tell the user to run yarn on a pnpm branch (or vice versa).

`kbn-start.sh` also passes `--xpack.security.cookieName=sid-<kibana-port>` so multiple
instances on `localhost` don't share the default `sid` cookie (cookies are scoped by
host, not port — otherwise logging in to one instance logs you out of the others).
If a user reports being logged out of one Kibana when logging in to another, restart
that instance via `kbn-start.sh`; don't suggest editing `kibana.dev.yml`.

`kbn-start.sh` also handles Node version switching (`nvm use`) automatically before
starting ES or Kibana. Never tell the developer to run `nvm use` manually — the
scripts take care of it.

## Important: never hardcode paths

Always refer to paths using their config variable names (`KIBANA_MAIN_DIR`,
`WORKTREE_BASE`, etc.) from `~/.kibana-dev.conf`. Never hardcode paths like
`~/Documents/Development/kibana` in responses — the developer's paths may differ.

## Important: auto-detect, don't ask

When the developer asks to create resources (SLOs, private locations, etc.) or
interact with a running Kibana, read `config/kibana.dev.yml` and `~/.kibana-dev.conf`
automatically to get ports, credentials, and ES host. Don't ask the developer to
look these up — the config files have everything.

## Important: always use ports from config, not defaults

This setup runs multiple Kibana instances on different ports (feat=5601, main=5602,
hotfix=5603+). When making Kibana API calls — whether directly or through other
skills like `observability-manage-slos` or `kibana-api` — always read the port and
credentials from `config/kibana.dev.yml` in the current working directory. Never
fall back to hardcoded defaults like `localhost:5601` or `elastic:changeme`.

The `kibana-api` utility in the Kibana repo only tries `localhost:5601` — this is
wrong for main and hotfix sessions. This skill's config detection takes precedence:
read `config/kibana.dev.yml` for the correct port, then use it for all API calls.

## Architecture

```
dev-start.sh (CLI router)
  ├── kbn-start.sh    (bootstrap ES + Kibana in tmux panes)
  ├── run-checks.sh   (scoped lint / typecheck / jest)
  └── run-data.sh     (SLO + synthetics data ingestion + failure scenarios + full reset)
```

All scripts share config from `~/.kibana-dev.conf` (paths, ports, cluster name)
and per-worktree `config/kibana.dev.yml` (ES connection, Kibana settings).

### Session structure

Each tmux session has these windows:

| Window    | Purpose                                    |
|-----------|--------------------------------------------|
| servers   | Pane 0: ES (or kbn-start.sh), Pane 1: Kibana (`yarn start` / `pnpm start` with port flags) |
| cursor    | IDE MCP config, KIBANA_URL set              |
| scripts   | Pre-populated data ingestion commands       |
| git       | Git operations, branch management           |
| editor    | File editing                                |
| checks    | Lint / typecheck / jest (full sessions)     |
| ftr       | Functional test runner (full sessions)      |

Lightweight sessions (created with `new`) have: servers, cursor, scripts, git, editor.

### Port assignments

Ports are configurable in `~/.kibana-dev.conf`. The defaults are:

- **kibana-feat**: Kibana 5601, ES 9200 (the "primary" ports — feat is the active dev session)
- **kibana-main**: Kibana 5602, ES 9201 (secondary, for main branch)
- **Hotfix sessions**: auto-assigned starting from 5603/9202

Always read `~/.kibana-dev.conf` or `config/kibana.dev.yml` for the actual ports
rather than assuming defaults — the developer may have customized them.

## Commands

Run all commands as `~/dev-start.sh <command>`:

### Sessions
| Command | What it does |
|---------|-------------|
| *(no args)* | Start/attach all sessions + auto-recover orphaned worktrees |
| `switch <branch> [--remote\|--serverless[=oblt\|security\|es]]` | **Destructive** — kills kibana-feat, removes its worktree, creates a new one |
| `new <branch> [--full] [--remote\|--serverless[=type]]` | **Non-destructive** — creates an additional session alongside existing ones |
| `attach <branch>` | Attach to an existing session |
| `kill <branch>` | Kill session + remove worktree |
| `kill-all` | Kill ALL kibana-* sessions |
| `recover` | Recreate sessions for orphaned worktrees (auto-start ES + Kibana) |
| `prune` | Remove orphaned worktrees (no active tmux session) |

#### Choosing `new` vs `switch`

**Default to `new`** unless the developer explicitly asks to replace the current feat session.
`switch` kills the running kibana-feat session and removes its worktree — this is destructive
and the developer may have unsaved work, running servers, or open terminals in that session.

| Developer says | Use | Why |
|---|---|---|
| "start working on a new branch" | `new` | Preserves current sessions |
| "create a session for branch X" | `new` | Additive, no disruption |
| "I want to work on feature/X" | `new` | Ambiguous → default to non-destructive |
| "switch feat to branch X" | `switch` | Explicitly asked to replace feat |
| "replace my current feature branch" | `switch` | Explicitly asked to replace feat |

When in doubt, ask: "Do you want a new session alongside kibana-feat, or replace it?"

### Operations
| Command | What it does |
|---------|-------------|
| `restart <main\|feat\|branch>` | Restart ES + Kibana (handles graceful shutdown, auto-rebuilds session if panes are missing) |
| `renew [--cluster-name <n>] [--session <t>] [--save]` | Refresh remote ES credentials; `--session` limits to one session (main\|feat\|branch) |
| `sync [target] [--remote\|--local]` | Regenerate kibana.dev.yml from template (target: main\|feat\|branch\|all). For a branch worktree with no kibana.dev.yml, generates one with fresh ports |
| `clean [main\|feat\|name\|all]` | List or delete ES data folders |

### Info
| Command | What it does |
|---------|-------------|
| `list` | Sessions, worktrees & port assignments |
| `status` | Health check — ping ES + Kibana |
| `setup` | Interactive config wizard |

### Navigating sessions

To switch between sessions and windows, the developer uses tmux shortcuts:
- **Ctrl-a s** — session switcher (pick kibana-main, kibana-feat, etc.)
- **Ctrl-a w** — window overview within a session

To attach to a session from outside tmux: `~/dev-start.sh attach feat`

## Local vs Remote ES

**Local ES** — `kbn-start.sh` runs `yarn es snapshot` in pane 0, watches for the
trigger string `"succ kbn/es setup complete"`, then sends `yarn start` (with correct
port arguments) to pane 1.

**Remote ES** — When `--remote` is passed, `dev-start.sh` generates `kibana.dev.yml`
using credentials from `~/.kibana-remote-es.yml` (fetched via `oblt-cli` or pasted
manually). `kbn-start.sh` detects the remote URL and skips local ES startup.
Fleet config (agent policies, Fleet Server, package installations) is also included
in the remote `kibana.dev.yml` — the Fleet ES output host points to the remote
cluster instead of `host.docker.internal`.

**Serverless** — `--serverless[=oblt|security|es]` (default `oblt`) writes a minimal
`kibana.dev.yml` with a `# Serverless: <type>` marker and an `https://localhost:<es-port>`
host. `kbn-start.sh` detects it, runs `yarn es serverless --kill --projectType <mapped> --port <es-port>`
(Docker, HTTPS; `oblt`→`observability`, `es`→`elasticsearch`) in pane 0, waits for ES
health, then starts `yarn serverless-<type>` in pane 1. Serverless Kibana needs the mock
IdP, so `--mockIdpPlugin.enabled=false` is dropped from `KBN_EXTRA_ARGS` (otherwise it
dies with "`xpack.security.uiam.enabled` must be `true`"). Only one serverless session at
a time (fixed container names: `es01…`, `uiam`, `uiam-cosmosdb`). `restart`/`kill`/`switch`
remove those containers rather than killing the port. Not available for `kibana-main`.
Memory is heavy (Docker ES nodes + one optimizer per Kibana): `list` prints a memory summary
and warns; stop idle sessions, use `restart <s> --no-watch`, and check `docker stats --no-stream`
(ES heap is fixed per node; Docker's memory setting is a ceiling that bounds VM growth, ~10-12 GB is enough).

### Credential renewal flow

When remote ES credentials expire or the cluster has been destroyed:

```bash
~/dev-start.sh renew              # auto-detects cluster, fetches fresh creds (all remote sessions)
~/dev-start.sh renew --session feat   # only update feat (others keep their current cluster)
~/dev-start.sh restart feat       # restart to pick up new credentials
```

`renew` auto-detects the cluster name from `oblt-cli cluster list`, fetches
credentials via `oblt-cli cluster secrets kibana-config`, writes to
`~/.kibana-remote-es.yml`, and regenerates `kibana.dev.yml` for compatible
remote sessions if credentials changed. Use `--session <target>` to limit
regeneration to a single session — other sessions keep their current cluster
credentials. This is useful when different sessions need to point at different
clusters (e.g. testing expired certificates, schema changes, or different ES
versions). Sessions whose Kibana version doesn't match the new cluster's ES
version are automatically skipped.

If no cluster exists (expired and destroyed), `renew` offers to create a new one
via `oblt-cli cluster create`. The create command is configurable in
`~/.kibana-dev.conf` via `OBLT_CLUSTER_CREATE_CMD`. Creation is async — run
`renew` again after the Slack notification confirms the cluster is ready.

`renew` also detects **version mismatches** between the remote ES cluster and
local Kibana (e.g. ES 9.4 vs Kibana 9.5 after a version bump on `main`). When
a mismatch is found, it checks `oblt-cli cluster list` for other existing
clusters and offers to switch to one if available. If no other clusters exist,
it offers to destroy and replace. If some sessions still match the old ES
version (e.g. a hotfix branch on 9.4), it shows which sessions are affected
and adjusts options accordingly — prioritising switching to an existing cluster.

## Data Ingestion

`run-data` must be run from within a Kibana repo directory. Auto-detect the correct
directory from `~/.kibana-dev.conf` (KIBANA_MAIN_DIR or WORKTREE_BASE) — don't tell
the developer to navigate there manually.

```bash
run-data slo                            # Ingest SLO fake_stack data via data_forge.js
run-data synthetics                     # Create synthetics private location (Fleet Server + Agent)
run-data synthetics break <scenario>    # Trigger a Synthetics failure scenario
run-data synthetics fix <scenario>      # Restore from a failure scenario
run-data synthetics reset               # Wipe all Fleet + Synthetics state (monitors, locations, agents, agent records, policies, .fleet-* indices, API key, orphaned data)
run-data synthetics heartbeat <cmd>     # k8s autodiscovery heartbeat monitors (up/deploy/annotate/verify/clear/status/reset)
```

`run-data.sh` reads ES host and credentials from `config/kibana.dev.yml`,
waits for Kibana readiness via `/api/status`, and uses the `elastic` superuser
(not `kibana_system_user`, which lacks write permissions).

**Synthetics private location:** Uses the Kibana `synthetics_private_location.js` script which
starts Fleet Server, enrolls an agent, and creates the private location. Credentials are passed
via `--kibana-password` so it works with both local and remote ES. Before launching it,
`run-data synthetics` checks the Docker daemon, warns about stale Fleet/Agent containers, calls
`/api/fleet/setup` (local and remote) and waits for `fleet-server-policy`. It also refreshes both agent
images (`elastic-agent` + `elastic-agent-complete`, at most every 12h; `RUN_DATA_SKIP_PULL=1` skips) and,
after enrolling, verifies the synthetics agent is healthy — a stale cached snapshot image makes
`synthetics/*` components crash ("seccomp policy is already registered") and monitors stay Pending.
Mock data from `generate-monitors.js` can make monitors look Up even if the agent is broken. If the script fails with
exit 125 (docker run failed) or 143 (Fleet Server timed out, usually missing `fleet-server-policy`),
see `references/troubleshooting.md` → "Synthetics private location fails".

**Heartbeat (minikube) with multiple Kibanas:** `run-data synthetics heartbeat deploy` names the
Agent and its resources per instance (`elastic-agent-synthetics-<kibana-port>`, manifest
`/tmp/kbn-dev-agent-synthetics-<port>.yaml`, API key `kbn-dev-synthetics-agent-<port>`), so each
worktree's ES gets its own Agent and heartbeat monitors are Up in both. Service annotations are
shared; `heartbeat reset` removes them only when no other instance's Agent remains. If heartbeat
monitors are stale in one Kibana but Up in another, the old single-name Agent was overwriting —
re-run `heartbeat deploy` in the stale worktree. Details: `references/heartbeat-autodiscovery.md`.

**Multiple Kibanas, persistent containers:** the Kibana script hardcodes Fleet Server host port 8220
and `--rm` containers, so it supports only one instance and its containers disappear when Docker
stops. `run-data synthetics` derives a Fleet Server port from the Kibana port in `kibana.dev.yml`
(`8220 + port - 5601`: 5601→8220, 5607→8226), creates the policy, location and enrollment token
via the API, and starts `fleet-server-<port>` / `elastic-agent-<port>` with `--restart
unless-stopped` for EVERY instance (they survive Docker restarts). `--legacy` runs the
stock Kibana script instead. `run-data synthetics reset`, `dev-start.sh kill <branch>` and `switch`
remove only the containers belonging to that instance. After an ES data reset or branch/version
switch, re-run `run-data synthetics` (stale enrollment, pinned image version). If a user's agents
vanished after Docker closed, they were `--rm` containers from the stock script — just re-run. `dev-start.sh` writes the
same port into `xpack.fleet.fleetServerHosts` in `kibana.dev.yml` (`__FLEET_SERVER_PORT__` in the
template). A worktree generated earlier still has `8220` there: agents then stay "Updating"/
"Unhealthy" because they check in to another instance's Fleet Server — edit the port and restart Kibana.
`run-data synthetics` now detects this (default `fleet_server_hosts` ≠ this instance's port): it aborts
before starting containers (and re-checks if the agent ends up unhealthy), printing the exact fix.
The host is preconfigured, so the Fleet API returns 403 on PUT — only `kibana.dev.yml` can change it.
Order: edit yml → `run-data synthetics reset` → restart Kibana → `run-data synthetics`.

For remote ES, it auto-reduces concurrency (payload 1000, concurrency 1,
events-per-cycle 10) to avoid timeouts.

### Synthetics failure scenarios

The `synthetics break` and `synthetics fix` subcommands inject and restore
Synthetics/Fleet failure states for testing diagnostic tooling. All scenarios are
reversible. Monitors created by `break` are tagged with `[BREAK]` in their name
so `fix` can clean them up.

```bash
run-data synthetics break <scenario>    # inject a failure
run-data synthetics fix <scenario>      # restore from a failure
run-data synthetics break all           # chaos mode — trigger all scenarios
run-data synthetics fix all             # full restore
run-data synthetics break help          # list available scenarios
```

Available scenarios:

| Scenario | Break effect | Fix action |
|----------|-------------|------------|
| `agent-offline` | Stops synthetics agent Docker container | Restarts stopped agent containers |
| `revision-mismatch` | Stops agent + creates monitor (policy rev diverges) | Cleans `[BREAK]` monitors + restarts agent |
| `zero-data` | Creates monitor on private location with agent down | Cleans `[BREAK]` monitors + restarts agent |
| `fleet-degraded` | Stops Fleet Server container | Restarts Fleet Server containers |
| `orphaned-data` | Creates + deletes monitor (data remains in ES) | Deletes orphaned check data from ES |
| `policy-disabled` | Disables Fleet package policy (monitor still enabled) | Re-enables disabled package policies |
| `orphaned-policy` | Deletes monitor SO from ES (package policy remains) | Deletes package policies with no monitor |
| `agent-unenrolled` | Force-unenrolls agent (monitors still configured) | Re-enrolls agent (full synthetics setup) |
| `service-disabled` | Disables Synthetics service (API key invalidated) | Re-enables Synthetics service |

Prerequisites: a working Synthetics setup with at least 1 private location,
1 enrolled agent, and 1-2 monitors. Run `run-data synthetics` first to provision.

### Remote-only monitors for CCS testing

`node generate-monitors.js --remote-only [--minimal] --elasticsearch-host <remote-es>`
does not call Kibana: it writes mock result docs (with stable `config_id`s, fake
location "Remote Location", optional `--remote-kibana-url` → `kibanaUrl`) to the given
ES only. A Kibana that has that ES configured as a remote cluster lists them as
remote-only monitors. Use it with a local CCS setup (second ES on 9500/9600) when
Kibana and the remote cluster must be on the same version.

Extra flags: `--location-label`, `--name-prefix`, `--limit N`, `--no-tags`,
`--down TEXT` (repeat on every re-run), and `--history-days N` (one-time backfill of
older checks, 1 per 30 min, so trends/sparklines look populated; don't put it in a
refresh loop). Docs include a `state` object so the "Error states" tile has a value.

### Heartbeat / k8s autodiscovery monitors

`run-data synthetics heartbeat` provisions **Elastic Agent–run synthetics monitors
that have no Kibana saved object** — the "Heartbeat / autodiscovery" case. An Agent
runs in minikube with the Kubernetes provider and `synthetics/http|tcp` inputs; it
autodiscovers annotated Services and ships pings straight to `synthetics-*` with no
saved object. This is the input the Synthetics app's read-only heartbeat-monitor
surfacing consumes.

```bash
run-data synthetics heartbeat up          # one-shot: minikube → otel demo → deploy → annotate → wait → verify
run-data synthetics heartbeat deploy      # install synthetics pkg, create scoped API key, deploy Agent
run-data synthetics heartbeat annotate    # annotate otel-demo Services → autodiscovered monitors
run-data synthetics heartbeat verify      # check synthetics-* pings (+ location/space fields; FRESH/STALE verdict)
run-data synthetics heartbeat break <s>   # inject a failure: dead-key (default) | agent-down | unannotate
run-data synthetics heartbeat fix <s>     # restore from a break scenario (same names)
run-data synthetics heartbeat clear       # delete only ping data (monitors vanish from UI; Agent repopulates)
run-data synthetics heartbeat status      # Agent pod + recent logs
run-data synthetics heartbeat reset       # full teardown: delete Agent, annotations, pings, API key
```

**`up` handles the prerequisites for you** — it starts minikube if needed and
deploys the OpenTelemetry demo (which supplies the Services to annotate) if its
namespace is missing, then runs deploy → annotate → verify. On remote/oblt-cli
ES pass the superuser, and `up` reuses those creds for the otel-demo deploy too
(exported as `KIBANA_*`/`ELASTICSEARCH_*`); tune the post-annotate wait with
`HB_WAIT=<seconds>` (default 75):

```bash
DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data synthetics heartbeat up
```

The individual subcommands above assume minikube is already running and the demo
is deployed (`node ./scripts/otel_demo.js --config config/kibana.dev.yml`).

Key facts the command handles automatically:
- Derives the Agent image from the repo's `package.json` (`<version>-SNAPSHOT`).
- Reads the ES host from `config/kibana.dev.yml` and points the Agent's output
  there (Agent and Kibana must share one cluster). For **local ES** it rewrites
  `localhost`/`127.0.0.1` to `host.minikube.internal` in the manifest only, since
  the in-cluster Agent can't reach the host's loopback; ES must also bind beyond
  loopback — set `ES_BIND_ALL="true"` in `~/.kibana-dev.conf` (kbn-start.sh then
  starts ES with `-E network.host=0.0.0.0`), then restart ES. Otherwise the Agent
  logs `connection refused`.
- Creates a scoped ES API key (`auto_configure`/`create_doc` on `synthetics-*`).
- These pings deliberately carry no `observer.geo.name` (location-less) and no
  `meta.space_id` (space-less), which is exactly what the read-only surfacing and
  the space-filter handling are tested against.

Full manual runbook and troubleshooting: read
`references/heartbeat-autodiscovery.md`.

### Data generated by `run-data slo`

The `slo` command uses `kbn-data-forge` (`x-pack/scripts/data_forge.js`) with the
`fake_stack` dataset and `good` event template. This generates data in the
`high-volume-metrics` index with fields like `http.response.status_code`,
`service.name`, etc.

### Creating SLOs

Data ingestion must happen **before** creating SLOs — there must be data in the
target index first. The standard workflow is:

1. Run `run-data slo` to ingest fake_stack data
2. Create an SLO via the Kibana API (see `references/kibana-api.md`)

When creating SLOs on data_forge data, ALWAYS use the **Admin Console Availability** pattern:
- **Indicator type**: `sli.kql.custom` (NOT `sli.apm.transactionDuration`)
- **Good query**: `http.response.status_code < 500`
- **Total query**: `http.response.status_code : *`
- **Index**: `high-volume-metrics` (NOT `metrics-apm*`)

This measures availability (% of non-5xx responses). This is the only SLO type that
works with kbn-data-forge fake_stack data. Do NOT use APM latency indicators
(`sli.apm.transactionDuration`) — the fake_stack dataset does not generate APM data,
so APM-based SLOs will have no matching data and will fail silently.

### Kibana API operations

For creating SLOs, private locations, or other resources via the Kibana API,
read `references/kibana-api.md` for endpoint details, required headers, and
example request bodies. When making API calls:

1. Read `config/kibana.dev.yml` to get the Kibana port and ES credentials
2. Verify Kibana is ready with `~/dev-start.sh status`
3. Use the `elastic` superuser for authentication
4. Always include `kbn-xsrf: true` header

## Code Quality Checks

```bash
run-checks lint       # ESLint on changed files (vs upstream/main)
run-checks typecheck  # TypeScript check on changed plugins
run-checks jest       # Unit tests on changed plugins
```

`run-checks.sh` uses `git merge-base` to scope checks to only the files and
plugins you've actually changed on your branch. It handles both committed and
untracked files.

## Configuration

### ~/.kibana-dev.conf

User-specific paths and ports. Created by `setup` wizard. Uses `${VAR:-default}`
pattern so every value is overridable:

```bash
KIBANA_MAIN_DIR="$HOME/Documents/Development/kibana"
WORKTREE_BASE="$HOME/Documents/Development/worktrees"
ES_DATA_BASE="$HOME/Documents/Development/es_data"
MAIN_KIBANA_PORT="5602"
MAIN_ES_PORT="9201"
FEAT_KIBANA_PORT="5601"
FEAT_ES_PORT="9200"
OBLT_CLUSTER_NAME="my-cluster"   # optional, for renew auto-detect
KBN_EXTRA_ARGS="--mockIdpPlugin.enabled=false"  # optional, extra flags for yarn start (do NOT add --no-watch here — use restart --no-watch for QA)
ES_BIND_ALL="true"   # optional, local ES only: start ES with network.host=0.0.0.0 so the minikube Agent (heartbeat monitors) can reach it; exposes ES on the network
```

### `--no-watch` (file watcher)

**Do not** persist `--no-watch` in `KBN_EXTRA_ARGS` during active development — it disables the dev file watcher, so server-side edits won't auto-restart Kibana.

Use it **only for a single restart** when needed (e.g. macOS FSEvents limit hit, or a one-off QA boot):

```bash
~/dev-start.sh restart feat --no-watch
```

This passes `--no-watch` to `yarn start` for that restart only; the next normal `restart feat` picks up hot-reload again.

**Agent rule:** When running the QA screenshot tools (`qa/run.sh`, `qa-feature.mjs`), do **not** edit `~/.kibana-dev.conf` to add `--no-watch`. If Kibana must be restarted before capture and FSEvents fails, use `restart <session> --no-watch` instead. After QA, restart without the flag if the developer is iterating on code.

### config/kibana.dev.yml

Per-worktree Kibana config. Generated from `kibana.dev.yml.template` (local ES)
or from `~/.kibana-remote-es.yml` (remote ES). Contains server port, ES hosts,
and any custom Kibana settings (logging, feature flags, etc.).

## Troubleshooting

For common issues and their solutions, read `references/troubleshooting.md`.

Key principle: always suggest `dev-start.sh` commands for fixes, not raw tmux
commands or manual `yarn start`. The scripts handle port assignments and process
management automatically.

## Working with Remote ES (`--remote`)

When a session uses `--remote`, Kibana connects to an external Elasticsearch cluster (typically an oblt-cli-managed Cloud deployment) via cross-cluster search (CCS). This changes how indices and data are addressed.

### Index patterns use a CCS prefix

Data on the remote cluster lives behind a `remote_cluster:` prefix. Standard local patterns do not work:

| Local pattern | Remote equivalent |
|---|---|
| `logs-*` | `remote_cluster:logs-*` |
| `metrics-apm*` | `remote_cluster:metrics-apm*` |
| `traces-apm*` | `remote_cluster:traces-apm*` |
| `filebeat-*` | `remote_cluster:filebeat-*` |

The exact prefix name (`remote_cluster`) varies by deployment. Check `config/kibana.dev.yml` — the `apm_sources_access.indices` and `uiSettings.overrides` sections show the correct prefix for the current cluster.

### Discovery before creating resources (SLOs, rules, etc.)

When creating SLOs, alerting rules, or any resource that references index patterns or field values, always discover real data first:

1. **Detect the CCS prefix** — inspect `config/kibana.dev.yml` or query existing SLOs:
   ```bash
   curl -u "$AUTH" -H "kbn-xsrf: true" "$KIBANA_URL/api/observability/slos?perPage=5" | \
     jq '.results[].indicator.params.index'
   ```

2. **Discover real service names** — query the target index for actual `service.name` values:
   ```bash
   curl -k -u "$AUTH" "$ES_URL/<index-pattern>/_search" \
     -H "Content-Type: application/json" \
     -d '{ "size": 0, "aggs": { "services": { "terms": { "field": "service.name", "size": 30 } } } }'
   ```

3. **Verify fields exist** — confirm filters reference real fields with data:
   ```bash
   curl -k -u "$AUTH" "$ES_URL/<index-pattern>/_search" \
     -H "Content-Type: application/json" \
     -d '{ "size": 0, "query": { "bool": { "filter": [
       { "term": { "service.name": "<service>" } },
       { "exists": { "field": "http.response.status_code" } }
     ] } } }'
   ```

Never use made-up service names or assume local index patterns when connected to a remote cluster. Creating resources against non-existent data produces `NO_DATA` entries that clutter the UI and waste transforms.

## First-time setup

```bash
~/dev-start.sh setup                    # config wizard: paths, ports, symlinks
~/dev-start.sh switch feature/my-branch # set your first feature branch
~/dev-start.sh                          # start everything
```
