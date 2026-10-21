# Kibana Dev Environment

A tmux + git worktrees setup that eliminates context-switching overhead, runs multiple Kibana instances simultaneously, and automates the full bootstrap → ES → Kibana startup sequence.

<a href="https://mgiota.github.io/kibana-env-setup/kibana-dev-workflow.html" target="_blank">📊 Visual workflow guide</a>

## What it does

- Creates two permanent tmux sessions: `kibana-main` (main branch) and `kibana-feat` (your active feature branch)
- Auto-runs `yarn kbn bootstrap` (or `pnpm kbn bootstrap` on branches that use pnpm — detected per worktree), starts ES, and launches Kibana once ES is ready — all from a single command. Supports both local ES and remote ES (oblt-cli / Elastic Cloud)
- Manages git worktrees so each session has its own isolated checkout
- Assigns ports automatically — `kibana-feat` always gets the default ports (5601/9200) so you never need to remember them
- Spins up temporary sessions for PR reviews or hotfixes alongside your active work

---

## Prerequisites

**Kibana repo** cloned on your machine — either the main repo or your own fork:
```bash
# elastic/kibana directly
git clone https://github.com/elastic/kibana.git ~/Documents/Development/kibana

# or your fork
git clone https://github.com/<your-username>/kibana.git ~/Documents/Development/kibana
```
> The path above matches the default in `dev-start.sh`. If you clone elsewhere, update `KIBANA_MAIN_DIR` in the script.

**tmux**
```bash
brew install tmux
```

Set up `~/.tmux.conf`. Here's a recommended config (feel free to customise):
```bash
unbind-key C-b
set -g prefix C-a          # prefix is Ctrl-a
bind-key C-a send-prefix
set -g mouse on
set -g mode-keys vi
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind | split-window -h
bind - split-window -v
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "pbcopy"
```

**nvm** — the scripts use `nvm use` to load the correct Node version from `.nvmrc`. Make sure nvm is installed and working.

**`~/bin` on your PATH** — add this to `~/.zshrc` if not already there:
```bash
export PATH="$HOME/bin:$PATH"
```

**`/etc/hosts`** — add these entries for the local hostnames:
```
127.0.0.1 kibana-main.local
127.0.0.1 kibana-feat.local
```

---

## One-time setup

**1. Clone the repo** somewhere convenient, e.g.:
```bash
git clone <repo-url> ~/Documents/Development/AI_projects/kibana-env-setup
```

**2. Run the setup wizard** — configures paths, ports, and creates symlinks:
```bash
cd ~/Documents/Development/AI_projects/kibana-env-setup
./dev-start.sh setup
```

The wizard asks for your Kibana repo path, worktree directory, and ports, then writes `~/.kibana-dev.conf` and sets up all symlinks automatically. Press Enter at each prompt to accept the defaults. To reconfigure later, just run `setup` again.

> **Manual setup:** If you prefer, copy `kibana-dev.conf.example` to `~/.kibana-dev.conf` and edit it, then create the symlinks yourself. See the example file for all available settings.

**3. Kibana config template**

`kibana.dev.yml.template` lives in this repo and is picked up automatically — no copying needed. When a session is created, the script generates a `config/kibana.dev.yml` in each worktree by replacing the `__KIBANA_PORT__` and `__ES_PORT__` placeholders with the correct values.

To customise defaults (credentials, Fleet config, remote ES, etc.), edit `kibana.dev.yml.template` in the repo directly.

To propagate template changes to all running sessions without tearing them down:
```bash
vim kibana.dev.yml.template          # add a logger, feature flag, etc.
~/dev-start.sh sync                  # regenerate kibana.dev.yml in all worktrees
~/dev-start.sh restart feat          # restart to pick up changes
```

> **Note on config regeneration:**
> - `switch` — always regenerates `kibana.dev.yml`. Without `--remote`, generates local ES config from template. With `--remote`, generates from `~/.kibana-remote-es.yml`. This means you can freely switch between local and remote by re-running `switch` with or without the flag.
> - `new` — if `kibana.dev.yml` already exists (e.g. from a previous run), it is left untouched and a warning is shown (unless `--remote` is passed, which always regenerates). Delete it and re-run if you want to regenerate from the template with fresh ports.
> - `dev-start.sh` (no args), `kibana-main` — only generates if the file doesn't exist. An existing config is always left untouched.
> - `dev-start.sh` (no args), `kibana-feat` — keeps the existing config if ports are correct. Regenerates automatically if ports are wrong.

**5. Switch to your first feature branch:**
```bash
~/dev-start.sh switch feature/your-branch
```

This creates the worktree, generates the config files, and sets up the `kibana-feat` session.

---

## Running

```bash
~/dev-start.sh
```

That's it for your morning start. It creates any missing sessions and attaches to `kibana-feat`. ES and Kibana start automatically.

---

## Commands

```bash
~/dev-start.sh                            # start/attach all sessions
~/dev-start.sh switch <branch>            # replace kibana-feat with a new branch (local ES)
~/dev-start.sh switch <branch> --remote   # switch with remote ES (reads ~/.kibana-remote-es.yml)
~/dev-start.sh new <branch>               # spin up a temporary session (PR review, hotfix)
~/dev-start.sh new <branch> --full        # temporary session with full layout (checks + ftr)
~/dev-start.sh new <branch> --remote      # temporary session with remote ES
~/dev-start.sh new <branch> --full --remote  # full session + remote ES
~/dev-start.sh sync                       # regenerate kibana.dev.yml from template (all sessions)
~/dev-start.sh sync feat                  # regenerate for a specific session
~/dev-start.sh sync main --remote         # switch kibana-main to remote ES
~/dev-start.sh sync main --local          # switch kibana-main back to local ES
~/dev-start.sh sync <branch>              # worktree with no kibana.dev.yml: generates one with fresh ports (then: restart <session>)
~/dev-start.sh status                     # health check — ping ES + Kibana for all sessions
~/dev-start.sh restart main               # restart ES + Kibana in kibana-main
~/dev-start.sh restart feat               # restart ES + Kibana in kibana-feat
~/dev-start.sh restart slo-crash          # restart a hotfix session
~/dev-start.sh restart feat --no-watch    # one-off restart without file watcher (QA / FSEvents workaround)
~/dev-start.sh clean                      # list ES data folders + sizes
~/dev-start.sh clean main                 # delete ES data for kibana-main
~/dev-start.sh clean feat                 # delete ES data for current feat branch
~/dev-start.sh clean all                  # delete ALL ES data
~/dev-start.sh renew                      # refresh remote ES creds (auto-creates cluster if gone)
~/dev-start.sh renew --cluster-name <n>   # refresh with explicit cluster name
~/dev-start.sh renew --session feat       # only update feat session (others keep current cluster)
~/dev-start.sh setup                      # interactive config wizard (paths, ports, symlinks)
~/dev-start.sh kill <branch>              # kill session + remove worktree
~/dev-start.sh kill-all                   # kill all kibana-* sessions
~/dev-start.sh prune                      # remove orphaned worktrees (no active session)
~/dev-start.sh list                       # show sessions, worktrees, port assignments + warnings
~/dev-start.sh attach <branch>            # attach to an existing temporary session
~/dev-start.sh help                       # usage
```

### `switch` vs `new`

| Command | Use when |
|---|---|
| `switch <branch>` | Starting a new feature. Replaces `kibana-feat` — the new branch gets the default ports (5601/9200) automatically. |
| `new <branch>` | Need to run another branch alongside your current work — PR review, hotfix, testing a colleague's branch. |

Both commands auto-create the branch from `upstream/main` if it doesn't exist locally or on origin — no manual branch setup needed. For `switch`, the branch check happens before any session or worktree is torn down, so if it fails your current `kibana-feat` is left untouched.

---

## Port assignments

| Session | Kibana | ES | Host |
|---|---|---|---|
| `kibana-feat` | 5601 | 9200 | kibana-feat.local |
| `kibana-main` | 5602 | 9201 | kibana-main.local |
| `kibana-<branch>` | 5603+ (auto) | 9202+ (auto) | localhost |

`~/dev-start.sh list` shows current port assignments and warns if any `kibana.dev.yml` has mismatched ports.

---

## Session layout

Each session has the same window structure:

| # | Window | Panes |
|---|---|---|
| 0 | servers | left: ES + bootstrap · right: Kibana (auto-started). Detects remote ES and skips local ES. |
| 1 | cursor | left: cursor-agent · right: shell |
| 2 | scripts | left: `run-data synthetics` · right: `run-data slo` (pre-populated, press Enter to run) |
| 3 | git | single pane |
| 4 | editor | single pane |

Full sessions (`kibana-feat`, `kibana-main`, or `new --full`) also get:

| # | Window | Panes |
|---|---|---|
| 5 | checks | top-left: eslint · top-right: type check · bottom: jest |
| 6 | ftr | left: ftr server · right: ftr runner |

The `checks` window uses `run-checks.sh` — a helper script that scopes lint, type check, and jest to files/plugins changed on your branch (via `git merge-base HEAD upstream/main`). Press Enter in any pane to run that check.

---

## Daily workflow

**Morning:**
```bash
~/dev-start.sh
```

**Switch between sessions:**
```
Ctrl-a s  →  select kibana-main or kibana-feat
```

**Review a colleague's PR:**
```bash
~/dev-start.sh new feat/colleague-branch
# when done:
~/dev-start.sh kill colleague-branch
```

**Start a new feature:**
```bash
~/dev-start.sh switch feature/new-feature
```

**End of day:**
```
Ctrl-a d   # detach — sessions keep running
```

---

## Key tmux shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl-a s` | Session switcher |
| `Ctrl-a w` | Window overview |
| `Ctrl-a d` | Detach |
| `Ctrl-a [` | Scroll / copy mode |
| `Ctrl-a 0-9` | Jump to window by number |
| `Ctrl-a \|` | Split pane vertically |
| `Ctrl-a -` | Split pane horizontally |

---

## Remote ES (oblt-cli / Elastic Cloud)

Use the `--remote` flag to connect to a remote ES cluster instead of starting a local one:

```bash
~/dev-start.sh switch <branch> --remote
~/dev-start.sh new <branch> --remote
```

### Setup & renewal

The `renew` command pulls fresh credentials from oblt-cli and writes them to `~/.kibana-remote-es.yml` automatically:

```bash
~/dev-start.sh renew                                  # auto-detects cluster from oblt-cli
~/dev-start.sh renew --cluster-name edge-oblt         # explicit cluster name
~/dev-start.sh renew --cluster-name edge-oblt --save  # also save the name for next time
~/dev-start.sh renew --session feat                   # only update feat (others keep current cluster)
```

The cluster name is resolved in this order: `--cluster-name` flag → saved name in `~/.kibana-dev.conf` → auto-detected from `oblt-cli cluster list`.

If no cluster is found (e.g. it expired and was destroyed), `renew` offers to create a new one automatically using `oblt-cli cluster create`. The create command is configurable via `OBLT_CLUSTER_CREATE_CMD` in `~/.kibana-dev.conf` (defaults to `oblt-cli cluster create ccs --remote-cluster=edge-lite-oblt`). Cluster creation is async — you'll get a Slack notification when it's ready, then run `renew` again to fetch the credentials. The same offer appears if `renew` has a saved cluster name but fetching secrets fails (likely because the cluster was destroyed).

**Version mismatch detection:** After verifying reachability, `renew` queries the remote ES version and compares it against the local Kibana version (from `package.json`). If `elasticsearch.ignoreVersionMismatch: true` is set (which it is by default — see below), the mismatch is shown as an informational note since Kibana will work fine. If the flag is not set and the major.minor versions don't match, `renew` checks `oblt-cli cluster list` for other existing clusters and offers to switch to one. If no other clusters exist, it offers to destroy the old cluster and create a new one. If other sessions (hotfix worktrees) still match the old ES version, `renew` shows which sessions are affected and adjusts the options accordingly.

**ignoreVersionMismatch:** `generate_remote_kibana_dev_yml` automatically injects `elasticsearch.ignoreVersionMismatch: true`, `server.versioned.versionResolution: oldest`, and `server.oas.enabled: true` into every remote session's `kibana.dev.yml` if they're not already present in `~/.kibana-remote-es.yml`. This is necessary because oblt-cli clusters often run a different minor version than the Kibana branch under development.

By default, `renew` regenerates `kibana.dev.yml` for **all** compatible remote sessions. Use `--session <target>` to limit regeneration to a single session (`main`, `feat`, or a branch name) — other sessions keep their current cluster credentials. This is useful when you want different sessions pointing at different clusters (e.g. testing expired certificates, schema changes, or different ES versions). Sessions whose Kibana version doesn't match the new cluster's ES version are skipped automatically. After renewing, restart to pick up the new credentials:
```bash
~/dev-start.sh renew
~/dev-start.sh restart feat
```

**Manual alternative:** Copy `kibana-remote-es.yml.example` to `~/.kibana-remote-es.yml` and paste your oblt-cli output there. The `server:` block is automatically stripped and replaced with the correct port. Everything else is kept: ES connection, monitoring indices, APM sources, encryption keys, uptime config, uiSettings, etc.

### How it works

When `--remote` is passed, `dev-start.sh` generates `kibana.dev.yml` using the credentials from `~/.kibana-remote-es.yml` instead of the local ES template. `kbn-start.sh` auto-detects the remote URL and skips `yarn es snapshot` (`pnpm es snapshot` on pnpm branches), starting Kibana directly.

**yarn vs pnpm:** newer Kibana branches (e.g. 9.5.x) use pnpm, older ones still use yarn. `kbn-start.sh` picks the right one per worktree (pnpm if `package.json` declares `"packageManager": "pnpm@…"` or `pnpm-lock.yaml` exists) and runs `corepack enable` if `pnpm` isn't available for the active Node version.

**Per-port session cookie:** browser cookies are scoped by host, not port, so two instances on `localhost` (e.g. 5601 and 5607) would share Kibana's default `sid` cookie and log each other out. `kbn-start.sh` passes `--xpack.security.cookieName=sid-<kibana-port>` so every instance has its own session. Restart Kibana (and clear the old `sid` cookie once) after upgrading.

Without `--remote`, the default local ES setup is used. To switch between local and remote, just re-run `switch` with or without the flag — no manual config editing needed.

Both YAML formats are detected by `kbn-start.sh`:
- **Template format**: `elasticsearch.hosts:` → `- "http://..."`
- **oblt-cli format**: `elasticsearch:` → `hosts: https://...`

---

## Data ingestion (run-data.sh)

The scripts window has pre-populated commands for data ingestion. Press Enter when Kibana is ready — the script waits automatically by polling `/api/status`.

```bash
run-data.sh slo          # ingest SLO fake_stack data via data_forge.js
run-data.sh synthetics   # create synthetics private location (Fleet Server + Agent)
run-data.sh fleet-reset  # wipe all Fleet state (monitors, private locations, agents, policies, .fleet-* indices)
```

**Multiple Kibanas / persistent containers:** the Kibana private-location script hardcodes Fleet Server port 8220 and `docker run --rm`, so only one instance can use it and its containers vanish when Docker stops. `run-data.sh synthetics` therefore starts its own `fleet-server-<port>` / `elastic-agent-<port>` containers for every instance, on a Fleet Server port derived from the Kibana port (`8220 + port − 5601`, e.g. 5601 → 8220, 5607 → 8226), with `--restart unless-stopped` so they survive Docker restarts. `run-data.sh synthetics --legacy` runs the stock Kibana script instead (fallback). `reset`, `dev-start.sh kill <branch>` and `switch` remove only that instance's containers. Re-run `run-data synthetics` after an ES data reset or a branch/version switch (stale enrollment, pinned image version). `dev-start.sh` writes the matching port into the `xpack.fleet.fleetServerHosts` entry of `kibana.dev.yml` (template placeholder `__FLEET_SERVER_PORT__`); worktrees generated earlier still have `8220` there and must be edited to their port (and Kibana restarted), otherwise agents check in to the wrong Fleet Server and stay "Updating".

`run-data.sh` reads ES host and credentials from `config/kibana.dev.yml` at runtime, so it works with both local and remote ES. For remote clusters, it automatically reduces concurrency and payload size to avoid timeouts. Data ingestion always uses the `elastic` superuser (same password as in the config) since service accounts like `kibana_system_user` lack write permissions on data indices.

**Remote-only Synthetics monitors (CCS testing):** `generate-monitors.js --remote-only` skips Kibana entirely and writes mock result docs only to the ES you point `--elasticsearch-host` at (e.g. a second local ES acting as the remote). A Kibana that has that cluster as a remote shows them as remote-only monitors (no local config). Optional `--remote-kibana-url` stores a `kibanaUrl` on each doc for deep links. `--allow-unenrolled` lets the script use private locations that have no enrolled agent (handy for a plain local Kibana). With `--remote-only`, `--location-label "Frankfurt"` sets the location shown on the remote cards and `--name-prefix "[EU] "` makes remote monitor names distinct from local ones, `--limit N` keeps only the first N generated monitors (to fill an Overview grid exactly), `--no-tags` omits tags so the type and Remote badges stay on one row, and `--down "PostgreSQL"` forces matching monitors to be down (red card + error points; repeat the flag on every re-run). `--history-days N` backfills older checks (one per 30 min, up to N days back) so duration trends and sparklines look populated; run it once, not in a refresh loop (re-running adds duplicate history). Example: `node generate-monitors.js --remote-only --minimal --elasticsearch-host http://localhost:9500 --elasticsearch-username elastic --elasticsearch-password changeme`.

**Synthetics:** `run-data.sh synthetics` creates a private location with Fleet Server + Elastic Agent using the Kibana `synthetics_private_location.js` script. Works on both local and remote ES — the script receives credentials via `--kibana-password` so it handles both cases. Before launching it, the command checks that Docker is responding, warns about stale Fleet/Agent containers, refreshes both agent images (`elastic-agent` + `elastic-agent-complete`, at most every 12h; `RUN_DATA_SKIP_PULL=1` to skip), calls `/api/fleet/setup` (local and remote), waits for `fleet-server-policy`, and afterwards verifies the synthetics agent is healthy (a stale cached image makes `synthetics/*` components crash with "seccomp policy is already registered" and monitors stay Pending). Note: `generate-monitors.js` mock data can make monitors look Up even if the agent is broken. If it still fails, it prints the common causes: exit `125` = `docker run` failed (Docker down, stale container/port 8220, image pull), exit `143` = Fleet Server timed out after ~120s (usually missing `fleet-server-policy` — restart Kibana). Details in `kibana-dev-env/references/troubleshooting.md`.

**Fleet reset:** If you see "Cannot read existing Message Signing Key pair" errors, the remote ES has stale Fleet state from a previous Kibana. Run `run-data.sh fleet-reset` to wipe all Fleet state — it deletes synthetics monitors, private locations, Fleet agents, agent policies, Fleet system index data, and `.fleet-*` ES indices — then restart Kibana so preconfiguration runs fresh.

### Heartbeat / k8s autodiscovery monitors

`run-data.sh synthetics heartbeat` sets up **read-only "heartbeat" monitors** — pings shipped straight to `synthetics-*` by an Elastic Agent running Kubernetes autodiscovery, with **no Kibana saved object** behind them. This is the input the Synthetics app's heartbeat-monitor surfacing consumes, so it's what you need to review/verify that feature.

**One-shot (recommended):** `up` runs the whole pipeline — starts minikube (if needed), deploys the OpenTelemetry demo (if the namespace is missing), deploys the Agent, annotates the Services, waits, and verifies:

```bash
# local ES
run-data.sh synthetics heartbeat up

# remote / oblt-cli ES (superuser is `admin`, password in kibana.dev.yml's loginAssistanceMessage)
DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data.sh synthetics heartbeat up
```
> `up` reuses `DATA_USERNAME`/`DATA_PASSWORD` for the otel-demo deploy too (it exports them as `KIBANA_*`/`ELASTICSEARCH_*`), so one credential set drives everything. Override the post-annotate wait with `HB_WAIT=<seconds>` (default 75).

> **Local ES:** the in-cluster Agent can't reach `localhost` (that's the pod itself), so for a local ES host the script rewrites `localhost`/`127.0.0.1` to `host.minikube.internal` in the Agent manifest only. ES must also listen beyond loopback — add `ES_BIND_ALL=true` to `~/.kibana-dev.conf` once (`kbn-start.sh` then starts local ES with `-E network.host=0.0.0.0`; ignored with remote ES) and restart ES. This exposes dev ES (default creds) on your network. Otherwise the Agent logs `dial tcp …:9200: connection refused` and no pings land (check with `run-data.sh synthetics heartbeat status`).

Autodiscovery needs *live* k8s Services to watch (which oblt-cli's indexed oteldemo data can't provide), which is why `up` deploys the demo into minikube.

**Individual steps** (if you'd rather drive it manually, or minikube + otel demo are already up):
```bash
run-data.sh synthetics heartbeat deploy     # install synthetics pkg, create API key, deploy Agent to minikube
run-data.sh synthetics heartbeat annotate   # annotate otel-demo Services → autodiscovered monitors start pinging
run-data.sh synthetics heartbeat verify     # confirm synthetics-* pings landed (+ location/space fields; FRESH/STALE verdict)
run-data.sh synthetics heartbeat break <s>  # inject a failure: dead-key (default) | agent-down | unannotate
run-data.sh synthetics heartbeat fix <s>    # restore from a break scenario (same names)
run-data.sh synthetics heartbeat clear      # delete only the ping data (monitors vanish from UI; Agent repopulates)
run-data.sh synthetics heartbeat status     # show Agent pod + recent logs
run-data.sh synthetics heartbeat reset      # full teardown: delete Agent, annotations, pings, and API key
```

Pings land within ~1 min of `annotate`. See `kibana-dev-env/references/heartbeat-autodiscovery.md` for the full runbook and troubleshooting (minikube stale kubeconfig, `otel_demo.js` 401s, etc.).

---

## Branch-scoped checks (run-checks.sh)

The checks window runs lint, type check, and jest scoped to files and plugins changed on your branch (compared to `upstream/main` via `git merge-base`). Each check is in its own pane — press Enter to run.

```bash
run-checks.sh lint       # eslint on changed .ts/.tsx/.js files
run-checks.sh typecheck  # tsc per changed plugin
run-checks.sh jest       # jest per changed plugin
```

---

## Starting fresh (clean ES data)

ES data is stored outside the Kibana repo at `~/Documents/Development/es_data/` — one subfolder per session (e.g. `main-cluster`, `slo-filters`). This avoids polluting git status.

To wipe a cluster and start fresh:
```bash
~/dev-start.sh clean              # see what's there + sizes
~/dev-start.sh clean main         # wipe kibana-main data
~/dev-start.sh clean feat         # wipe current feat branch data
~/dev-start.sh clean all          # wipe everything
```

Next time ES starts, it creates a fresh empty cluster automatically.

---

## Tests

The project includes a test suite that validates config generation, remote ES detection, credential parsing, argument parsing, and port assignment logic. Run it with:

```bash
./tests/run-tests.sh              # all tests
./tests/run-tests.sh config       # only config generation tests
./tests/run-tests.sh detection    # only ES detection tests
./tests/run-tests.sh run-data     # only run-data parsing tests
./tests/run-tests.sh arg          # only argument parsing tests
```

The tests use a lightweight bash framework (`tests/test-helpers.sh`) — no external dependencies. Each test file creates temporary directories, generates configs, and asserts expected behaviour. Safe to run at any time.

| Suite | What it covers |
|---|---|
| `test-config-generation` | Local + remote `kibana.dev.yml` generation, port substitution, placeholder removal, server block stripping, switching between local/remote |
| `test-es-detection` | Grep pattern matching for both YAML formats (template + oblt-cli), localhost/127.0.0.1 filtering, commented lines, edge cases |
| `test-run-data` | Credential parsing, remote detection, concurrency reduction, password defaults, synthetics guard |
| `test-arg-parsing` | `kbn-start.sh` flag parsing, `switch`/`new` flag parsing, port reservation logic |
| `test-clean` | ES data listing, deletion by name/alias, `clean all`, edge cases |
| `test-config-loading` | `~/.kibana-dev.conf` loading, defaults, full/partial overrides, empty config |
| `test-renew` | `renew` command: argument parsing, credential fetch (mocked oblt-cli), config saving, error handling, version mismatch detection |

---

## Known behaviours & gotchas

- **Branch names with dots** (e.g. `9.3`) — tmux can't use dots in session names. The script converts them to hyphens: `kibana-9-3`. The worktree folder keeps the original name.
- **Sessions survive terminal close** — tmux keeps everything running. Only a machine reboot kills sessions.
- **`list` only shows active sessions** — dead sessions are filtered out of the port assignments table automatically.
- **Remote ES: `kibana_system_user` can't write data** — `run-data.sh` uses the `elastic` superuser automatically. If you get 401 errors, verify the `elastic` user has the same password as your config.
- **encryptedSavedObjects errors with remote ES** — expected. Alerts from a different Kibana instance were encrypted with a different key. Harmless — new rules you create locally work fine.
