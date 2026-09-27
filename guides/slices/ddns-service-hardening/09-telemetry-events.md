---
kind: implementation
serves: [P-04]
skills: [defdo-exunit-quality-tests]
---

# Slice H09 — `:telemetry` events for cycles and outbound HTTP

## Ecosystem

- uses: telemetry@1.4.2 — `:telemetry.span/3`, `:telemetry.attach_many/4`
  (already in `mix.lock` through req/finch; this slice declares it directly).
- gap: metrics sink — **deployment**, per product.md Q3 (events only).

## Goal

DDNS emits standard `:telemetry` span events so a host or exporter can graph
cycle duration/outcomes and outbound request health (P-04):

- `[:defdo_ddns, :cycle, :start | :stop | :exception]` — one span per monitor cycle.
- `[:defdo_ddns, :http, :request, :start | :stop | :exception]` — one span per
  outbound HTTP call (Cloudflare and public-IP lookup).

No event metadata carries hostnames, IPs, record content, URLs or tokens.

## Preconditions

- Read `00-conventions.md`, `product.md` (Q3).
- H05 merged (`run_cycle/1` in the monitor). Independent of H08.

## Decisions (made; do not reopen)

- `:telemetry.span/3` everywhere: it emits start/stop/exception with
  `:duration` (native units) and `:monotonic_time`, the convention every
  consumer (`telemetry_metrics`, OpenTelemetry bridges) already understands.
- Declare `{:telemetry, "~> 1.0"}` in `mix.exs`: using a transitive dependency
  directly breaks the day req drops it. No version change: the lock holds 1.4.2.
- Operation names are fixed strings chosen here, not derived from URLs.

## Event contract (put this table in README verbatim)

| Event | Measurements | Metadata |
|---|---|---|
| `[:defdo_ddns, :cycle, :stop]` | `duration` | `outcome` (`"ok"`/`"degraded"`/`"failed"`), `domains` (integer), `consecutive_failures` (integer) |
| `[:defdo_ddns, :http, :request, :stop]` | `duration` | `service` (`:cloudflare` \| `:ip_lookup`), `operation` (string, below), `result` (`:ok` \| `:error`), `status` (integer HTTP status or `nil` on transport error) |

`operation` values: `"get_zone_id"`, `"list_dns_records"` (one event per page),
`"get_zone_ssl_mode"`, `"apply_update"`, `"create_dns_record"`, `"public_ip_ipv4"`,
`"public_ip_ipv6"`. `:start` events carry the same metadata minus `result`/`status`.

## Targets

- `mix.exs` — `deps/0` (`rg -n "defp deps" mix.exs`)
- `lib/defdo/cloudflare/ddns.ex` — every `Req.get/put/post(` (`rg -n "Req\.(get|put|post)\(" lib/defdo/cloudflare/ddns.ex`, 6 sites after H02)
- `lib/defdo/cloudflare/monitor.ex` — `defp run_cycle` (`rg -n "defp run_cycle" lib`)
- `test/ddns_telemetry_test.exs` (new)
- `README.md` — new `### Telemetry` section before `### Optional HTTP API (Bandit)`
- `CHANGELOG.md`

## Step 1 — Dependency

In `mix.exs` `deps/0`, add after `{:bandit, ...}`:

```elixir
      # Already locked through req/finch; declared because DDNS emits events itself.
      {:telemetry, "~> 1.0"},
```

Then `mix deps.get` must report no changes to `mix.lock` (author/reviewer
step; the driver has no network — if `mix compile` complains about the lock,
STOP and report). Check: `git diff --exit-code mix.lock`.

## Step 2 — Instrument outbound HTTP

In `Defdo.Cloudflare.DDNS` add:

```elixir
  # One telemetry span per outbound request. Metadata is fixed strings and
  # status codes only: never URLs (the IP lookup URL is harmless, but the rule
  # keeps credentials out wherever a URL might carry one).
  defp instrument(service, operation, fun) do
    meta = %{service: service, operation: operation}

    :telemetry.span([:defdo_ddns, :http, :request], meta, fn ->
      response = fun.()
      {response, Map.merge(meta, response_meta(response))}
    end)
  end

  defp response_meta({:ok, %Req.Response{status: status}}) when status in 200..299,
    do: %{result: :ok, status: status}

  defp response_meta({:ok, %Req.Response{status: status}}), do: %{result: :error, status: status}
  defp response_meta({:error, _reason}), do: %{result: :error, status: nil}
```

Wrap **each** `Req.get/put/post(...)` call as the first argument of the
pipeline, e.g.:

```elixir
    instrument(:cloudflare, "get_zone_id", fn ->
      Req.get(
        @zone_endpoint,
        [headers: cf_auth_headers(), params: [name: domain]] ++ req_options()
      )
    end)
    |> decode_envelope("get_zone_id")
```

For `fetch_public_ip/2` use `instrument(:ip_lookup, "public_ip_#{family}", fn -> Req.get(url, req_options()) end)`
and keep the existing `case`.

Check: `rg -c "instrument\(" lib/defdo/cloudflare/ddns.ex` ≥ number of
`Req.(get|put|post)(` calls + 1 (the `defp instrument` line).

## Step 3 — Instrument the cycle

In `Defdo.Cloudflare.Monitor`, extract the failure-count rule so the telemetry
metadata and the ETS row can never disagree:

```elixir
  defp next_failures("failed", previous), do: previous["consecutive_failures"] + 1
  defp next_failures(_outcome, _previous), do: 0
```

In `run_cycle/1`, replace `{outcome, lines} = execute_monitor()` with:

```elixir
    {:ok, previous} = status()

    {outcome, lines} =
      :telemetry.span([:defdo_ddns, :cycle], %{}, fn ->
        {outcome, lines} = result = execute_monitor()

        {result,
         %{
           outcome: outcome,
           domains: length(lines),
           consecutive_failures: next_failures(outcome, previous)
         }}
      end)
```

and use `next_failures(outcome, previous)` for `"consecutive_failures"` in the
ETS row (delete the inline `if(failed?, ...)` for that key; keep `failed?` for
`last_success_at`). Move the existing `{:ok, previous} = status()` line up to
where it is shown above rather than reading status twice.

`checkup_once/0` emits no cycle event (it records no status either).

## Step 4 — README and CHANGELOG

README `### Telemetry`: the event contract table above, a one-line
`:telemetry.attach_many/4` example, and "no hostnames, IPs, URLs or tokens in
metadata".

CHANGELOG `## ✨ Features`: telemetry span events for cycles and outbound HTTP.

## Tests

`test/ddns_telemetry_test.exs` (`async: false`; `Req.Test` shared mode and
`:cloudflare_req_options` → `retry: false`; attach a handler with
`:telemetry.attach_many/4` that sends `{event, measurements, metadata}` to the
test pid; `:telemetry.detach/1` in `on_exit`):

- `"http request stop event per Cloudflare call"` — `DDNS.get_zone_id("example.com")`
  with a 200 stub → one `[:defdo_ddns, :http, :request, :stop]` with
  `%{service: :cloudflare, operation: "get_zone_id", result: :ok, status: 200}`
  and an integer `duration`.
- `"error result on 521 and on transport error"` — 521 stub → `result: :error, status: 521`;
  `Req.Test.transport_error(conn, :econnrefused)` → `result: :error, status: nil`.
- `"one event per listing page"` — 2-page stub → two stop events with operation `"list_dns_records"`.
- `"cycle stop event"` — `start_supervised!({Monitor, refetch_every: :timer.hours(1)})`
  with a healthy stub → a `[:defdo_ddns, :cycle, :stop]` with `outcome: "ok"`,
  `domains: 1`, `consecutive_failures: 0`.
- `"metadata carries no hostnames or URLs"` — collect every event from one
  healthy cycle; `inspect(all_metadata)` contains neither `"example.com"`,
  `"https://"`, nor `"203.0.113."`.

## Verification

```sh
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
git diff --exit-code mix.lock
mix test test/ddns_telemetry_test.exs
mix test
mix test --seed 8
grep -q '{:telemetry, "~> 1.0"}' mix.exs
test "$(grep -c 'instrument(' lib/defdo/cloudflare/ddns.ex)" -gt "$(grep -cE 'Req\.(get|put|post)\(' lib/defdo/cloudflare/ddns.ex)"
grep -q "defdo_ddns, :cycle" lib/defdo/cloudflare/monitor.ex
grep -q "### Telemetry" README.md
git diff --check
```

## Acceptance criteria

- [ ] `telemetry` declared in `mix.exs`; `mix.lock` unchanged.
- [ ] Every outbound `Req` call is inside `instrument/3`; events match the contract table.
- [ ] One cycle span per monitor cycle with outcome/domains/consecutive_failures; none from `checkup_once/0`.
- [ ] Metadata test proves no hostnames/URLs/IPs.
- [ ] README table and CHANGELOG. Suite green on default seed and seed 8.

## What wrong looks like

- Putting `url`, `name`, `zone_id` or `content` in metadata.
- `:telemetry.execute` hand-rolled start/stop pairs instead of `span/3`.
- A telemetry handler attached by the library itself (hosts attach; the
  library only emits).
