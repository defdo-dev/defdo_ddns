---
kind: implementation
serves: []  # internal security narrowing: removes access tenant clients were never meant to have
skills: [defdo-exunit-quality-tests]
---

# Slice H06 — Adoption endpoints require the operator token

## Ecosystem

- uses: plug@1.20.3 — `Plug.Router`, `Plug.Test` (already used).
- gap: none.

## Goal

A request authenticated as a **tenant client** (`x-client-id` + that client's
token) to any `/v1/adoption*` route gets `403 {"status":"error","error":"forbidden"}`
and changes nothing. The operator's global token (`DDNS_API_TOKEN`, mode
`:token`) keeps full access. `POST /v1/dns/upsert` is unchanged.

Today `router.ex:54-93` calls `authorize/1` only: a client scoped to `a.com`
can list every pending host in the estate and accept or reject adoption for
any domain. Adoption is an estate-wide operator decision, not a tenant one.

## Preconditions

- Read `00-conventions.md`.
- H01 merged. Independent of H02–H05.

## Decisions (made; do not reopen)

- **D-06a Operator = auth mode `:token`.** That is the global token, including
  the existing compatibility path (clients configured, no `x-client-id`, valid
  global token → `:token`).
- **D-06b 403, not 401.** The caller is authenticated; it lacks permission.
  401 stays for missing/invalid credentials.
- **D-06c No per-domain client scoping for adoption.** Filtering the list by
  `allowed_base_domains` was considered and rejected: acceptance writes
  estate-wide desired state, and a scoped variant is a product decision.
- Deployments that configure **only** `DDNS_API_CLIENTS_JSON` lose HTTP
  adoption access until they also set `DDNS_API_TOKEN`. Documented in README.

## Targets

Verified at `origin/main@2a98d69`; re-locate with the grep.

- `lib/defdo/ddns/api/router.ex` — adoption routes `:54-93`, `decide/3`
  `:109-128`, `authorize/1` `:130-146`.
  `rg -n 'adoption|defp decide|defp authorize\(' lib/defdo/ddns/api/router.ex`
- `test/ddns_api_test.exs` — `describe "adoption endpoints"` `:535-647`.
  `rg -n 'describe "adoption endpoints"' test/ddns_api_test.exs`
- `README.md` — HTTP API section; `rg -n "Optional HTTP API" README.md`
- `CHANGELOG.md`

## Step 1 — `authorize_operator/1`

Add beside `authorize/1`:

```elixir
  # Adoption decides what the whole estate converges; a tenant client scoped to
  # its own base domains must not list or decide it.
  defp authorize_operator(conn) do
    case authorize(conn) do
      {:ok, %{mode: :token} = auth} -> {:ok, auth}
      {:ok, _client} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end
```

## Step 2 — Use it on every adoption route

In `get "/v1/adoption"`, `post "/v1/adoption/refresh"` and `decide/3`, replace
`authorize(conn)` with `authorize_operator(conn)` and add to each `else`/error
handling:

```elixir
      {:error, :forbidden} ->
        json(conn, 403, %{status: "error", error: "forbidden"})
```

In `post "/v1/adoption/refresh"` the `else` has a `{:error, reason}` catch-all
that returns 502 — the `{:error, :forbidden}` clause must come **before** it,
or a forbidden caller gets `502 discovery_failed`.

Check: `rg -n "authorize\(conn\)" lib/defdo/ddns/api/router.ex` → exactly two
hits: one inside `post "/v1/dns/upsert"`, one inside `authorize_operator/1`.

## Step 3 — README and CHANGELOG

README, HTTP API section — add: "Adoption endpoints (`/v1/adoption*`) require
the operator token (`DDNS_API_TOKEN`). Client tokens from
`DDNS_API_CLIENTS_JSON` receive `403`."

CHANGELOG `# Unreleased` → `## 🔒 Security`:

```
- Adoption endpoints now require the operator token. A tenant client token
  could list every undeclared host in the estate and accept or reject
  adoption for domains outside its `allowed_base_domains`; it now gets 403.
```

## Tests

In `test/ddns_api_test.exs`, `describe "adoption endpoints"`:

1. Fix the setup's env leak: it `put_env`s `Defdo.DDNS.API` without restoring.
   Capture `previous_api = Application.get_env(:defdo_ddns, Defdo.DDNS.API)`
   and `restore(Defdo.DDNS.API, previous_api)` in the existing `on_exit`.
2. Add a helper and tests. Configure clients in the test itself:
   `Application.put_env(:defdo_ddns, Defdo.DDNS.API, token: "secret", clients: [%{"id" => "tenant-a", "token" => "tenant-secret", "allowed_base_domains" => ["defdo.ninja"]}])`
   (with clients in app env and the API not started, `AuthStore.get_clients/0`
   reads app env — `auth_store.ex:30-38`).

   ```elixir
    defp call_as_client(method, path, body \\ nil) do
      conn = conn(method, path, body && Jason.encode!(body))
      conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

      conn
      |> put_req_header("x-client-id", "tenant-a")
      |> put_req_header("authorization", "Bearer tenant-secret")
      |> Router.call([])
    end
   ```

   - `"a client token cannot list adoption"` — `GET /v1/adoption` → 403, body `"error" => "forbidden"`.
   - `"a client token cannot accept, and nothing changes"` — POST accept → 403;
     then `Defdo.DDNS.Adoption.get("cname:foss.defdo.ninja")["state"] == "pending"`
     and the desired-state file has no `foss.defdo.ninja` entry.
   - `"a client token cannot reject"` — 403; entry still pending.
   - `"a client token cannot refresh"` — POST refresh with
     `%{"domain" => "defdo.ninja"}` → 403 (not 502).
   - `"the global token still works when clients are configured"` — same env,
     `call(:get, "/v1/adoption")` (global bearer, no `x-client-id`) → 200.

The existing tests in the describe (global token) must stay green unchanged.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_api_test.exs
mix test
mix test --seed 8
test -f lib/defdo/ddns/api/router.ex
test "$(grep -v 'defp authorize' lib/defdo/ddns/api/router.ex | grep -c 'authorize(conn)')" -eq 2
test "$(grep -c 'authorize_operator(conn)' lib/defdo/ddns/api/router.ex)" -ge 3
grep -q '"forbidden"' test/ddns_api_test.exs
git diff --check
```

## Acceptance criteria

- [ ] All four adoption routes return 403 for a valid client token and change no state.
- [ ] Global token access unchanged, including with clients configured.
- [ ] `POST /v1/dns/upsert` still uses `authorize/1` + `authorize_base_domain/2`.
- [ ] The adoption test setup restores `Defdo.DDNS.API` env.
- [ ] README and CHANGELOG updated. Full suite green on default seed and seed 8.

## What wrong looks like

- Returning 401 for an authenticated client.
- Putting the `:forbidden` clause after the refresh route's `{:error, reason}` catch-all.
- Filtering adoption entries by the client's domains instead of refusing (D-06c).
