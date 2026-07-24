# Slice 01 - Heartbeat Emitter

## Goal

After every completed checkup, ping a `defdo_status` heartbeat endpoint, so that
the absence of a ping raises an incident.

## Scope

New module `Defdo.DDNS.Heartbeat`.

```elixir
@spec ping(outcome :: :ok | :degraded) :: :ok
```

Configuration (`config/runtime.exs`):

```elixir
config :defdo_ddns, Defdo.DDNS.Heartbeat,
  url: System.get_env("DDNS_HEARTBEAT_URL"),
  timeout_ms: Defdo.ConfigHelper.parse_integer_env("DDNS_HEARTBEAT_TIMEOUT_MS", 5_000, min: 250),
  send_on_degraded: Defdo.ConfigHelper.parse_boolean_env("DDNS_HEARTBEAT_ON_DEGRADED", true)
```

`DDNS_HEARTBEAT_URL` is the full `defdo_status` ping URL including the opaque
token. It is a credential: treat it like `CLOUDFLARE_API_TOKEN`.

## Behaviour

1. `Defdo.Cloudflare.Monitor` calls `Heartbeat.ping/1` once per checkup, **after**
   the checkup completes, never before.
2. Outcome:
   - `:ok` — every domain processed without an error result.
   - `:degraded` — at least one domain returned an error. Sent only when
     `send_on_degraded` is true (the default: a DDNS that is running but failing
     is still better represented as "up with errors" than as "dead", and its
     failures show up in logs and in the zone drift).
3. `ping/1` always returns `:ok`. It never raises, never blocks beyond
   `timeout_ms`, and never propagates a failure to the caller.
4. No URL configured → return `:ok` immediately, log nothing per-tick (log once at
   boot that the heartbeat is disabled).

## Implementation Notes

- Use `Req.get` with an explicit `receive_timeout`. Never a bang variant.
- Wrap in `try`/`rescue` regardless — a heartbeat must not be able to do to the
  monitor what Cloudflare did in 0.3.4. This is the whole point of the set.
- Log failures at `warning`, once per failure, with the reason but **never the
  URL** (it contains the token). Log the host only, or a fixed label.

## Out of Scope

- Deploying `defdo_status`.
- Creating the monitor record or alert channel.
- Any push of metrics or record counts; this is a liveness signal only.

## Acceptance

- A completed checkup issues exactly one ping.
- A checkup that fails every domain still issues a ping when
  `send_on_degraded` is true, and none when it is false.
- A stubbed heartbeat endpoint returning 500, a timeout, and a transport error
  each leave the checkup result unchanged and the monitor alive.
- With no URL configured, zero HTTP requests are issued.
- No test log contains the token or the full URL.
