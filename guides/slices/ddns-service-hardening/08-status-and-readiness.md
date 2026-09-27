---
kind: implementation
serves: [P-01, P-02]
skills: [defdo-exunit-quality-tests]
---

# Slice H08 — `/ready` and `GET /v1/status`

## Ecosystem

- uses: plug@1.20.3 / bandit@1.12.5 (existing router and server).
- gap: none.

## Goal

With the HTTP API enabled:

1. `GET /ready` (no auth) answers `200 {"status":"ready"}` when DDNS can do its
   job, else `503 {"status":"not_ready","reasons":[...]}` with short reason
   codes. K3s uses it as the readiness probe (P-01).
2. `GET /v1/status` (operator token only) answers what DDNS is doing: last
   cycle, readiness and reasons, intent source and counts, record-store state,
   pending adoptions. No hostnames, IPs or tokens (P-02).
3. `GET /health` is unchanged (liveness).

## Preconditions

- Read `00-conventions.md`, `product.md` (approved; `## Decisions` Q1, Q2).
- H01–H07 merged (needs `Monitor.status/0` from H05, `authorize_operator/1` from H06).

## Decisions (from product.md — do not reopen)

- Readiness reasons, evaluated in this order, all collected (not first-only):
  `record_store_unavailable`, `desired_state_unavailable`, and — only when the
  monitor is enabled — `monitor_not_running`, `starting`,
  `consecutive_failures`, `stale`.
- `consecutive_failures`: `status["consecutive_failures"] >= max_consecutive_failures` (default 3).
- `stale`: `last_success_at` is set and older than
  `stale_factor * refetch_every_ms` (default factor 3).
- `/ready` body carries only `status` and `reasons`. Detail lives behind the
  operator token in `/v1/status`.

## Targets

Re-locate with the grep; H01–H06 changed these files.

- `lib/defdo/ddns/health.ex` (new)
- `lib/defdo/ddns/api/router.ex` — `get "/health"` (`rg -n 'get "/health"' lib`), `defp authorize_operator` (`rg -n "defp authorize_operator" lib`)
- `config/runtime.exs` — after `config :defdo_ddns, monitor_enabled: ...` (`rg -n "monitor_refetch_every_ms" config/runtime.exs`)
- `README.md` — env table and HTTP API endpoints list (`rg -n "GET /health" README.md`)
- `test/ddns_health_test.exs` (new), `test/ddns_api_status_test.exs` (new)
- `CHANGELOG.md`

## Step 1 — Config

In `config/runtime.exs` add:

```elixir
config :defdo_ddns, Defdo.DDNS.Health,
  max_consecutive_failures:
    Defdo.ConfigHelper.parse_integer_env("DDNS_READY_MAX_CONSECUTIVE_FAILURES", 3, min: 1),
  stale_factor: Defdo.ConfigHelper.parse_integer_env("DDNS_READY_STALE_FACTOR", 3, min: 2)
```

Verify the helper's signature first: `rg -n "def parse_integer_env" lib/defdo/config_helper.ex`
(`parse_integer_env(env_var, default, opts \\ [])`, opts `min:`/`max:`).

## Step 2 — `Defdo.DDNS.Health`

`lib/defdo/ddns/health.ex`:

```elixir
defmodule Defdo.DDNS.Health do
  @moduledoc """
  Readiness and a safe status report for probes and operators.

  Readiness means "DDNS can do its job": the record store is up, intent is
  loadable and — when the monitor is enabled — cycles are completing. The
  report carries counts and timestamps only; never hostnames, IPs or tokens.
  """

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.{Adoption, DesiredStateStore, RecordStore}

  @spec readiness(DateTime.t()) :: {:ready | :not_ready, [String.t()]}
  def readiness(now \\ DateTime.utc_now()) do
    reasons =
      [record_store_reason(), intent_reason()] ++ monitor_reasons(monitor_enabled?(), now)

    case Enum.reject(reasons, &is_nil/1) do
      [] -> {:ready, []}
      list -> {:not_ready, list}
    end
  end

  @spec report(DateTime.t()) :: map()
  def report(now \\ DateTime.utc_now()) do
    {state, reasons} = readiness(now)

    %{
      "ready" => state == :ready,
      "reasons" => reasons,
      "monitor" => monitor_report(),
      "desired_state" => DesiredStateStore.status(),
      "record_store" => record_store_report(),
      "adoption" => adoption_report()
    }
  end

  defp record_store_reason do
    case RecordStore.status() do
      status when is_map(status) -> nil
      {:error, _reason} -> "record_store_unavailable"
    end
  end

  # Read-only check: a probe must never seed (write) the desired-state file.
  defp intent_reason do
    case DesiredStateStore.check() do
      :ok -> nil
      {:error, _reason} -> "desired_state_unavailable"
    end
  end

  defp monitor_reasons(false, _now), do: []

  defp monitor_reasons(true, now) do
    case Monitor.status() do
      {:error, :not_running} -> ["monitor_not_running"]
      {:ok, %{"outcome" => "starting"}} -> ["starting"]
      {:ok, status} -> [failures_reason(status), stale_reason(status, now)]
    end
  end

  defp failures_reason(%{"consecutive_failures" => n}) do
    if n >= config(:max_consecutive_failures, 3), do: "consecutive_failures"
  end

  defp stale_reason(%{"last_success_at" => nil}, _now), do: nil

  defp stale_reason(%{"last_success_at" => at, "refetch_every_ms" => every}, now) do
    {:ok, last, _offset} = DateTime.from_iso8601(at)
    limit_ms = config(:stale_factor, 3) * every

    if DateTime.diff(now, last, :millisecond) > limit_ms, do: "stale"
  end

  defp monitor_report do
    case Monitor.status() do
      {:ok, status} -> status
      {:error, :not_running} -> %{"outcome" => "not_running"}
    end
  end

  # Explicit subset: the backend status map carries atoms, tuples and paths
  # that are either not JSON-encodable or not the operator's business.
  defp record_store_report do
    case RecordStore.status() do
      status when is_map(status) ->
        %{
          "state" => "running",
          "source" => to_string(status[:source]),
          "record_count" => status[:record_count],
          "record_types" => status[:record_types],
          "last_error" => if(status[:last_error], do: inspect(status[:last_error]))
        }

      {:error, reason} ->
        %{"state" => "error", "reason" => inspect(reason)}
    end
  end

  defp adoption_report do
    %{"pending" => length(Adoption.list(:pending))}
  rescue
    error -> %{"state" => "error", "reason" => Exception.message(error)}
  end

  defp monitor_enabled?, do: Application.get_env(:defdo_ddns, :monitor_enabled, true)

  defp config(key, default) do
    :defdo_ddns |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
```

Before writing `record_store_report/0`, confirm the backend's status keys:
`rg -n "defp status_map" -A12 lib/defdo/ddns/record_stores/file_ets_store.ex`
(verified: `source`, `record_count`, `record_types`, `writable?`, `persistent?`,
`last_loaded_at`, `last_persisted_at`, `last_error`, atom keys).

Hot-path note: `readiness/1` runs per probe (K3s default every 10 s). It reads
the desired-state file once and makes one GenServer call to the record store.
That is acceptable; do **not** add caching.

### Step 2b — Read-only desired-state status

`Intent.load/0` → `DesiredStateStore.load/0` **seeds a missing file** when the
environment can seed it — an unauthenticated probe must not write. Add to
`DesiredStateStore` a private `read/0` (like `load/0` but returning
`{:error, :pending_seed}` for a missing, seedable file instead of seeding), a
public `check/0` (`:ok` for loaded, disabled or `:pending_seed`), and make
`status/0` use `read/0` (reporting `"state" => "pending_seed"`). Health uses
`check/0`, as shown above.

## Step 3 — Routes

In `lib/defdo/ddns/api/router.ex`, after `get "/health"`:

```elixir
  # Readiness probe: no auth (probes carry no token), no detail beyond reason codes.
  get "/ready" do
    case Health.readiness() do
      {:ready, []} -> json(conn, 200, %{status: "ready"})
      {:not_ready, reasons} -> json(conn, 503, %{status: "not_ready", reasons: reasons})
    end
  end

  get "/v1/status" do
    case authorize_operator(conn) do
      {:ok, _auth} -> json(conn, 200, Map.put(Health.report(), "status", "ok"))
      {:error, :forbidden} -> json(conn, 403, %{status: "error", error: "forbidden"})
      {:error, :unauthorized} -> json(conn, 401, %{status: "error", error: "unauthorized"})
    end
  end
```

Add `alias Defdo.DDNS.Health`.

## Step 4 — README and CHANGELOG

README:
- Env table: `DDNS_READY_MAX_CONSECUTIVE_FAILURES` (3), `DDNS_READY_STALE_FACTOR` (3).
- Endpoints list: `GET /ready` (probe; 200/503 + reason codes, listing the six
  codes) and `GET /v1/status` (operator token; fields).
- A K3s probe snippet:

  ```yaml
  livenessProbe:
    httpGet: { path: /health, port: 4050 }
  readinessProbe:
    httpGet: { path: /ready, port: 4050 }
    periodSeconds: 10
    failureThreshold: 3
  ```

CHANGELOG `# Unreleased` → `## ✨ Features`: `/ready` and `/v1/status`.

## Tests

`test/ddns_health_test.exs` (`async: false`; restore `:monitor_enabled`,
`Defdo.DDNS.Health`, `DesiredStateStore`, `Cloudflare` env; any monitor via
`start_supervised!`; `Req.Test.set_req_test_to_shared()` as in
`test/ddns_monitor_cycle_test.exs`):

- `"ready when the monitor is disabled and intent loads"` — `:monitor_enabled` false → `{:ready, []}`.
- `"monitor enabled but not running"` → reasons include `"monitor_not_running"`.
- `"starting before the first cycle"` — call `readiness/1` with an ETS row whose
  outcome is `"starting"`: start the monitor with a zones stub that sleeps
  300 ms, `Process.sleep(50)`, assert `"starting"` in reasons.
- `"consecutive failures threshold"` — zones stub returns 521; start monitor,
  `Monitor.checkup()` twice (3 failures) → `"consecutive_failures"` in reasons.
  With `max_consecutive_failures: 10` → not in reasons.
- `"stale last success"` — healthy stub, one successful cycle with
  `refetch_every: 1_000`; `readiness(DateTime.add(DateTime.utc_now(), 10, :second))`
  → `"stale"` in reasons; `readiness(DateTime.utc_now())` → not.
- `"broken desired-state file"` — write `"{"` to the configured path →
  `"desired_state_unavailable"`.
- `"readiness never writes the desired-state file"` — path configured, file
  absent, env seedable → `{:ready, []}` (monitor disabled), report shows
  `pending_seed`, and the file still does not exist.
- `"report carries no hostnames"` — with a healthy cycle for `example.com`
  and a desired-state file declaring `secret-host.example.com`, assert
  `Jason.encode!(Health.report())` contains neither `"example.com"` nor `"203.0.113."`.

`test/ddns_api_status_test.exs` (`async: false`, `Plug.Test` like
`test/ddns_api_test.exs`; set `Defdo.DDNS.API` env with `token: "secret"` and a
client, restore it):

- `"GET /ready is 200 when ready"` / `"GET /ready is 503 with reasons"` (monitor
  enabled, not running) — body `%{"status" => "not_ready", "reasons" => ["monitor_not_running"]}`.
- `"GET /ready needs no token"`.
- `"GET /v1/status requires a token"` → 401.
- `"GET /v1/status forbids client tokens"` → 403.
- `"GET /v1/status with the operator token"` → 200 with keys
  `ready reasons monitor desired_state record_store adoption status`.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_health_test.exs test/ddns_api_status_test.exs
mix test
mix test --seed 8
test -f lib/defdo/ddns/health.ex
grep -q 'get "/ready"' lib/defdo/ddns/api/router.ex
grep -q 'get "/v1/status"' lib/defdo/ddns/api/router.ex
test "$(grep -v 'defp authorize' lib/defdo/ddns/api/router.ex | grep -c 'authorize(conn)')" -eq 2
grep -q "DDNS_READY_MAX_CONSECUTIVE_FAILURES" README.md
grep -q "readinessProbe" README.md
git diff --check
```

## Acceptance criteria

- [ ] `/ready` returns 200/503 per the reason rules; no auth; body has only `status` (+ `reasons`).
- [ ] `/v1/status` is operator-only (401 without token, 403 for clients) and returns the documented keys.
- [ ] The report contains no hostnames or IPs (test).
- [ ] Thresholds configurable via the two env vars.
- [ ] README (env, endpoints, probe snippet) and CHANGELOG updated. Suite green on default seed and seed 8.

## What wrong looks like

- `/ready` returning detail (monitor map, paths) without auth.
- Calling `Monitor.checkup/1` or anything that runs a cycle from a probe.
- Caching readiness in a process.
- Putting `RecordStore.status()` into the JSON as-is (atoms/tuples; `Jason.EncodeError`).
