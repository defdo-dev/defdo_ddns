---
kind: implementation
serves: []  # internal: bounded, correct Cloudflare I/O
skills: [defdo-exunit-quality-tests]
---

# Slice H02 — Cloudflare client hardening

## Ecosystem

- uses: req@0.6.3 — `Req.get/2`, `Req.put/2`, `Req.post/2`, options quoted in `00-conventions.md` §C.
- gap: none.

## Goal

After this slice:

1. Every HTTP call in `Defdo.Cloudflare.DDNS` carries explicit, configurable
   Req options: 10 s receive timeout, 5 s connect timeout, at most 2 retries.
   Tests can disable retries through app env.
2. `get_zone_ssl_mode/1` returns `nil` (and logs) on a Cloudflare edge error
   instead of raising `BadMapError`.
3. `fetch_dns_records/2` returns **every** record in a zone, following
   `result_info.total_pages`, with `per_page` always sent explicitly.
4. Public IP detection tries a list of lookup URLs in order, so one provider
   being down does not stop A/AAAA sync.

## Preconditions

- Read `00-conventions.md` (§C Req, §D Cloudflare).
- Slice H01 merged.

## Targets

Verified at `origin/main@2a98d69`; re-locate with the grep.

- `lib/defdo/cloudflare/ddns.ex`
  - module attributes `:6-9` — `rg -n "@ipv4_lookup_url|@zone_endpoint" lib/defdo/cloudflare/ddns.ex`
  - `fetch_public_ip/2` `:38-56` — `rg -n "defp fetch_public_ip" lib`
  - `get_zone_id/1` `:79-95`
  - `fetch_dns_records/2` `:126-146`
  - `get_zone_ssl_mode/1` `:156-186`
  - `apply_update/2` `:191-198`, `create_dns_record/2` `:204-219`
- `test/cloudflare_edge_error_test.exs` (extend)
- `test/cloudflare_client_test.exs` (new)
- `README.md` — env var table; `rg -n "CLOUDFLARE_PROXY_EXCLUDE" README.md` to find it
- `CHANGELOG.md`

## Step 1 — One place for Req options

Add near the top of `Defdo.Cloudflare.DDNS`, after the module attributes:

```elixir
  @default_req_options [
    receive_timeout: 10_000,
    connect_options: [timeout: 5_000],
    max_retries: 2,
    retry_log_level: :warning
  ]

  @doc false
  # Every outbound call goes through this. Req's implicit defaults are a 15 s
  # receive timeout and 3 retries at 1/2/4 s — one degraded Cloudflare stretch
  # could hold a monitor cycle for minutes. Overridable for tests and hosts via
  # `config :defdo_ddns, :cloudflare_req_options, [...]`.
  @spec req_options() :: keyword()
  def req_options do
    Keyword.merge(
      @default_req_options,
      Application.get_env(:defdo_ddns, :cloudflare_req_options, [])
    )
  end
```

Then pass `req_options()` to **every** `Req.get/put/post` in the module by
appending it to the existing keyword list, e.g.:

```elixir
    Req.get(@zone_endpoint, [headers: cf_auth_headers(), params: [name: domain]] ++ req_options())
```

and in `fetch_public_ip/2`: `Req.get(url, req_options())`.

Check: `rg -n "Req\.(get|put|post)\(" lib/defdo/cloudflare/ddns.ex` — every
hit's line (or its continuation) contains `req_options()`.

Do **not** put `plug:` in the defaults: tests inject it through
`Req.default_options/1`, which per-request options merge over.

## Step 2 — Route `get_zone_ssl_mode/1` through the envelope

Replace the whole function body:

```elixir
  def get_zone_ssl_mode(zone_id) do
    Req.get("#{@zone_endpoint}/#{zone_id}/settings/ssl", [headers: cf_auth_headers()] ++ req_options())
    |> decode_envelope("get_zone_ssl_mode")
    |> case do
      {:ok, %{"success" => true, "result" => %{"value" => ssl_mode}}} when is_binary(ssl_mode) ->
        ssl_mode

      {:ok, body} ->
        Logger.warning(
          "Cloudflare get_zone_ssl_mode: unexpected response #{inspect(Map.get(body, "errors", []))}"
        )

        nil

      {:error, message} ->
        Logger.warning(message)
        nil
    end
  end
```

`decode_envelope/2` already proves the body is a map before the `{:ok, body}`
branch; that is the whole fix.

## Step 3 — Paginate `fetch_dns_records/2`

Replace `fetch_dns_records/2` with a paging loop. Keep its `@doc` and `@spec`;
add one sentence to the doc: "Follows `result_info.total_pages`; returns every
page or an error, never a partial list."

```elixir
  @page_size 5_000
  @max_pages 100

  def fetch_dns_records(zone_id, params \\ []) do
    params = Keyword.put_new(params, :per_page, @page_size)
    fetch_dns_records_page(zone_id, params, 1, [])
  end

  defp fetch_dns_records_page(_zone_id, _params, page, _acc) when page > @max_pages do
    Logger.error("Cloudflare list_dns_records: more than #{@max_pages} pages; refusing a partial answer")
    {:error, :too_many_pages}
  end

  defp fetch_dns_records_page(zone_id, params, page, acc) do
    Req.get(
      "#{@zone_endpoint}/#{zone_id}/dns_records",
      [headers: cf_auth_headers(), params: Keyword.put(params, :page, page)] ++ req_options()
    )
    |> decode_envelope("list_dns_records")
    |> case do
      {:ok, %{"result" => result} = body} when is_list(result) ->
        if more_pages?(body, page) do
          fetch_dns_records_page(zone_id, params, page + 1, [result | acc])
        else
          {:ok, [result | acc] |> Enum.reverse() |> Enum.concat()}
        end

      {:ok, body} ->
        log_api_error("list_dns_records", body)
        {:error, :unexpected_response}

      {:error, message} ->
        Logger.error(message)
        {:error, :listing_failed}
    end
  end

  # `result_info` is optional in practice; without it there is no evidence of
  # another page, so stop.
  defp more_pages?(%{"result_info" => %{"total_pages" => total}}, page)
       when is_integer(total),
       do: page < total

  defp more_pages?(_body, _page), do: false
```

A failure on page 2+ returns the error — **never** the pages fetched so far.
`list_dns_records/2` keeps delegating to `fetch_dns_records/2` unchanged.

## Step 4 — Fallback IP lookup providers

Replace `@ipv4_lookup_url` / `@ipv6_lookup_url` and `get_current_ip_family/1`:

```elixir
  @default_ipv4_lookup_urls ["https://ipv4.icanhazip.com", "https://api.ipify.org"]
  @default_ipv6_lookup_urls ["https://ipv6.icanhazip.com", "https://api6.ipify.org"]

  defp get_current_ip_family(family) do
    family
    |> lookup_urls()
    |> Enum.find_value(&fetch_public_ip(&1, family))
  end

  defp lookup_urls(:ipv4),
    do: get_cloudflare_key(:ipv4_lookup_urls, @default_ipv4_lookup_urls)

  defp lookup_urls(:ipv6),
    do: get_cloudflare_key(:ipv6_lookup_urls, @default_ipv6_lookup_urls)
```

`fetch_public_ip/2` keeps returning `nil` on failure, so `Enum.find_value/2`
moves to the next URL. Add to `config/runtime.exs` inside
`config :defdo_ddns, Cloudflare`:

```elixir
  ipv4_lookup_urls:
    Defdo.ConfigHelper.parse_list_env("DDNS_IPV4_LOOKUP_URLS", [
      "https://ipv4.icanhazip.com",
      "https://api.ipify.org"
    ]),
  ipv6_lookup_urls:
    Defdo.ConfigHelper.parse_list_env("DDNS_IPV6_LOOKUP_URLS", [
      "https://ipv6.icanhazip.com",
      "https://api6.ipify.org"
    ]),
```

Verify `parse_list_env/2` exists with that arity before using it:
`rg -n "def parse_list_env" lib/defdo/config_helper.ex`. Document both env vars
in the README env table.

## Step 5 — CHANGELOG

Under `# Unreleased`:

- `## 🐞 Fixes`: SSL-mode check survives edge errors; full-zone listings are
  paginated (inventory on zones above one page was partial).
- `## ✨ Features`: `DDNS_IPV4_LOOKUP_URLS` / `DDNS_IPV6_LOOKUP_URLS` fallback providers.
- `## 🧹 Internal`: explicit Req timeouts/retries via `:cloudflare_req_options`.

## Tests

Create `test/cloudflare_client_test.exs` (`async: false`, `Req.Test` setup per
conventions, and put `Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)`
in setup with restore). Tests:

- `"req_options/0 has bounded defaults"` — `receive_timeout == 10_000`,
  `max_retries == 2`, `connect_options[:timeout] == 5_000` when the env key is unset
  (delete it inside the test, restore after).
- `"req_options/0 lets app env override"` — with `retry: false` set, `req_options()[:retry] == false`.
- `"fetch_dns_records/2 follows total_pages"` — stub returns page 1
  `result_info: %{"page" => 1, "total_pages" => 3}` with records `a`, page 2
  `b`, page 3 `c` (read `conn.query_params["page"]` after `Plug.Conn.fetch_query_params/1`);
  assert `{:ok, [a, b, c]}` in order, and that 3 requests were made (count with
  an `Agent` or `:counters`).
- `"fetch_dns_records/2 sends per_page explicitly"` — stub asserts
  `conn.query_params["per_page"] == "5000"`.
- `"fetch_dns_records/2 fails whole when a later page fails"` — page 1 ok with
  `total_pages: 2`, page 2 returns 521 text → `{:error, :listing_failed}`.
- `"fetch_dns_records/2 stops without result_info"` — one request, `{:ok, records}`.
- `"current ipv4 falls back to the next provider"` — set
  `ipv4_lookup_urls: ["https://first.test", "https://second.test"]` in the
  Cloudflare env; stub returns 503 for host `first.test`, `"203.0.113.7\n"` for
  `second.test` (route on `conn.host`); assert `DDNS.get_current_ipv4() == "203.0.113.7"`.

Extend `test/cloudflare_edge_error_test.exs` → describe
`"Cloudflare edge error (521, non-JSON body)"`:

- `"get_zone_ssl_mode/1 returns nil instead of raising"` — `stub_edge_error()`,
  assert `nil`, log contains `get_zone_ssl_mode` and `521`.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/cloudflare_client_test.exs test/cloudflare_edge_error_test.exs
mix test
mix test --seed 8
grep -q "def req_options" lib/defdo/cloudflare/ddns.ex
grep -q "total_pages" lib/defdo/cloudflare/ddns.ex
grep -q 'decode_envelope("get_zone_ssl_mode")' lib/defdo/cloudflare/ddns.ex
test "$(grep -v '@spec' lib/defdo/cloudflare/ddns.ex | grep -c 'req_options()')" -ge "$(grep -cE 'Req\.(get|put|post)\(' lib/defdo/cloudflare/ddns.ex)"
grep -q "DDNS_IPV4_LOOKUP_URLS" README.md
git diff --check
```

The count line asserts there are at least as many `req_options()` uses (the
`@spec` line excluded) as there are `Req.get/put/post(` calls. Write each call
so `req_options()` appears once per call, as the snippets above do.

## Acceptance criteria

- [ ] `req_options/0` exists, defaults bounded, overridable by `:cloudflare_req_options`.
- [ ] Every `Req.get/put/post` in `ddns.ex` passes `req_options()`.
- [ ] `get_zone_ssl_mode/1` uses `decode_envelope/2`; the 521 test passes.
- [ ] `fetch_dns_records/2` paginates; the 3-page, failing-page-2 and no-result_info tests pass.
- [ ] IP lookup falls back; the fallback test passes.
- [ ] Full suite green on default seed and seed 8.

## What wrong looks like

- Returning the records gathered so far when a later page fails.
- Adding `plug:` or `retry: false` to `@default_req_options` to make tests pass.
- A `Map.get/2` on a Req body anywhere that did not come out of `decode_envelope/2`.
