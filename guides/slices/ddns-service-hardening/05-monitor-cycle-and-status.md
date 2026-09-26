---
kind: implementation
serves: []  # internal: prerequisite for phase 2 status/readiness and for ddns-heartbeat
skills: [defdo-exunit-quality-tests]
---

# Slice H05 — One listing per zone, safe on failure, observable cycle

## Ecosystem

- uses: none beyond this repo and OTP (`:ets`).
- gap: none.

## Goal

After this slice:

1. A monitor cycle lists each zone's records **once** (plus one re-read only if
   it wrote something), instead of three listings per declared hostname.
2. If that listing fails, the domain is skipped for the cycle with an `Error -`
   line. **Nothing is created** — today a transient error plus
   `AUTO_CREATE_DNS_RECORDS=true` creates duplicate A records.
3. `Defdo.Cloudflare.Monitor.status/0` returns what the last cycle did
   (outcome, timings, consecutive failures) from ETS, without blocking even
   while a cycle is running.
4. `Monitor.checkup/1` accepts a timeout (default 2 min). Today it uses
   `GenServer.call/2`'s 5 s default and exits the caller on any slow cycle.

The public return shape of `checkup/0`, `checkup_once/0` and
`Defdo.DDNS.checkup/0` (a list) does not change.

## Preconditions

- Read `00-conventions.md`.
- H02 (paginated `fetch_dns_records/2`, `:cloudflare_req_options`) and H04
  (intent passed into `process/2`) merged.

## Decisions (made; do not reopen)

- **D-05a Full-zone listing, filtered in memory.** One paginated
  `fetch_dns_records(zone_id)` per domain per cycle. Name matching is
  case-insensitive (`String.downcase/1` on both sides).
- **D-05b A failed listing fails the domain, never "absent".** Use
  `fetch_dns_records/2`; `list_dns_records/2` is no longer called by the monitor.
- **D-05c Status lives in ETS owned by the monitor process.** A GenServer call
  would block behind a running cycle; `:persistent_term` updates trigger a
  global GC. Table: `:defdo_ddns_monitor_status`, `:set`, `:protected`,
  `read_concurrency: true`, created in `init/1`.
- **D-05d Outcome rules.** Per domain: `:failed` (zone unresolved, listing
  failed, or raised), `:degraded` (completed, ≥1 line starts with `"Error"`),
  `:ok`. Per cycle: `"failed"` if intent failed, the cycle aborted, or every
  domain failed (with ≥1 domain); `"degraded"` if any domain is not `:ok`;
  otherwise `"ok"` (zero domains is `"ok"`).
- **D-05e No zone-id cache in this slice.** It saves one request per domain
  per cycle; not worth the invalidation logic now. Recorded as residue.

## Targets

Verified at `origin/main@2a98d69`, but H04 rewrote `process/2`: re-locate with
the grep, not the line numbers.

- `lib/defdo/cloudflare/monitor.ex`
  - `State` `:9-12` — `rg -n "defstruct" lib/defdo/cloudflare/monitor.ex`
  - `init/1`, `handle_continue/2`, `handle_call(:checkup, ...)`, `handle_info(:keep_monitoring, ...)` `:15-44`
  - `checkup/0` `:49-51`, `checkup_once/0` `:53-55`, `execute_monitor` `:57-71`, `safe_process` `:73-80`
  - listing calls — `rg -n "list_dns_records" lib/defdo/cloudflare/monitor.ex` (3 hits at authoring: `:148`, `:198`, `:381`)
- `lib/defdo/ddns.ex` — add `monitor_status/0` delegate
- `test/ddns_monitor_cycle_test.exs` (new)
- `CHANGELOG.md`

## Step 1 — Structured per-domain result, same public shape

Internally, `safe_process/2` returns `{outcome, lines}` where outcome is
`:ok | :degraded | :failed`:

```elixir
  defp safe_process(domain, intent) do
    case process(domain, intent) do
      {:failed, lines} -> {:failed, lines}
      {:done, lines} -> {domain_outcome(lines), lines}
    end
  rescue
    error ->
      message = "Error - checkup failed for domain=#{domain}: #{Exception.message(error)}"
      Logger.error(message)
      {:failed, [message]}
  end

  defp domain_outcome(lines) do
    if Enum.any?(lines, &String.starts_with?(&1, "Error")), do: :degraded, else: :ok
  end
```

`process/2` returns `{:failed, [message]}` from the zone-unresolved branch and
from the new listing-failure branch (Step 2), and `{:done, lines}` at the end.

`execute_monitor/1` (was `/0`) returns `{cycle_outcome, lines_per_domain}`:

```elixir
  defp execute_monitor do
    Logger.info("Executing checkup...")

    case Defdo.DDNS.Intent.load() do
      {:ok, intent} ->
        results = intent |> Defdo.DDNS.Intent.domains() |> Enum.map(&safe_process(&1, intent))
        {cycle_outcome(Enum.map(results, &elem(&1, 0))), Enum.map(results, &elem(&1, 1))}

      {:error, reason} ->
        message = "Error - desired state unavailable, checkup skipped: #{inspect(reason)}"
        Logger.error(message)
        {"failed", [message]}
    end
  rescue
    error ->
      message = "Error - checkup aborted: #{Exception.message(error)}"
      Logger.error(message)
      {"failed", [message]}
  end

  defp cycle_outcome([]), do: "ok"

  defp cycle_outcome(outcomes) do
    cond do
      Enum.all?(outcomes, &(&1 == :failed)) -> "failed"
      Enum.all?(outcomes, &(&1 == :ok)) -> "ok"
      true -> "degraded"
    end
  end
```

Keep the existing comment block on the `rescue` (why a checkup must never take
the monitor down). The public return (what `checkup/0`, `checkup_once/0`
return) is the second tuple element — exactly today's shape: a list of
per-domain line lists, or a one-element list with the error message.

## Step 2 — One listing per zone

In `process/2`, right after the zone id is resolved:

```elixir
      case fetch_dns_records(zone_id) do
        {:ok, live} ->
          {:done, sync_domain(domain, zone_id, live, intent)}

        {:error, reason} ->
          message =
            "Error - unable to list DNS records for domain=#{domain}; skipping this cycle (#{inspect(reason)})"

          Logger.error(message)
          {:failed, [message]}
      end
```

Move the remainder of today's `process` body into `sync_domain/4`, with these
changes only:

1. Build once: `live_by_name = Enum.group_by(live, &String.downcase(&1["name"] || ""))`
   and a helper `live_for(live_by_name, name) = Map.get(live_by_name, String.downcase(name), [])`.
2. The per-hostname `list_dns_records(zone_id, name: record_name)` in the
   `flat_map` → `live_for(live_by_name, record_name)`.
3. `sync_cname_records/2` → `/3` taking `live_by_name`; inside
   `sync_cname_record`, `list_dns_records(zone_id, name: record_name)` →
   `live_for(live_by_name, record_name)`.
4. The final re-read: only when the cycle wrote (the IP result list, the
   CNAME result list, or created records is non-empty):

   ```elixir
   final_source =
     if wrote? do
       case fetch_dns_records(zone_id) do
         {:ok, records} ->
           records

         {:error, _reason} ->
           Logger.warning("Post-update re-read failed for domain=#{domain}; posture uses pre-update records")
           live
       end
     else
       live
     end
   ```

   then filter `final_source` to the monitored names (case-insensitive) and
   types `A AAAA CNAME` exactly as today's `final_dns_records`.

After this step `rg -n "list_dns_records" lib/defdo/cloudflare/monitor.ex`
returns nothing. Keep every existing log message text.

## Step 3 — Cycle status in ETS

Add to the module:

```elixir
  @status_table :defdo_ddns_monitor_status

  @doc """
  What the last cycle did. Reads ETS, so it answers immediately even while a
  cycle is running. `{:error, :not_running}` when the monitor is not started.
  """
  @spec status() :: {:ok, map()} | {:error, :not_running}
  def status do
    case :ets.whereis(@status_table) do
      :undefined ->
        {:error, :not_running}

      _tid ->
        case :ets.lookup(@status_table, :status) do
          [{:status, status}] -> {:ok, status}
          [] -> {:error, :not_running}
        end
    end
  end
```

In `init/1`, before returning:

```elixir
    :ets.new(@status_table, [:set, :protected, :named_table, read_concurrency: true])

    :ets.insert(@status_table, {:status, %{
      "outcome" => "starting",
      "consecutive_failures" => 0,
      "last_success_at" => nil,
      "refetch_every_ms" => state.refetch_every
    }})
```

Add a private `run_cycle(state)` used by `handle_continue/2`, `handle_info/2`
and `handle_call(:checkup, ...)`:

```elixir
  defp run_cycle(state) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)
    {outcome, lines} = execute_monitor()
    finished_at = DateTime.utc_now()

    previous = elem(status(), 1)
    failed? = outcome == "failed"

    :ets.insert(@status_table, {:status, %{
      "outcome" => outcome,
      "started_at" => DateTime.to_iso8601(started_at),
      "finished_at" => DateTime.to_iso8601(finished_at),
      "duration_ms" => System.monotonic_time(:millisecond) - started_mono,
      "domains" => length(lines),
      "consecutive_failures" => if(failed?, do: previous["consecutive_failures"] + 1, else: 0),
      "last_success_at" => if(failed?, do: previous["last_success_at"], else: DateTime.to_iso8601(finished_at)),
      "refetch_every_ms" => state.refetch_every
    }})

    lines
  end
```

`status/0` inside the monitor process always finds the row (init inserted it),
so `elem(status(), 1)` is safe there. `checkup_once/0` (no process) calls
`execute_monitor/0` and returns `elem(result, 1)`; it does **not** write status.

Add `defdelegate monitor_status(), to: Defdo.Cloudflare.Monitor, as: :status`
to `Defdo.DDNS` with a `@doc` line.

The status map contains no hostnames, IPs or tokens — keep it that way.

## Step 4 — Caller timeout

```elixir
  @spec checkup(timeout()) :: list()
  def checkup(timeout \\ :timer.minutes(2)) do
    GenServer.call(__MODULE__, :checkup, timeout)
  end
```

## Step 5 — CHANGELOG

`# Unreleased`:

- `## 🐞 Fixes`: a failed record listing no longer triggers auto-create (it
  could duplicate A records); `Monitor.checkup/1` no longer exits callers after 5 s.
- `## ✨ Features`: `Defdo.DDNS.monitor_status/0` — last cycle outcome, timings,
  consecutive failures.
- `## 🧹 Internal`: one Cloudflare listing per zone per cycle instead of three
  per declared hostname.

## Tests

`test/ddns_monitor_cycle_test.exs` (`async: false`). Setup: `Req.Test` plug
default, `:cloudflare_req_options` → `retry: false`, Cloudflare env
`auth_token: "t", ipv4_lookup_urls: ["https://ip.test"], domain_mappings: %{"example.com" => ["www", "api"]}, aaaa_domain_mappings: %{}, auto_create_missing_records: true, proxy_a_records: false`,
desired-state disabled; stop any running `Monitor` in `on_exit`; restore env.
A request log `Agent` records `{method, request_path}` for every stub call. The
stub routes: `host == "ip.test"` → `"203.0.113.7"`; `GET /client/v4/zones` →
`[%{"id" => "z1"}]`; `GET .../settings/ssl` → strict; `GET .../dns_records` →
per-test.

- `"one listing per zone when nothing changes"` — dns_records returns A
  records for `example.com`, `www.example.com`, `api.example.com` all with
  content `203.0.113.7`, `proxied: false`, `ttl: 300`. After
  `Monitor.checkup_once()`, exactly **1** `GET .../dns_records` was logged.
- `"one re-read after a write"` — same, but `api.example.com` has content
  `198.51.100.1`; `PUT` stub succeeds. Exactly **2** `GET .../dns_records`.
- `"a failed listing never auto-creates"` — dns_records returns 521 text.
  Result contains a line starting `"Error - unable to list DNS records for domain=example.com"`;
  **no** `POST` was logged. **This test must fail before Step 2** (today it
  POSTs A records); run it before Step 2 and note the failure in the commit body.
- `"status reports the last cycle"` — `Monitor.start_link(refetch_every: :timer.hours(1))`,
  then `Monitor.checkup()`; `{:ok, s} = Monitor.status()`; `s["outcome"] == "ok"`,
  `s["consecutive_failures"] == 0`, `is_binary(s["last_success_at"])`,
  `is_integer(s["duration_ms"])`, `s["domains"] == 1`.
- `"consecutive failures count and reset"` — zones returns 521; start monitor,
  call `Monitor.checkup()` twice → `consecutive_failures == 3` (continue + 2
  calls), outcome `"failed"`. Switch the stub to healthy, `Monitor.checkup()` →
  `consecutive_failures == 0`, outcome `"ok"`.
- `"status answers while a cycle is running"` — zones stub sleeps 500 ms;
  start monitor with a 1 h interval, wait for its first cycle
  (`Monitor.checkup()`), then `Task.async(fn -> Monitor.checkup() end)`,
  `Process.sleep(50)`, and `{micros, {:ok, _}} = :timer.tc(&Monitor.status/0)`;
  assert `micros < 50_000`. `Task.await(task, 5_000)`.
- `"status without a monitor"` — no monitor running → `{:error, :not_running}`.
- `"checkup accepts a timeout"` — `Code.ensure_loaded!(Defdo.Cloudflare.Monitor)`,
  `function_exported?(Defdo.Cloudflare.Monitor, :checkup, 1)`.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_monitor_cycle_test.exs
mix test test/cloudflare_monitor_test.exs test/ddns_monitor_desired_state_test.exs test/cloudflare_ddns_test.exs
mix test
mix test --seed 8
test -f lib/defdo/cloudflare/monitor.ex
! grep -n "list_dns_records" lib/defdo/cloudflare/monitor.ex
grep -q "defdo_ddns_monitor_status" lib/defdo/cloudflare/monitor.ex
grep -q "def checkup(timeout" lib/defdo/cloudflare/monitor.ex
grep -q "monitor_status" lib/defdo/ddns.ex
git diff --check
```

## Acceptance criteria

- [ ] Monitor makes 1 listing per zone per cycle, 2 when it wrote.
- [ ] A failed listing produces an `Error -` line, marks the domain failed, and creates nothing.
- [ ] `Monitor.status/0` and `Defdo.DDNS.monitor_status/0` return the documented map from ETS; non-blocking test passes.
- [ ] `consecutive_failures` increments on failed cycles and resets on success.
- [ ] `checkup/1` takes a timeout, default 2 min; return shape of `checkup/0,1` and `checkup_once/0` unchanged.
- [ ] The failing-listing test failed before the change (noted in commit body).
- [ ] Full suite green on default seed and seed 8.

## What wrong looks like

- Keeping `list_dns_records/2` anywhere in the monitor "for CNAMEs".
- Reading status with `GenServer.call` — it waits behind the running cycle.
- Treating `{:error, _}` from the listing as `[]`.
- Putting hostnames or IPs in the status map.
