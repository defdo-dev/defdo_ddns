---
kind: implementation
serves: [P-01, P-02, P-03, P-04]
skills: [defdo-exunit-quality-tests, defdo-adversarial-review]
---

# Slice H11 — Phase 2 verification gate

## Ecosystem

- uses: bandit@1.12.5 and req@0.6.3 for a real-HTTP product check.
- gap: none.

## Goal

The phase 2 scenarios are walked **as the user does them** — over real HTTP
against a running Bandit server, not through `Plug.Test` — and the phase 2
invariants join the source-invariant test so CI keeps them.

## Preconditions

- Read `00-conventions.md`, `product.md`.
- H08, H09, H10 merged.

## Targets

- `test/ddns_product_scenarios_test.exs` (new)
- `test/ddns_hardening_invariants_test.exs` (extend)
- `guides/slices/ddns-service-hardening/README.md` — append `## Verified (phase 2)`

## Step 1 — Product scenarios over real HTTP

`test/ddns_product_scenarios_test.exs` (`async: false`). Setup: pick a free
port (`{:ok, s} = :gen_tcp.listen(0, []); {:ok, port} = :inet.port(s); :gen_tcp.close(s)`),
`start_supervised!({Bandit, plug: Defdo.DDNS.API.Router, scheme: :http, ip: {127, 0, 0, 1}, port: port})`,
API env `token: "operator-secret"` plus one client, Cloudflare stubbed with
`Req.Test` shared mode. The **test's own** HTTP client must not go through
Req: `Req.default_options(plug: {Req.Test, ...})` would route the probe into
the Cloudflare stub instead of the Bandit server. Use OTP's `:httpc`, which Req
options do not touch:

```elixir
  defp http_get(port, path, headers \\ []) do
    :inets.start()
    url = ~c"http://127.0.0.1:#{port}#{path}"
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
    {:ok, {{_, status, _}, _h, body}} = :httpc.request(:get, {url, hdrs}, [], body_format: :binary)
    {status, Jason.decode!(body)}
  end
```

Scenarios (names are the product ids):

- `"P-01 a converging DDNS is ready"` — healthy stub, monitor started
  (`start_supervised!`), one `Monitor.checkup/0` → `http_get(port, "/ready")`
  is `{200, %{"status" => "ready"}}`.
- `"P-01 an expired token makes DDNS not ready, not dead"` — zones stub returns
  `403` JSON `%{"success" => false, "errors" => [%{"code" => 9109}]}`; after
  start + two `Monitor.checkup/0` → `/ready` is `503` with
  `"consecutive_failures"` in `reasons`, and `/health` is still `200`.
- `"P-02 one command answers what DDNS is doing"` — healthy cycle, then
  `http_get(port, "/v1/status", [{"authorization", "Bearer operator-secret"}])`
  → 200; `body["monitor"]["outcome"] == "ok"`, `body["ready"] == true`,
  `is_integer(body["adoption"]["pending"])`, and
  `Jason.encode!(body)` contains no `"example.com"`.
- `"P-02 a tenant client cannot read status"` → 403 with client headers.
- `"P-03 silence when failing"` — heartbeat URL `https://status.test/ping/T`;
  failing stub → zero `status.test` requests after start + one checkup; switch
  to healthy → one request after the next checkup.
- `"P-04 cycle and request events exist"` — attach to both stop events; one
  checkup produces ≥1 `[:defdo_ddns, :cycle, :stop]` and ≥1
  `[:defdo_ddns, :http, :request, :stop]`.

## Step 2 — Invariants

Append to `test/ddns_hardening_invariants_test.exs`:

```elixir
  test "status is operator-only and readiness has no auth (H08)" do
    src = source!("lib/defdo/ddns/api/router.ex")
    assert src =~ ~s(get "/ready")
    [_, status_route] = String.split(src, ~s(get "/v1/status"), parts: 2)
    assert status_route |> String.split("\n  end", parts: 2) |> hd() =~ "authorize_operator(conn)"
  end

  test "every outbound request is instrumented (H09)" do
    src = source!("lib/defdo/cloudflare/ddns.ex")
    calls = ~r/Req\.(get|put|post)\(/ |> Regex.scan(src) |> length()
    wraps = ~r/instrument\(:(cloudflare|ip_lookup)/ |> Regex.scan(src) |> length()
    assert calls >= 6
    assert wraps >= calls, "#{calls} Req calls but #{wraps} instrument/3 wrappers"
  end

  test "the heartbeat never logs its URL (H10)" do
    src = source!("lib/defdo/ddns/heartbeat.ex")
    refute src =~ ~r/Logger\.\w+\([^\n]*url/, "heartbeat.ex logs the URL"
    refute src =~ "Exception.message", "exception messages can carry the URL"
  end
```

Prove each fails under a violating edit (as in H07 Step 2) and record the
messages in the commit body:

| Test | Violating edit |
|---|---|
| H08 | in `get "/v1/status"`, replace `authorize_operator(conn)` with `authorize(conn)` (and adjust the case clauses so it compiles) |
| H09 | unwrap one `instrument(:cloudflare, ...)` |
| H10 | add `Logger.debug("ping #{url()}")` in `send_ping/0` |

## Step 3 — Clean clone and record

Fresh clone of the pushed branch, `mix deps.get`, then the Verification block.
Append to the set README:

```
## Verified (phase 2)

- Commit: <sha>
- Environment: fresh clone, Elixir <x> / OTP <y>
- mix test: <N> tests, 0 failures; seeds 0, 8, 12345: 0 failures
- Product scenarios P-01..P-04 over real HTTP: pass
- Invariant self-test: 3/3 failed under their violating edit
```

## Verification

```sh
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix test test/ddns_product_scenarios_test.exs test/ddns_hardening_invariants_test.exs
mix test
mix test --seed 0
mix test --seed 8
mix test --seed 12345
grep -q "^## Verified (phase 2)" guides/slices/ddns-service-hardening/README.md
! grep -n "<sha>\|<N>\|<x>\|<y>" guides/slices/ddns-service-hardening/README.md
git diff --check
```

## Acceptance criteria

- [ ] P-01..P-04 pass over real HTTP against Bandit.
- [ ] Three new invariants pass and each failed under its violating edit.
- [ ] Clean-clone run green on all four seed configurations; README records real values.
- [ ] Adversarial review of H08–H11: no open blocker.
