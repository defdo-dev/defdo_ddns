---
kind: implementation
serves: [P-03]
skills: [defdo-exunit-quality-tests]
supersedes: guides/slices/ddns-heartbeat/01-heartbeat-emitter.md
---

# Slice H10 — Heartbeat after each completed cycle

## Ecosystem

- uses: req@0.6.3 (no new client).
- gap: the receiving side (defdo_status heartbeat monitor) — **external**,
  product.md Q4. This slice ships disabled by default.

## Goal

When `DDNS_HEARTBEAT_URL` is set, the monitor pings it once after every cycle
whose outcome is `"ok"`, and after `"degraded"` cycles unless
`DDNS_HEARTBEAT_ON_DEGRADED=false`. It **never** pings after a `"failed"`
cycle, so a DDNS that fails every cycle goes silent and defdo_status raises
`heartbeat_missed` (P-03). A ping can never delay a cycle by more than its
timeout, raise into the monitor, or log the URL (it carries a token).

This supersedes `ddns-heartbeat/01`: same module and config, but the outcome
now comes from the cycle status H05 records, and "failed" is silence instead of
a degraded ping.

## Preconditions

- Read `00-conventions.md`, `product.md` (P-03, Q4), and `ddns-heartbeat/README.md` (why).
- H05 merged. Independent of H08/H09 (if H09 is merged, the ping is **not**
  instrumented with `instrument/3` — it is not Cloudflare or IP lookup; leave it
  out of the HTTP event contract).

## Targets

- `lib/defdo/ddns/heartbeat.ex` (new)
- `lib/defdo/cloudflare/monitor.ex` — `init/1`, `defp run_cycle` (`rg -n "def init|defp run_cycle" lib/defdo/cloudflare/monitor.ex`)
- `config/runtime.exs`
- `README.md` — env table; `### Heartbeat` section after `### Telemetry` if it exists, else before `### Optional HTTP API (Bandit)`
- `guides/slices/ddns-heartbeat/01-heartbeat-emitter.md` — add a SUPERSEDED banner (first lines)
- `test/ddns_heartbeat_test.exs` (new)
- `CHANGELOG.md`

## Step 1 — Config

`config/runtime.exs`:

```elixir
config :defdo_ddns, Defdo.DDNS.Heartbeat,
  url: System.get_env("DDNS_HEARTBEAT_URL"),
  timeout_ms: Defdo.ConfigHelper.parse_integer_env("DDNS_HEARTBEAT_TIMEOUT_MS", 5_000, min: 250),
  send_on_degraded: Defdo.ConfigHelper.parse_boolean_env("DDNS_HEARTBEAT_ON_DEGRADED", true)
```

## Step 2 — `Defdo.DDNS.Heartbeat`

```elixir
defmodule Defdo.DDNS.Heartbeat do
  @moduledoc """
  Dead-man's switch: one ping per completed cycle, so silence means trouble.

  `"failed"` cycles send nothing — a DDNS that cannot converge must look dead
  to the receiver. The URL carries the receiver's token: it is never logged.
  A ping can never raise into the monitor or wait longer than `timeout_ms`.
  """

  require Logger

  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(url()) and url() != ""

  @doc "Ping for a cycle outcome. Always returns `:ok`."
  @spec ping(String.t()) :: :ok
  def ping(outcome) do
    if enabled?() and should_ping?(outcome), do: send_ping()
    :ok
  end

  defp should_ping?("ok"), do: true
  defp should_ping?("degraded"), do: config(:send_on_degraded, true)
  defp should_ping?(_outcome), do: false

  defp send_ping do
    case Req.get(url(), receive_timeout: config(:timeout_ms, 5_000), retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("DDNS heartbeat rejected (status=#{status})")

      {:error, reason} ->
        Logger.warning("DDNS heartbeat failed: #{inspect(reason_label(reason))}")
    end
  rescue
    error -> Logger.warning("DDNS heartbeat crashed: #{inspect(error.__struct__)}")
  end

  # Transport errors can embed the request; keep only the reason atom.
  defp reason_label(%{reason: reason}) when is_atom(reason), do: reason
  defp reason_label(reason) when is_atom(reason), do: reason
  defp reason_label(_reason), do: :unknown

  defp url, do: config(:url, nil)

  defp config(key, default) do
    :defdo_ddns |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
```

Do **not** use `Exception.message/1` in the rescue: some exception messages
include the request URL.

## Step 3 — Wire it into the monitor

- In `init/1`, once: `unless Heartbeat.enabled?(), do: Logger.info("DDNS heartbeat disabled (DDNS_HEARTBEAT_URL unset)")`.
- In `run_cycle/1`, **after** the ETS status row is written and before
  returning `lines`: `Heartbeat.ping(outcome)`.
- `checkup_once/0` never pings.

Add `alias Defdo.DDNS.Heartbeat`.

## Step 4 — Docs

- README env table: `DDNS_HEARTBEAT_URL` (unset = off; **credential**),
  `DDNS_HEARTBEAT_TIMEOUT_MS` (5000), `DDNS_HEARTBEAT_ON_DEGRADED` (true).
- README `### Heartbeat`: semantics (ok → ping; degraded → ping unless disabled;
  failed → silence), and the receiver setup note from `ddns-heartbeat/README.md`
  ("period slightly longer than `DDNS_REFETCH_EVERY_MS`, e.g. 12 min for the
  5 min default").
- Prepend to `guides/slices/ddns-heartbeat/01-heartbeat-emitter.md`:
  `> **SUPERSEDED (2026-09-26)** by guides/slices/ddns-service-hardening/10-heartbeat-after-cycle.md. Do not execute it.`
- CHANGELOG `## ✨ Features`: heartbeat.

## Tests

`test/ddns_heartbeat_test.exs` (`async: false`; `Req.Test` shared mode;
`capture_log`; restore `Defdo.DDNS.Heartbeat`, `Cloudflare`,
`:cloudflare_req_options` env; the heartbeat URL in tests is
`"https://status.test/ping/SECRET-TOKEN-123"`; the stub records every request
whose `conn.host == "status.test"`):

- `"ok cycle pings once"` — healthy Cloudflare stub; `start_supervised!` the
  monitor (1 h interval) → exactly 1 heartbeat request after its first cycle
  (wait with `Monitor.checkup/0`, which adds a second cycle → assert 2 after it).
- `"failed cycle sends nothing"` — zones stub 521 → 0 heartbeat requests after
  start + one `Monitor.checkup/0`.
- `"degraded pings unless disabled"` — `Heartbeat.ping("degraded")` → 1 request;
  with `send_on_degraded: false` → 0.
- `"no URL, no request"` — url nil; `Heartbeat.ping("ok")` → 0 requests.
- `"endpoint 500, timeout and transport error never raise"` — for each stub,
  `assert Heartbeat.ping("ok") == :ok` and the monitor stays alive after a
  `Monitor.checkup/0`.
- `"the token never reaches the log"` — capture logs across the three failure
  stubs; refute the log contains `"SECRET-TOKEN-123"` or `"status.test/ping"`.
- `"checkup_once never pings"`.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_heartbeat_test.exs
mix test
mix test --seed 8
test -f lib/defdo/ddns/heartbeat.ex
grep -q "Heartbeat.ping(outcome)" lib/defdo/cloudflare/monitor.ex
! grep -nE 'Logger\.[a-z]+\(.*url' lib/defdo/ddns/heartbeat.ex
! grep -n "Exception.message" lib/defdo/ddns/heartbeat.ex
grep -q "DDNS_HEARTBEAT_URL" README.md
grep -q "SUPERSEDED" guides/slices/ddns-heartbeat/01-heartbeat-emitter.md
git diff --check
```

## Acceptance criteria

- [ ] Ping after ok cycles, after degraded unless disabled, never after failed or from `checkup_once/0`.
- [ ] Off with no URL: zero requests, one boot log line.
- [ ] Failure modes never raise or kill the monitor; token absent from logs (test).
- [ ] README, CHANGELOG, superseded banner. Suite green on default seed and seed 8.

## What wrong looks like

- Pinging from `handle_info` before the cycle (proves the process is alive, not that DDNS works).
- Pinging on `"failed"` "to show we are up".
- Logging `url()`, `inspect(error)` of a Req exception, or `Exception.message/1`.
