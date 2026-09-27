---
kind: product
topic: ddns-service-hardening (phase 2 — operability)
approved: 2026-09-26 by owner (chat: "de momento vamos con ese product.md" — recommendations accepted for Q1–Q3)
---

# DDNS as an operable service — product

> **Status: APPROVED 2026-09-26.** The owner accepted the recommendations for
> Q1–Q3 (see `## Decisions`). Q4 is an external dependency, not a product
> choice: P-03's code ships disabled by default and waits on defdo_status being
> deployed. Phase 2 slices: `08`–`11`.

## Who and why

The **platform operator** runs `defdo_ddns` as a container in K3s. It keeps
home-lab A/AAAA records on the current public IP and gives other defdo apps a
`POST /v1/dns/upsert` endpoint for tenant subdomains. Today the only signal
available is `GET /health` → `{"status":"ok"}`, which only proves the HTTP
listener is up. In July 2026 the app was down for 11 days before anyone noticed;
after 0.3.4 it stays up, but a monitor that fails every cycle still looks
exactly like a healthy one. The operator finds out only when a DNS name stops
resolving.

A second user is **K3s itself** (probes), and a third is **defdo_status**
(heartbeat monitor), which already knows how to raise `heartbeat_missed`.

## Scenarios

### P-01 — The cluster shows DDNS isn't converging

1. The Cloudflare token expires. Every cycle now fails at `get_zone_id`.
2. After the configured threshold (see open question Q1), the operator runs
   `kubectl get pods -n <ns>` and sees the ddns pod `0/1 READY` instead of
   `1/1`. `GET /health` still returns 200 (liveness), so K3s does not
   restart-loop it.
3. `kubectl describe pod` shows the readiness probe failing on `/ready` with
   status 503.

Done when: a DDNS instance that cannot converge DNS is visibly not ready in the
cluster within the threshold, without being restarted.

### P-02 — The operator checks what DDNS is doing after a deploy

1. The operator deploys a new tag and runs
   `curl -s -H "Authorization: Bearer $DDNS_API_TOKEN" https://<ddns-host>/v1/status | jq`.
2. They see: the last cycle's outcome (`ok` / `degraded` / `failed`), when it
   finished, how long it took, how long since the last success, consecutive
   failures, where intent comes from (`desired_state` file or `env`) with record
   counts, the record-store state, and how many adoption entries are pending.
3. No hostname, IP or token appears in the response.

Done when: one command answers "is it converging, from what, and is anything
waiting on me?".

### P-03 — The operator is alerted when DDNS stops

1. The ddns pod is OOM-killed and cannot start (or the monitor fails every
   cycle).
2. Within a few intervals, defdo_status raises `heartbeat_missed` for the ddns
   monitor and the operator is notified through their usual channel.
3. When DDNS recovers, the next successful cycle pings again and the incident
   resolves.

Done when: silence from DDNS becomes an alert within minutes, not days. (This is
the existing `ddns-heartbeat` set; phase 2 only rewires *where* it fires — after
a completed, non-failed cycle recorded by slice H05.)

### P-04 — The operator sees trends (pending Q3)

1. The operator opens their dashboard and sees cycle duration, cycle outcomes
   over time, and Cloudflare request counts/errors per operation.
2. A slow creep in cycle duration or error rate is visible before it becomes an
   outage.

Done when: cycle and Cloudflare-call health can be graphed over time.

## Views

| Surface | For | Scenarios | Primary action |
|---|---|---|---|
| `GET /health` (exists) | liveness: process is serving | P-01 | K3s liveness probe |
| `GET /ready` (new) | readiness: DDNS can do its job | P-01 | K3s readiness probe |
| `GET /v1/status` (new) | human/automation status, counts only | P-02 | operator `curl` |
| heartbeat ping (existing set) | dead-man's switch | P-03 | defdo_status sweep |
| `:telemetry` events (new) | metrics source | P-04 | host/exporter attaches |

## Out of scope

- A web UI. Status is JSON; a console belongs in a separate set if wanted.
- Deleting unmanaged records (still excluded, as in the adoption set).
- Multi-node / HA DDNS. The locks from H03 are node-local by design.

## Decisions

Recorded from the owner's approval. Each was an open question; the reasoning
is kept so it is not reopened by accident.

- **Q1 → B.** `/ready` fails on process problems (record store not running,
  monitor enabled but not running, intent not loadable) **and** on convergence
  problems: `consecutive_failures >= 3` or last success older than
  3 × `DDNS_REFETCH_EVERY_MS` (both configurable). Before the first cycle
  finishes, `/ready` is 503 (`starting`). With the monitor disabled
  (`DDNS_ENABLE_MONITOR=false`), convergence checks are skipped. Accepted
  trade-off: while Cloudflare is failing, K3s removes the pod from the Service,
  so `POST /v1/dns/upsert` and adoption decisions are unreachable through it.
- **Q2 → operator token.** `GET /v1/status` requires `DDNS_API_TOKEN` (auth
  mode `:token`), as the adoption routes do since H06; client tokens get 403.
  `/ready` and `/health` are unauthenticated (probes carry no token) and return
  no detail beyond `status` and short reason codes.
- **Q3 → A.** `:telemetry` events only; no exporter and no new HTTP endpoint.
  P-04 is "done" when the events exist and are documented; wiring a sink is
  deployment work.
- **Q4 → external.** The heartbeat ships behind `DDNS_HEARTBEAT_URL` (unset =
  off). Deploying defdo_status and creating the monitor stays outside this repo.

## Open questions (answered — see Decisions)

Kept as asked, for the record.

- **Q1 — What makes `/ready` fail?** Option A: only process readiness (record
  store loaded, monitor started, intent loadable). Option B: A **plus** "last
  successful cycle older than 3× the interval" or "≥3 consecutive failed
  cycles". Trade-off: B removes the pod from Service endpoints, so
  `POST /v1/dns/upsert` becomes unreachable while Cloudflare is failing —
  arguably correct (upsert would fail anyway), but it also blocks adoption
  decisions, which do not need Cloudflare. *Recommendation: B for readiness,
  with the threshold configurable, because P-01 is the reason for the set.*
- **Q2 — Who can read `/v1/status`?** Operator token only (consistent with
  H06), or unauthenticated since it carries counts only? *Recommendation:
  operator token.*
- **Q3 — Where do metrics go?** Option A: emit `:telemetry` events only (no new
  dependency; the host or a sidecar exporter attaches). Option B: built-in
  Prometheus endpoint (adds a dependency). *Recommendation: A; P-04 stays
  pending until there is a sink.*
- **Q4 — Heartbeat target.** Is defdo_status deployed and reachable from the
  ddns namespace? If not, P-03 waits on that deployment (tracked outside this
  repo in `ddns-heartbeat/README.md`).
