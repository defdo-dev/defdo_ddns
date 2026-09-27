---
kind: implementation
serves: []  # internal: makes existing API/adoption promises true; no new surface
skills: [defdo-exunit-quality-tests, defdo-scoped-refactor-assistant]
supersedes: guides/slices/ddns-desired-state-file/02-monitor-consumes-desired-state.md
---

# Slice H04 — Monitor and inventory consume desired state

## Ecosystem

- uses: none beyond this repo.
- gap: none.

## Goal

When `DDNS_DESIRED_STATE_PATH` is configured, the monitor and the inventory read
**all** DNS intent (A/AAAA hostnames, CNAME records, `auto_create_missing_records`,
`proxy_a_records`, `proxy_exclude`) from the desired-state file, once per cycle,
through a new `Defdo.DDNS.Intent` module. When it is not configured, behaviour
is exactly today's (env + `RecordStore`).

Observable after this slice, and false today:

1. A CNAME declared by `POST /v1/dns/upsert` or accepted through adoption is
   created/converged by the next monitor cycle.
2. A record accepted through adoption is `managed` in the next inventory.
3. A domain that appears only in CNAME declarations is processed.
4. A malformed desired-state file makes the cycle report an error and issue
   **zero** Cloudflare requests — it never falls back to env.

## Preconditions

- Read `00-conventions.md`, especially §A (every intent read site).
- H01 and H03 merged.
- Do **not** execute `ddns-desired-state-file/02-*`; this slice replaces it.

## Decisions (made; do not reopen)

- **D-04a One read per cycle.** `Intent.load/0` is called once at the top of a
  cycle and the result is passed down. Never call it per record (it reads a file).
- **D-04b No fallback on a broken file.** `{:error, reason}` from
  `DesiredStateStore.load/0` other than `:disabled` aborts the cycle. Falling
  back to env would silently resurrect intent someone removed from the file.
- **D-04c CNAME domains are processed.** The domain set becomes
  A-mapping keys ∪ AAAA-mapping keys ∪ non-empty `"domain"` of CNAME entries.
  Without this, a record the API declares for a base domain that has no A
  mapping is never converged — the 0.5.0 promise would stay false.
- **D-04d Old public functions keep their env semantics.** `records_to_monitor/1,2`,
  `get_cname_records_for_domain/1`, `input_for_update_dns_records/2`,
  `resolve_proxied_value/1`, `Defdo.DDNS.configured_domains/0` keep working as
  before (they are public API of the package). The monitor and inventory stop
  using them.

## Targets

Verified at `origin/main@2a98d69`; re-locate with the grep.

- `lib/defdo/ddns/intent.ex` (new)
- `lib/defdo/cloudflare/ddns.ex`
  - `input_for_update_dns_records/2` `:287-315` — `rg -n "def input_for_update_dns_records" lib`
  - `resolve_proxied_value/1` `:360-375`
  - `get_proxy_exclude_patterns/0` `:401-415` — `rg -n "def get_proxy_exclude_patterns" lib`
  - `get_cname_records_for_domain/1` `:538-547`
  - `get_subdomains_for_domain/2` `:556-573`
  - `plan_updates_for_group/2` — `rg -n "defp plan_updates_for_group" lib`
- `lib/defdo/cloudflare/monitor.ex` — `execute_monitor/0` `:57-71`, `safe_process/1` `:73-80`,
  `process/1` `:82-222`, `create_missing_ip_records/7` `:224-275`,
  `maybe_create_missing_ip_records/9` `:308-370`, `log_advanced_certificate_warnings/2` `:462-497`
- `lib/defdo/ddns/reconcile/inventory.ex` — `inventory/1` `:872-878`, `declared_records/1` `:907-930`
- `test/ddns_intent_test.exs` (new), `test/ddns_monitor_desired_state_test.exs` (new)
- `README.md` — has **no** desired-state documentation today (`rg -n "DDNS_DESIRED_STATE_PATH" README.md` is empty). New section goes before `### Optional HTTP API (Bandit)` (`rg -n "Optional HTTP API" README.md`, line 202 at authoring); env table under `## ⚙️ Configuration Options` (line 111)
- `CHANGELOG.md`

## Step 1 — Public seams in `Defdo.Cloudflare.DDNS`

Extract, do not duplicate. Each old function becomes a thin wrapper.

1. `expand_hostnames/2` — from `records_to_monitor/2` + `get_subdomains_for_domain/2`:

   ```elixir
   @doc "Root domain plus normalized subdomains, as `records_to_monitor/2` returns them."
   @spec expand_hostnames(String.t(), list()) :: [String.t()]
   def expand_hostnames(domain, subdomains) when is_binary(domain) and is_list(subdomains) do
     expanded =
       subdomains
       |> Enum.filter(&is_binary/1)
       |> Enum.map(&normalize_subdomain(&1, domain))
       |> Enum.reject(&(&1 == domain))
       |> Enum.uniq()

     [domain | expanded]
   end
   ```

   `get_subdomains_for_domain/2` keeps its `nil` warning branch; its list branch
   becomes `domain |> expand_hostnames(subdomains) |> tl()`.

2. `normalize_cname_records/3` — the pipeline inside `get_cname_records_for_domain/1`:

   ```elixir
   @spec normalize_cname_records(list(), String.t(), boolean()) :: [map()]
   def normalize_cname_records(records, domain, default_proxied)
       when is_list(records) and is_binary(domain) do
     records
     |> Enum.filter(&(record_type(&1) == "CNAME"))
     |> Enum.flat_map(&normalize_cname_record_config(&1, domain, default_proxied))
     |> Enum.uniq_by(&{&1["name"], &1["content"], &1["proxied"], &1["ttl"]})
   end
   ```

   `get_cname_records_for_domain/1` becomes
   `normalize_cname_records(Defdo.DDNS.RecordStore.records(), domain, get_cloudflare_key(:proxy_a_records, false))`.

3. `normalize_proxy_exclude_patterns/1` — the body of `get_proxy_exclude_patterns/0`
   taking the raw value; `get_proxy_exclude_patterns/0` calls it with
   `get_cloudflare_key(:proxy_exclude, [])`.

4. Proxy options threaded through planning. Add:

   ```elixir
   @type proxy_opts :: %{proxy_a_records: boolean(), proxy_exclude: [String.t()]}

   @spec env_proxy_opts() :: proxy_opts()
   def env_proxy_opts do
     %{
       proxy_a_records: get_cloudflare_key(:proxy_a_records, false),
       proxy_exclude: get_proxy_exclude_patterns()
     }
   end

   def resolve_proxied_value(record), do: resolve_proxied_value(record, env_proxy_opts())

   def resolve_proxied_value(record, %{proxy_a_records: true, proxy_exclude: patterns}) do
     not proxy_excluded?(Map.get(record, "name", ""), patterns)
   end

   def resolve_proxied_value(record, _opts), do: Map.get(record, "proxied", false)
   ```

   `input_for_update_dns_records/2` (both map and binary clauses) delegates to a
   new `/3` passing `env_proxy_opts()`; the `/3` map clause holds today's body
   and passes `opts` to `plan_updates_for_group(grouped_records, desired_ip, opts)`,
   which calls `resolve_proxied_value(record, opts)`. Keep the catch-all clause
   for `/3` too.

5. `matches_domain_scope?/2` compares case-insensitively
   (`String.downcase(scope) == String.downcase(domain)`), because
   `Intent.domains/1` folds `Example.com` into `example.com`; an exact match
   would silently drop that CNAME.

6. **Resolve the inherited proxy default at read time.** In env mode a CNAME
   without `proxied` inherits `proxy_a_records` (`normalize_cname_records/3`'s
   `default_proxied`). `Defdo.DDNS.DesiredState` canonicalized a missing
   `proxied` to `false`, which flipped those CNAMEs to DNS-only once the file
   became live; baking `proxy_a_records` in instead would freeze today's value
   (a later policy change would not apply). In `desired_state.ex`
   `normalize_cname_record/1`, use `boolean(get.("proxied"), nil)` and drop
   nil values (`Map.reject(fn {_k, v} -> is_nil(v) end)`) so the key is absent;
   `Intent.cname_records/2` then resolves it against the document's
   `proxy_a_records` on every read. In `DesiredStateStore.entry_for/1`, write
   `"proxied" => record["proxied"]` (nil allowed).

## Step 2 — Create `Defdo.DDNS.Intent`

`lib/defdo/ddns/intent.ex`:

```elixir
defmodule Defdo.DDNS.Intent do
  @moduledoc """
  What DNS should look like, for one cycle, from exactly one source.

  With a desired-state file configured, the file is the only source. Without
  one, intent comes from application env and the record store, as it always
  has. A broken file is an error, never a reason to fall back to env: that
  would resurrect intent someone deliberately removed from the file.

  Load once per cycle and pass the result down; it reads a file.
  """

  alias Defdo.Cloudflare.DDNS
  alias Defdo.DDNS.{DesiredStateStore, RecordStore}

  @type t :: %{required(String.t()) => term()}

  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    case DesiredStateStore.load() do
      {:ok, doc} -> {:ok, from_desired_state(doc)}
      {:error, :disabled} -> {:ok, from_env()}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec from_env() :: t()
  def from_env do
    %{
      "source" => "env",
      "domain_mappings" => mappings(DDNS.get_cloudflare_key(:domain_mappings, %{})),
      "aaaa_domain_mappings" => mappings(DDNS.get_cloudflare_key(:aaaa_domain_mappings, %{})),
      "cname_records" => RecordStore.records(),
      "auto_create_missing_records" => DDNS.get_cloudflare_key(:auto_create_missing_records, false) == true,
      "proxy_a_records" => DDNS.get_cloudflare_key(:proxy_a_records, false) == true,
      "proxy_exclude" => DDNS.get_proxy_exclude_patterns()
    }
  end

  @spec from_desired_state(map()) :: t()
  def from_desired_state(%{"cloudflare" => cf}) do
    %{
      "source" => "desired_state",
      "domain_mappings" => mappings(Map.get(cf, "domain_mappings", %{})),
      "aaaa_domain_mappings" => mappings(Map.get(cf, "aaaa_domain_mappings", %{})),
      # File entries carry no "type"; the normalizer filters on it.
      "cname_records" => Enum.map(Map.get(cf, "cname_records", []), &Map.put(&1, "type", "CNAME")),
      "auto_create_missing_records" => Map.get(cf, "auto_create_missing_records", false),
      "proxy_a_records" => Map.get(cf, "proxy_a_records", false),
      "proxy_exclude" => DDNS.normalize_proxy_exclude_patterns(Map.get(cf, "proxy_exclude", []))
    }
  end

  @doc "A ∪ AAAA mapping keys ∪ CNAME entry domains, sorted."
  @spec domains(t()) :: [String.t()]
  def domains(intent) do
    cname_domains =
      intent["cname_records"]
      |> Enum.map(&(Map.get(&1, "domain") || Map.get(&1, :domain)))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&String.downcase/1)

    # DNS names are case-insensitive: mapping keys were lowercased (and merged)
    # when the intent was built.
    (Map.keys(intent["domain_mappings"]) ++ Map.keys(intent["aaaa_domain_mappings"]) ++ cname_domains)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec hostnames(t(), String.t(), :a | :aaaa) :: [String.t()]
  def hostnames(intent, domain, family) do
    case Map.fetch(intent[mapping_key(family)], String.downcase(domain)) do
      {:ok, subdomains} when is_list(subdomains) -> DDNS.expand_hostnames(domain, subdomains)
      _ -> []
    end
  end

  @spec cname_records(t(), String.t()) :: [map()]
  def cname_records(intent, domain) do
    DDNS.normalize_cname_records(intent["cname_records"], domain, intent["proxy_a_records"])
  end

  @spec proxy_opts(t()) :: DDNS.proxy_opts()
  def proxy_opts(intent) do
    %{proxy_a_records: intent["proxy_a_records"], proxy_exclude: intent["proxy_exclude"]}
  end

  defp mapping_key(:a), do: "domain_mappings"
  defp mapping_key(:aaaa), do: "aaaa_domain_mappings"

  # Lowercase keys; entries differing only in case merge. Without this a
  # mixed-case AAAA key was silently never synced.
  defp mappings(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {domain, hosts}, acc ->
      Map.update(acc, domain |> to_string() |> String.downcase(), List.wrap(hosts), fn existing ->
        Enum.uniq(existing ++ List.wrap(hosts))
      end)
    end)
  end

  defp mappings(_value), do: %{}
end
```

Note the env branch: `records_to_monitor/2` returns `[domain | subs]` only when
the domain is a key of the mapping — `hostnames/3` reproduces that exactly. The
test in Step 5 pins the equivalence.

## Step 3 — Monitor reads intent once per cycle

In `lib/defdo/cloudflare/monitor.ex`:

1. `execute_monitor/0`: inside the existing `rescue`d function body, replace
   `get_all_cloudflare_config_domains() |> Enum.map(&safe_process/1)` with:

   ```elixir
   case Defdo.DDNS.Intent.load() do
     {:ok, intent} ->
       intent
       |> Defdo.DDNS.Intent.domains()
       |> Enum.map(&safe_process(&1, intent))

     {:error, reason} ->
       message = "Error - desired state unavailable, checkup skipped: #{inspect(reason)}"
       Logger.error(message)
       [message]
   end
   ```

2. `safe_process/1` → `safe_process/2` and `process/1` → `process/2`, taking `intent`.
3. In `process/2`, replace each read from §A:
   - A hostnames `:91-96` → `Intent.hostnames(intent, domain, :a)`
   - AAAA hostnames `:98-103` → `Intent.hostnames(intent, domain, :aaaa)`
   - `get_cname_records_for_domain(domain)` → `Intent.cname_records(intent, domain)`
   - `get_cloudflare_key(:auto_create_missing_records)` → `intent["auto_create_missing_records"]`
   - `get_cloudflare_key(:proxy_a_records, false)` (posture, `:204`) → `intent["proxy_a_records"]`
   - `input_for_update_dns_records(..., %{"A" => ..., "AAAA" => ...})` → the `/3`
     form with `Intent.proxy_opts(intent)`
4. `create_missing_ip_records/7`: replace its internal
   `get_cloudflare_key(:proxy_a_records, false)` with a `proxied` argument passed
   from `process/2` (`intent["proxy_a_records"]`); thread it through
   `maybe_create_missing_ip_records` (now `/10`). If the arity grows past what
   reads cleanly, pass a small map `ctx = %{zone_id: ..., ipv4: ..., ipv6: ..., a_names: ..., aaaa_names: ..., cname_names: ..., auto_create: ..., proxied: ...}`
   instead — preferred.
5. `log_advanced_certificate_warnings/2` → `/3` taking `patterns`
   (`intent["proxy_exclude"]`); use `proxy_excluded?(&1, patterns)`.

After this step, check: `rg -n "get_cloudflare_key|records_to_monitor|domain_configured\?|get_cname_records_for_domain|get_all_cloudflare_config_domains" lib/defdo/cloudflare/monitor.ex`
returns **no** hits. `import Defdo.Cloudflare.DDNS` stays.

Do not change the listing calls (`list_dns_records/2`) in this slice — slice
H05 replaces them. Keep every log message text identical.

## Step 4 — Inventory reads the same intent

In `lib/defdo/ddns/reconcile/inventory.ex`:

```elixir
  def inventory(domain) when is_binary(domain) do
    with {:ok, intent} <- Defdo.DDNS.Intent.load(),
         {:ok, zone_id} <- resolve_zone(domain),
         {:ok, live} <- fetch_live(zone_id) do
      build_report(domain, live, declared_records(intent, domain))
    end
  end
```

`declared_records/2` uses `Intent.hostnames(intent, domain, :a | :aaaa)` and
`Intent.cname_records(intent, domain)`, returning the list directly (drop the
`{:ok, _}` wrapper and `declared_hostnames/2`). Intent loads **before** the zone
lookup so a broken file costs no Cloudflare call.

## Step 5 — README and CHANGELOG

README — add a row for `DDNS_DESIRED_STATE_PATH` to the env table (default: unset = disabled; suggested `/var/lib/defdo_ddns/desired_state.json`), and a new `### Desired State File` section before `### Optional HTTP API (Bandit)` stating:

- With `DDNS_DESIRED_STATE_PATH` set, the file is the only source of DNS intent
  for the monitor and inventory; env seed vars only seed a missing file.
- Editing the file takes effect on the next cycle (it is read once per cycle; no
  restart needed).
- A malformed file stops convergence and logs
  `Error - desired state unavailable, checkup skipped`; DDNS does not fall back to env.

CHANGELOG `# Unreleased` → `## 🐞 Fixes`:

```
- The monitor and inventory now read the desired-state file. Records declared
  by `POST /v1/dns/upsert` or accepted through adoption were written to the
  file but never converged, and accepted records kept showing as unmanaged.
  Domains that appear only in CNAME declarations are now processed too.
```

## Tests

`test/ddns_intent_test.exs` (`async: false`; tmp dir + env restore as in
`test/ddns_desired_state_store_test.exs`):

- `"env intent matches records_to_monitor"` — env `domain_mappings: %{"example.com" => ["@", "www", "*.dev", "api.other.org"]}`;
  assert `Intent.hostnames(Intent.from_env(), "example.com", :a) == DDNS.records_to_monitor("example.com", :domain_mappings)`,
  and `[]` for an unmapped domain.
- `"load uses env when the store is disabled"` — no path configured → `{:ok, %{"source" => "env"}}`.
- `"load uses the file when configured and ignores env"` — env maps `env.example.com`,
  file maps `file.example.com` → `Intent.domains/1 == ["file.example.com"]`, source `"desired_state"`.
- `"load fails on a malformed file"` — write `"{"` to the path → `{:error, :malformed_desired_state}`.
- `"domains include CNAME-only domains"` — file with no mappings and one
  cname entry `domain: "cname-only.test"` → `["cname-only.test"]`.
- `"file cname entries normalize like store records"` — entry
  `%{"domain" => "example.com", "name" => "app", "target" => "@", "proxied" => true, "ttl" => 1}`
  → `Intent.cname_records(intent, "example.com") == [%{"type" => "CNAME", "name" => "app.example.com", "content" => "example.com", "proxied" => true, "ttl" => 1}]`.

- `"domains are de-duplicated case-insensitively, mapping spelling wins"` —
  mapping `example.com` + cname entry `domain: "Example.com"` → domains
  `["example.com"]` and `cname_records(intent, "example.com")` still has
  `app.example.com`.

`test/ddns_monitor_desired_state_test.exs` (`async: false`, `Req.Test` stubs,
`:cloudflare_req_options` → `retry: false`; record every request as
`{method, path, decoded_body}` in an `Agent`):

- `"a declared CNAME is created by the next cycle"` — env Cloudflare config has
  no mappings and no cnames; the file declares `app.example.com -> example.com`.
  Stubs: `GET /client/v4/zones` → `[%{"id" => "z1"}]`; `GET .../dns_records` → `[]`
  until a POST has happened; `POST .../dns_records` → `%{"success" => true, "result" => body}`;
  `GET .../settings/ssl` → `%{"success" => true, "result" => %{"value" => "strict"}}`.
  Run `Defdo.Cloudflare.Monitor.checkup_once()`; assert a POST with
  `"name" => "app.example.com"` and `"type" => "CNAME"` was recorded.
- `"a malformed file issues no Cloudflare request"` — write `"{"`, run
  `checkup_once()`; result is one line starting `"Error - desired state unavailable"`
  and the request Agent is empty.
- `"inventory counts an accepted record as managed"` — file declares
  `foss.example.com`; live listing returns a CNAME `foss.example.com` →
  `Inventory.inventory("example.com")` has it under `"managed"`, `"unmanaged"` is `[]`.

Same file, rules the slice says to preserve — each must fail under the named
mutation (run it once):

- `"CNAME-managed names never get A auto-create"` — file maps `example.com =>
  ["app"]` and declares CNAME `app`; empty listing; `auto_create` on → no POST
  of type `A` for `app.example.com`, a POST of type `CNAME` for it.
  Mutation: the `MapSet.member?(ctx.cname_names, record_name)` clause → `false`.
- `"A updates follow the intent's proxy policy"` — `proxy_a_records: true`,
  `proxy_exclude: ["internal.example.com"]`, three live A records proxied
  false → PUTs for `example.com` and `www.example.com` only, all
  `proxied: true, ttl: 1`. Mutation: `Intent.proxy_opts(intent)` → a literal
  `%{proxy_a_records: false, proxy_exclude: []}`.
- `"auto-created A records use the proxy policy"` — empty listing,
  `proxy_a_records: true`, auto-create → one POST `A example.com proxied: true ttl: 1`.
  Mutation: `ctx.proxied` forced to `false`.
- `"mixed-case A and AAAA keys are one zone and both sync"` (ddns_intent_test) —
  A key `example.com`, AAAA key `Example.com` → one domain, both hostname sets.
  Mutation: `mappings/1` without `String.downcase/1`.
- `"an unset CNAME proxied follows proxy_a_records at read time"` (ddns_intent_test) —
  stored entry has no `"proxied"` key; flipping `proxy_a_records` flips the
  resolved value. Mutation: `boolean(get.("proxied"), false)`.
- `"a seeded CNAME keeps the inherited proxy default"` — no file; env
  `proxy_a_records: true` and a CNAME with no `proxied`; first cycle seeds the
  file → POST `CNAME app.example.com proxied: true ttl: 1`. Mutation: the
  `desired_state.ex` default back to `false`.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_intent_test.exs test/ddns_monitor_desired_state_test.exs
mix test test/cloudflare_monitor_test.exs test/cloudflare_ddns_test.exs test/ddns_reconcile_inventory_test.exs test/ddns_adoption_test.exs
mix test
mix test --seed 8
test -f lib/defdo/ddns/intent.ex
test -f lib/defdo/cloudflare/monitor.ex
! grep -nE "get_cloudflare_key|records_to_monitor|domain_configured\?|get_cname_records_for_domain|get_all_cloudflare_config_domains" lib/defdo/cloudflare/monitor.ex
grep -q "Intent.load()" lib/defdo/cloudflare/monitor.ex
grep -q "Intent.load()" lib/defdo/ddns/reconcile/inventory.ex
grep -q "DDNS_DESIRED_STATE_PATH" README.md
grep -q "### Desired State File" README.md
git diff --check
```

## Acceptance criteria

- [ ] `Defdo.DDNS.Intent` exists with `load/0`, `from_env/0`, `from_desired_state/1`, `domains/1`, `hostnames/3`, `cname_records/2`, `proxy_opts/1`.
- [ ] The monitor calls `Intent.load/0` once per cycle and reads no intent from env directly.
- [ ] Inventory uses the same intent and loads it before any Cloudflare call.
- [ ] Old public functions (D-04d) still pass their existing tests unchanged.
- [ ] The three monitor/inventory tests pass; the "declared CNAME is created" test fails on `origin/main`.
- [ ] README and CHANGELOG updated. Full suite green on default seed and seed 8.

## What wrong looks like

- Calling `Intent.load/0` or `DesiredStateStore.load/0` inside `process/2`, a
  per-record loop, or `resolve_proxied_value`.
- Falling back to `Intent.from_env/0` when the file is malformed.
- `Application.put_env` from the file into `:defdo_ddns, Cloudflare` ("projecting"
  the file into env) — it creates the second source of truth this slice removes.
- Deleting or changing the behaviour of the old public functions.
