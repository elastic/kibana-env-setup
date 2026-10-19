# Heartbeat / k8s autodiscovery synthetics monitors

How to produce **Elastic Agent–run synthetics monitors that have no Kibana saved
object** — the "Heartbeat / autodiscovery" case. These monitors ship pings
straight into `synthetics-*` data streams and are the exact input the Synthetics
app's read-only "heartbeat monitor" surfacing consumes (PR
[#274947](https://github.com/elastic/kibana/pull/274947), issue
[#273494](https://github.com/elastic/kibana/issues/273494)).

Automated by: `run-data synthetics heartbeat <up|deploy|annotate|verify|clear|status|reset>`
(`clear` drops just the ping data; `reset` is the full teardown).
This doc is the manual runbook behind that command (and the fallback when a step
needs debugging).

**Fastest path:** `run-data synthetics heartbeat up` does everything below in one
shot — starts minikube (if needed), deploys the otel demo (if its namespace is
missing), then deploy → annotate → wait → verify. On remote/oblt-cli ES pass the
superuser (it's reused for the otel-demo deploy too):

```bash
DATA_USERNAME=admin DATA_PASSWORD='<admin-pw>' run-data synthetics heartbeat up
# HB_WAIT=<seconds> overrides the post-annotate wait (default 75)
```

Read the rest of this doc when a step fails or you want to understand the moving
parts.

## Mental model (read this first)

Three **independent** pieces must all be running. The most common mistake is
assuming the otel demo alone produces synthetics data — it does not.

```
otel demo Services            standalone Elastic Agent          Elasticsearch            Kibana
(ns: otel-demo)      ──annot──▶ (k8s provider +        ──write──▶ synthetics-*    ──read──▶ Synthetics app
 things to monitor    ations    synthetics inputs)       pings    (no saved object)         (read-only)
```

- **otel demo** only supplies *annotatable Services* (any app works; a plain
  nginx Service is enough). It is monitored, it does not monitor.
- **Annotations** (`co.elastic.monitor/*` on the Service) are what the Agent's
  Kubernetes provider turns into `synthetics/http|tcp` inputs.
- **The Agent** runs the checks and writes pings. Its ES output must point at the
  **same** cluster Kibana reads from.
- **The PR** only cares about docs in `synthetics-*` whose `monitor.id` has **no
  matching Synthetics saved object**. Nothing created these via the UI/API, so
  that condition holds automatically.

### Critical constraints

- Must be Elastic **Agent** `synthetics/*` inputs (write to `synthetics-*`).
  Classic standalone **Heartbeat** writes to `heartbeat-*`, which the Synthetics
  app does **not** query (`SYNTHETICS_INDEX_PATTERN = 'synthetics-*'`). Using
  Heartbeat will produce data that never shows up — a dead end.
- Agent and Kibana must share **one** ES cluster. With the dev-env on remote ES
  (oblt-cli), the Agent output uses the cloud URL from `config/kibana.dev.yml`.
  With **local ES**, `deploy` rewrites `localhost`/`127.0.0.1` to
  `host.minikube.internal` in the manifest (the pod's own localhost is not the
  host). ES must bind beyond loopback — set `ES_BIND_ALL=true` in `~/.kibana-dev.conf` and
  restart ES (kbn-start.sh adds `-E network.host=0.0.0.0`); symptom otherwise
  is `dial tcp …:9200: connection refused` + `Drop batch` in `heartbeat status`.
- The **synthetics integration package** must be installed first so `synthetics-*`
  data streams and mappings exist, otherwise pings land unmapped.
- Set `monitor.id` via `fields_under_root: true` + `fields: { monitor.id: ... }`.
  A plain `id:` stream field does **not** populate `monitor.id`.
- Match the Agent image to the stack version: `elastic-agent:<pkg-version>-SNAPSHOT`
  (derive `<pkg-version>` from the repo's `package.json`).

## Prerequisites

- `minikube` (or `kind`), `kubectl`, `docker`, `curl`, `python3`.
- A running dev-env session (Kibana up) on the branch under test.
- **Start minikube yourself first — `otel_demo.js` does NOT auto-start it.**
  It calls `assertMinikubeAvailable()` (throws unless `Running`) *before* the
  auto-start `ensureMinikubeRunning()`, so you'll hit
  `Error: minikube is not running. Please start minikube with: minikube start --driver=docker`.
  ```bash
  # Docker must be running first (docker driver)
  minikube start --driver=docker --memory=4096 --cpus=4
  minikube status        # host/kubelet/apiserver → Running, kubeconfig → Configured
  kubectl get nodes      # 1 node, Ready
  ```
  **Gotcha:** never start/stop the minikube container from Docker Desktop — that
  leaves a stale kubeconfig (`kubeconfig: Misconfigured`, kubelet/apiserver
  `Stopped`, API port drift). Recover with:
  ```bash
  minikube update-context && minikube start --driver=docker
  # or, if wedged:
  minikube delete && minikube start --driver=docker --memory=4096 --cpus=4
  ```
- Then deploy the **otel demo** (supplies annotatable Services):
  ```bash
  # from the Kibana repo dir, with Kibana fully started
  node ./scripts/otel_demo.js --config config/kibana.dev.yml
  ```
  This deploys the OpenTelemetry demo into minikube (namespace `otel-demo`) with
  ~14 ClusterIP Services: `frontend:8080`, `product-catalog:3550`, `cart:7070`,
  `checkout:5050`, `currency:7285`, `shipping:50051`, `quote:8090`, `ad:9555`,
  `recommendation:9001`, `email:6060`, `payment:50051`, plus `valkey:6379`,
  `flagd:8013`; NodePort `frontend-external:30080`.

### Why not just use oblt-cli's oteldemo?
oblt-cli's "oteldemo" is **pre-indexed APM data** (traces/metrics/logs) in the
remote ES — passive documents, visible in APM → Service inventory. Heartbeat
**autodiscovery is active, not data-driven**: the in-cluster Elastic Agent's
`providers.kubernetes` watches the k8s API for Services annotated with
`co.elastic.monitor/*`, then TCP/HTTP-**probes** their in-cluster hosts
(`*.svc.cluster.local`) and emits `synthetics-*` pings. oblt-cli gives you
nothing to annotate and nothing to probe, so you **can't** skip the local
minikube otel demo + annotate step.

The correct split — which this runbook already does — is: **local minikube = the
probe topology + agent; oblt-cli remote ES = the ping sink + Kibana** (the agent
writes its `k8s-autodiscover` pings into the oblt ES; `ES_HOST` parsing handles
the oblt-cli config format). Even if oblt-cli exposed a *running* k8s oteldemo
you could `kubectl` into, don't use it: it's shared (annotating Services +
deploying an Agent hits everyone), you couldn't shape the **location-less /
space-less** pings this feature is about (needs control of the agent config to
strip `observer.name` / `observer.geo.name`), and `reset` does a
`delete_by_query` on `synthetics-*` — destructive on shared data. Local minikube
is isolated, disposable, and lets you control the exact ping shape.

## Step 1 — install the synthetics integration package

```bash
curl -s -X POST "http://localhost:<port>/api/fleet/epm/packages/synthetics" \
  -u "elastic:<pw>" -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"force":true}'
```

Verify the templates exist:

```bash
curl -s -k -u "elastic:<pw>" \
  "<es-host>/_index_template/synthetics*?filter_path=index_templates.name"
```

## Step 2 — create an ES API key for the Agent output

The Agent needs to write to `synthetics-*` data streams:

```bash
curl -s -k -X POST "<es-host>/_security/api_key" -u "elastic:<pw>" \
  -H "Content-Type: application/json" -d '{
    "name": "kbn-dev-synthetics-agent",
    "role_descriptors": {
      "synthetics_writer": {
        "cluster": ["monitor"],
        "indices": [{ "names": ["synthetics-*"], "privileges": ["auto_configure","create_doc"] }]
      }
    }
  }'
```

The standalone Agent's `api_key` config wants the form `<id>:<api_key>` (from the
`id` and `api_key` fields of the response — **not** the base64 `encoded` field).
A quick test alternative is to skip the key and put `username: elastic` +
`password` in the ConfigMap.

## Step 3 — deploy the standalone Elastic Agent

Apply a manifest (ConfigMap + Deployment + RBAC) into `kube-system` with:

- image → `docker.elastic.co/elastic-agent/elastic-agent:<version>-SNAPSHOT`
- `outputs.default`: `type: elasticsearch`, `hosts: [<es-host>]`, `api_key: <id:key>`,
  `ssl.verification_mode: none` (Cloud certs are publicly trusted; this just avoids
  local CA hassle).
- `providers.kubernetes: { scope: cluster, resources.service.enabled: true }`
  (cluster scope lets the `kube-system` Agent discover `otel-demo` Services).
- two inputs, `synthetics/tcp` and `synthetics/http`, each gated on
  `condition: ${kubernetes.annotations.co.elastic.monitor/type} == 'tcp'|'http'`
  and reading `name/hosts/schedule/timeout` from `co.elastic.monitor/*`
  annotations, with `fields_under_root: true` + `fields: { monitor.id: ${...id} }`.
- cluster-scoped RBAC (ServiceAccount / ClusterRole / bindings) so the k8s
  provider can list/watch services across namespaces.

The exact working manifest is generated by `run-data synthetics heartbeat deploy`
(embedded heredoc). A reference copy also lives at
`~/synthetics-autodiscover-test/elastic-agent-synthetics.yaml`.

```bash
kubectl apply -f <manifest>
kubectl rollout status deployment/elastic-agent-synthetics -n kube-system --timeout=120s
```

## Step 4 — annotate Services to drive monitors

```bash
kubectl annotate --overwrite service frontend -n otel-demo \
  co.elastic.monitor/type=http \
  co.elastic.monitor/id=otel-frontend-http \
  co.elastic.monitor/name="OTel Frontend" \
  co.elastic.monitor/hosts=http://frontend.otel-demo.svc.cluster.local:8080 \
  co.elastic.monitor/schedule="@every 30s" \
  co.elastic.monitor/timeout=10s

kubectl annotate --overwrite service product-catalog -n otel-demo \
  co.elastic.monitor/type=tcp \
  co.elastic.monitor/id=otel-product-catalog-tcp \
  co.elastic.monitor/name="OTel Product Catalog" \
  co.elastic.monitor/hosts=product-catalog.otel-demo.svc.cluster.local:3550 \
  co.elastic.monitor/schedule="@every 30s" \
  co.elastic.monitor/timeout=10s
```

Notes:
- `@every 30s` keeps pings fresh so they pass the overview's "currently fresh"
  timespan filter.
- The `id` values must not collide with any Synthetics saved object — they won't,
  since nothing created them via UI/API. That is precisely the PR's trigger.
- These Agent pings carry **no `observer.name`/`observer.geo.name`** (no location)
  and **no `meta.space_id`** (no space). Both are deliberate parts of the test —
  the app groups location-less monitors under a "Heartbeat" placeholder location
  and (per product decision) shows space-less monitors in every space.

## Step 5 — verify

ES first (source of truth):

```bash
# pings exist for a monitor id?
curl -s -k -u "elastic:<pw>" "<es-host>/synthetics-*/_search" -H "Content-Type: application/json" \
  -d '{"size":1,"query":{"term":{"monitor.id":"otel-frontend-http"}}}'
```

Confirm on a fresh doc whether `observer.geo.name` and `meta.space_id` are present
(expected: absent for pure autodiscovery pings).

Then in the UI:
1. Overview (`/app/synthetics/monitors`): the monitor appears with a Heartbeat
   badge, read-only (no edit/run-test), under the "Heartbeat" placeholder location
   if location-less.
2. Flyout: Details tab renders (no infinite spinner); Duration chart populates.
   "Go to monitor" is intentionally hidden until the detail page supports these.

## Reset / teardown

```bash
kubectl delete -f <manifest> --ignore-not-found
# remove annotations from the services you annotated, e.g.:
kubectl annotate service frontend -n otel-demo co.elastic.monitor/type- co.elastic.monitor/id- ...
# optionally purge the pings:
curl -s -k -u "elastic:<pw>" -X POST "<es-host>/synthetics-*/_delete_by_query?conflicts=proceed" \
  -H "Content-Type: application/json" -d '{"query":{"term":{"tags":"k8s-autodiscover"}}}'
```

`run-data synthetics heartbeat reset` does all of the above and invalidates the
API key.

## Break / repro silent staleness

Autodiscovery monitors can stop shipping while the overview keeps showing them
**Up** — there is no staleness signal in the UI yet
([kibana#281750](https://github.com/elastic/kibana/issues/281750)). To reproduce
it on demand:

```bash
run-data synthetics heartbeat break dead-key    # default; strongest repro
run-data synthetics heartbeat break agent-down
run-data synthetics heartbeat break unannotate [namespace]
run-data synthetics heartbeat fix  <scenario>   # same names; restores shipping
```

| Scenario | What it does | Why it's realistic |
|---|---|---|
| `dead-key` (default) | Invalidates the Agent's ES API key **without** restarting the pod. The pod stays `Running` and keeps trying to ship with a dead key (401s). | Mirrors a rotated/expired/revoked key — the classic silent failure. `fix` runs `deploy` (fresh key + rollout restart). |
| `agent-down` | `kubectl scale …/elastic-agent-synthetics --replicas=0`. | Agent node/pod goes away (eviction, cordon, OOM). `fix` scales back to 1 and waits for rollout. |
| `unannotate` | Strips `co.elastic.monitor/*` from the otel-demo Services. | Someone edits/redeploys a Service without the annotations → the target disappears. `fix` re-annotates. |

After a `break`, the monitor keeps showing **Up** in the overview and the flyout's
"Last test run" stops advancing / Duration flatlines. Confirm from ES with
`run-data synthetics heartbeat verify` — it flips to `⚠️ STALE` once the newest
ping is older than ~3 min.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No pings in `synthetics-*` | Agent output points at a different/destroyed cluster | Re-check `hosts`/`api_key` against `config/kibana.dev.yml`; `run-data synthetics heartbeat deploy` regenerates from current config |
| Pings exist but nothing in Synthetics app | Data in `heartbeat-*` not `synthetics-*` (used Heartbeat, not Agent synthetics inputs) | Use the Agent `synthetics/*` inputs manifest |
| Monitor missing `monitor.id` | Used a plain `id:` stream field | Use `fields_under_root: true` + `fields: { monitor.id: ... }` |
| Agent pod CrashLoopBackOff | Version/image mismatch or bad api_key | `kubectl logs -n kube-system deploy/elastic-agent-synthetics`; match image to `<pkg-version>-SNAPSHOT` |
| Monitor shows only under "All permitted spaces" | Pings have no `meta.space_id`; older Kibana filtered them out in single-space view | Expected pre-fix; the branch under test surfaces space-less monitors in every space |
