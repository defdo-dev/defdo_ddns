# Slice 02 - Verification

```sh
mix format
mix compile --warnings-as-errors
mix test test/ddns_heartbeat_test.exs
mix test
git diff --check
```

## Functional Gate

With the heartbeat endpoint stubbed via `Req.Test`:

1. One completed checkup → exactly one ping.
2. Endpoint returns 500 → checkup result unchanged, monitor process still alive.
3. Endpoint times out → checkup result unchanged, monitor still alive, elapsed
   time bounded by `DDNS_HEARTBEAT_TIMEOUT_MS`.
4. Transport error → same.
5. No URL configured → zero requests, no per-tick log noise.
6. All domains failing + `send_on_degraded: false` → zero pings.

## Resilience Gate

The regression this set must never reintroduce: assert that a heartbeat failure
cannot terminate the monitor. Start a monitor with a stub that always fails,
drive two checkups, and assert the same pid is alive at the end.

## Redaction Gate

Capture logs across every case above and assert none contain the configured URL
or token.

## Operational Gate

Once `defdo_status` is deployed and the monitor registered:

- Stop the DDNS container and confirm `defdo_status` moves the monitor to `down`
  with cause `heartbeat_missed` within the configured grace period.
- Start it again and confirm recovery.

That end-to-end check is the actual acceptance for this set — until it has been
observed once, the alerting path is unproven.
