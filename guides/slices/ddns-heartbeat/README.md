# DDNS Heartbeat

This slice set makes a dead DDNS visible within minutes instead of days.

## Why

On 2026-07-13 the application shut down after a transient Cloudflare 521 (fixed
in 0.3.4). Nobody noticed for **11 days**. Dynamic-IP updates were not running
the entire time; the only reason nothing broke is that the public IP happened not
to change.

The 0.3.4 fix stops that specific crash. It does not tell anyone when the next
one happens — a stopped container, an OOM kill, a bad config, an expired token
are all still silent.

`defdo_status` already implements exactly the right mechanism: monitors of kind
`heartbeat`, an opaque `heartbeat_token`, `Monitors.record_heartbeat/1`, and a
`HeartbeatSweepWorker` that raises `heartbeat_missed` when a ping stops arriving.
Nothing needs to be designed. Two things are missing: `defdo_status` is not
deployed, and `defdo_ddns` never pings it.

This set covers the `defdo_ddns` half.

## Principles

- **The heartbeat means "a checkup completed", not "the process is alive".** A
  monitor stuck in a failing loop must not look healthy. Ping only after a
  checkup finishes.
- **The heartbeat must never affect DNS.** A failed or slow ping is logged and
  dropped; it can never delay, retry into, or crash a checkup.
- **Off by default.** No heartbeat URL configured means no HTTP calls and no
  warnings on every tick.

## Conventions

Inherits `ddns-record-adoption/00-conventions.md` for build ladder, branch
prefix, redaction and test rules. Additional rules:

- `Defdo.Cloudflare.Monitor` owns *when* a heartbeat fires. It must not own *how*.
- The heartbeat token is a credential: never logged, never in diagnostics.
- Do not add a new HTTP client; reuse `Req`.

## Slice Order

1. `01-heartbeat-emitter.md`
2. `02-verification.md`

## Follow-up outside this repo

Deploying `defdo_status` and registering the monitor is separate work and does
not belong to this set. Track it as: deploy `defdo_status`, create a `heartbeat`
monitor for DDNS with a period slightly longer than `DDNS_REFETCH_EVERY_MS`
(default 5 min — 12 min is a reasonable grace), and wire its alert channel.
