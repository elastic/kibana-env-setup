# Troubleshooting

Common issues and their solutions when working with the Kibana dev environment.

## ES won't start

**Symptom:** ES hangs or fails to start in pane 0.

**Causes and fixes:**
- Port already in use: `lsof -ti :9200 | xargs kill -9` (replace with your ES port)
- Stale ES data: `~/dev-start.sh clean main` to wipe data and start fresh
- Wrong Node version: check `.nvmrc` and run `nvm use`
- ES data directory permissions: check `~/Documents/Development/es_data/` is writable

## Bootstrap fails: "packageManager … yarn@pnpm@…" / Corepack message

**Symptom:** `kbn-start.sh` fails at the bootstrap step with `This project's package.json defines "packageManager": "yarn@pnpm@…"` and a hint to run `corepack enable`.

**Cause:** The branch uses pnpm but an older copy of `kbn-start.sh` ran `yarn`. Current `kbn-start.sh` detects pnpm per worktree and runs `corepack enable` if needed.

**Fix:** Make sure `~/bin/kbn-start.sh` points at the current script, then re-run it. Manual equivalent in the worktree: `corepack enable && pnpm kbn bootstrap`. Corepack shims are per Node version, so a new `.nvmrc` version may need `corepack enable` again.

## Kibana pane is blank after restart

**Symptom:** After `restart`, ES starts but pane 1 (Kibana) doesn't run anything.

**Cause:** `kbn-start.sh` sends `yarn start` (or `pnpm start` on pnpm branches) to pane 1 via `tmux send-keys`. If pane 1
still has a dying process (Kibana's 30-second graceful shutdown), the command gets lost.

**Fix:** Run `~/dev-start.sh restart feat` again — it handles port polling, force-kill,
and pane cleanup automatically. If it still happens, attach to the session with
`~/dev-start.sh attach feat`, navigate to pane 1 (Ctrl-a followed by arrow key), press
`Ctrl-C` to clear the old process. Note: don't just run `yarn start` manually — the
correct command includes port flags that `kbn-start.sh` sets automatically. Run
`~/dev-start.sh restart feat` instead.

## kibana_system_user can't write data

**Symptom:** 401 or 403 errors when ingesting data via `run-data.sh`.

**Cause:** The `kibana_system_user` account doesn't have write permissions on data indices.

**Fix:** `run-data.sh` automatically uses the `elastic` superuser. If you're running
ingestion manually, use `-u "elastic:changeme"` (local) or the elastic user password
from your remote config.

## Remote ES: version mismatch (incompatible)

**Symptom:** Kibana shows "This version of Kibana (v9.5.0) is incompatible with the
following Elasticsearch nodes in your cluster: v9.4.0".

**Cause:** Kibana `main` bumped to a new minor version but your remote ES cluster is
still on the previous version. Kibana requires matching major.minor versions.

**Fix:** Run `~/dev-start.sh renew` — it detects version mismatches automatically.
If you already have another cluster (e.g. created manually), it offers to switch to it.
Otherwise it offers to destroy the old cluster and create a new one. If you have hotfix
branches still using the old version, it shows which sessions are affected and adjusts
options accordingly.

## Remote ES: connection refused

**Symptom:** Kibana can't connect to remote ES after `switch --remote`.

**Checks:**
1. Verify credentials are fresh: `~/dev-start.sh renew`
2. Check `~/.kibana-remote-es.yml` exists and has valid content
3. Check `config/kibana.dev.yml` has the remote URL (not localhost)
4. Verify the cluster is still running: `oblt-cli cluster list`

## Port mismatch warnings in `list`

**Symptom:** `list` shows port mismatch warnings.

**Cause:** `kibana.dev.yml` was manually edited or regenerated with different ports
than `~/.kibana-dev.conf` expects.

**Fix:** `~/dev-start.sh sync <session>` to regenerate from template, or manually
update the port in `config/kibana.dev.yml`.

## run-checks finds no changed files

**Symptom:** `run-checks lint` says "No changed files" even though you have changes.

**Cause:** `run-checks.sh` compares against `upstream/main` via `git merge-base`. If
your upstream remote isn't set up or hasn't been fetched recently, the comparison fails.

**Fix:** `git fetch upstream` before running checks. Make sure you have an `upstream`
remote pointing to the main Kibana repo.

## tmux sessions lost after reboot

**Symptom:** All sessions disappear after Mac restart.

**Cause:** tmux sessions are in-memory and don't survive reboots.

**Fix:** Re-run `~/dev-start.sh` to recreate sessions. Your worktrees and config files
are preserved on disk — only the tmux sessions need to be recreated. (tmux-resurrect
integration is on the roadmap.)

## oblt-cli: "not found" or auth errors

**Symptom:** `renew` fails with "oblt-cli not found" or Google Cloud auth errors.

**Fix:**
- Install oblt-cli: https://github.com/elastic/observability-test-environments
- Auth: `gcloud auth login` and `gcloud auth application-default login`
- Verify: `oblt-cli cluster list` should show your clusters

## Fleet: "Cannot read existing Message Signing Key pair"

**Symptom:** Kibana logs show repeated `failed to get message signing phrase` errors.
Fleet preconfiguration (agent policies from `kibana.dev.yml`) silently fails — no
policies appear in Fleet despite being configured.

**Cause:** The remote ES has Fleet signing keys encrypted by a different Kibana instance
(e.g., the cloud Kibana). Your local Kibana has different encryption keys and can't
decrypt the existing signing keys.

**Fix:** Run `run-data fleet-reset` from the Kibana directory, then restart Kibana:
```bash
run-data fleet-reset
~/dev-start.sh restart main   # or feat, or <branch>
```
This deletes synthetics monitors, private locations, Fleet agents, agent policies,
Fleet system index data, and `.fleet-*` ES indices — a full wipe.
On restart, Fleet creates fresh signing keys and preconfiguration runs cleanly.

## Synthetics private location fails: "Fleet Server exited with code 125 / 143"

**Symptom:** `run-data synthetics` prints "SYNTHETICS PRIVATE LOCATION CREATED", then
`Error: Fleet Server exited with code <N>` (from `enroll_agent.ts`). The private location
and agent policy exist, but no agent enrolled.

`run-data synthetics` now runs pre-flight checks (Docker daemon, stale containers,
`/api/fleet/setup`, wait for `fleet-server-policy`) and prints these hints on failure.

| Exit code | Meaning | Likely causes / fix |
|---|---|---|
| **125** | `docker run` itself failed — container never started | Docker not running / still starting (`docker info`); stale Fleet/Agent container holding the name or port 8220 (`docker ps -a`, then `run-data synthetics reset`); image pull failed (snapshot tag gone, expired `docker login docker.elastic.co`); Docker disk full (`docker system df`) |
| **143** | SIGTERM — container started, then was killed. Usually Kibana's ~120s "Fleet Server ready" timeout (`execDuration=119`, `signal=15` in `docker events`); also happens if Docker restarts mid-run | **`fleet-server-policy` missing** (Fleet Server logs loop on "Waiting on policy with Fleet Server integration: fleet-server-policy") — happens after `reset`, which deletes it. Fix: `POST /api/fleet/setup` (the script now does this) or restart Kibana so preconfiguration runs. Other causes: ES/Kibana unreachable from inside the container (`localhost` ≠ host; needs `host.docker.internal`), x509/TLS errors to ES, agent snapshot image version ≠ Kibana/ES version |
| **exit 0, but monitors stay Pending / Fleet shows agent Unhealthy / banner "Missing Fleet integration"** | Enrollment worked but the agent's components crashed. Fleet → Agents → agent → Components shows `synthetics/*` (and `http/metrics-monitoring`) **FAILED** with `panic: a seccomp policy is already registered` | **Stale/broken cached agent image.** The Kibana script runs `<kibana version>-SNAPSHOT` tags and `docker run` never re-pulls a cached tag. `run-data synthetics` now pulls both `elastic-agent` (Fleet Server) and `elastic-agent-complete` (synthetics agent) at most every 12h (skip with `RUN_DATA_SKIP_PULL=1`) and verifies agent health after enrolling. Manual fix: pull **both** images, `run-data synthetics reset`, restart Kibana, re-run. If a fresh pull is still broken, the snapshot itself is bad — see whether a newer build lands, or ask the Elastic Agent team. |
| **hang** (no output) | `docker stop`/`rm` stuck in `reset` | Wedged container/daemon — restart Docker Desktop. `reset` now uses timeouts and `docker kill` fallback |

**Seeing why Fleet Server is unhealthy:** the container is `--rm`'d on exit, so capture logs
while it runs:
```bash
# terminal A (start before the script):
until docker ps -q --filter ancestor=docker.elastic.co/elastic-agent/elastic-agent:<ver>-SNAPSHOT | grep -q .; do sleep 1; done; \
docker logs -f $(docker ps -q --filter ancestor=docker.elastic.co/elastic-agent/elastic-agent:<ver>-SNAPSHOT) 2>&1 | tee /tmp/fleet-server.log
# terminal B: run-data synthetics
```
Also useful: `docker events --filter event=kill --filter event=die --filter event=oom`.

**Note:** re-running `run-data synthetics` without `reset` creates an additional private
location each time. Delete extras in Synthetics → Settings → Private Locations, or `reset`.

**Mock data can hide a broken agent:** `generate-monitors.js` writes fake summary docs straight
into ES, so monitors can show Up/Succeeded with random 100–500 ms durations (even a browser
monitor at ~290 ms) while the agent never ran anything. Real runs show realistic durations,
`agent.id` on the ping doc, and an increasing "Monitors run" count on the private location.
The post-enroll agent health check in `run-data synthetics` is the reliable signal.

**zsh gotcha:** don't paste `<placeholder>` into zsh — `<` is redirection (parse error).
