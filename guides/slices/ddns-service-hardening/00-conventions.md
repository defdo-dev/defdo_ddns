---
kind: implementation
---

# Slice 00 — Conventions

Read this before any slice in the set. Work only inside this repository.

## Environment and build

- Repository: `defdo_ddns`. Authored at `origin/main@2a98d69` (0.5.1), 2026-09-26.
- Toolchain verified: Elixir 1.19.5 / OTP 28.
- Deps: `jason`, `req` 0.6.3, `plug` 1.20.3, `bandit` 1.12.5, `ex_doc` (dev).
  `telemetry` 1.4.2 is present transitively. **Do not add a dependency** in
  this set.
- There is no `config/config.exs` or `config/test.exs`; only `config/runtime.exs`.
  Test-only settings go through `Application.put_env/3` in test setup, restored
  in `on_exit`.
- The driver has no internet. Never run `mix deps.get`, `mix hex.*`, `git fetch`
  or curl from a slice step. If deps are missing, STOP and report.
- If `mix` says `lock mismatch` for `mint`, the checkout's `deps/` is from a
  sibling branch. Do not "fix" `mix.lock`; STOP and report.

## Ownership rules

| Owner | Owns | Must not |
|---|---|---|
| `Defdo.Cloudflare.DDNS` (`lib/defdo/cloudflare/ddns.ex`) | every HTTP call to Cloudflare and to the IP lookup service; record planning (`input_for_update_*`) | read files; know about adoption |
| `Defdo.Cloudflare.Monitor` | *when* a cycle runs and what it did (status) | own HTTP details; contain adoption logic |
| `Defdo.DDNS.Intent` (**new**, slice 04) | "what should exist" for one cycle, from the desired-state file or, when disabled, env + `RecordStore` | write anything |
| `Defdo.DDNS.DesiredStateStore` | the desired-state file, all writes serialized (slice 03) | join the supervision tree (see its moduledoc) |
| `Defdo.DDNS.Adoption` | `adoption.json`, all writes serialized (slice 03) | call Cloudflare write endpoints |
| `Defdo.DDNS.FileLock` (**new**, slice 03) | serializing read-modify-write on one path | hold state; be a process |
| `Defdo.DDNS.API.Router` | HTTP surface and authorization | business logic beyond auth/validation |

Never edit: `deps/`, `_build/`, `mix.lock`, `.woodpecker/`, other slice sets.

## Language and framework rules

- Persisted payloads stay string-keyed maps. Never `String.to_atom/1` on input.
- Every Cloudflare response goes through `decode_envelope/2` before any `Map.*`
  call touches the body. Edge errors (520–527) return **plain text/HTML**, not
  JSON (`ddns.ex` comment block above `cf_auth_headers/0`).
- Anything that reasons about *absence* uses `fetch_dns_records/2`
  (`{:ok, list} | {:error, reason}`), never `list_dns_records/2` (which answers
  `[]` for both "empty" and "failed").
- A checkup must never crash the monitor. Keep the two rescue layers in
  `execute_monitor/0` and `safe_process/1`.
- No `cond` with a single branch plus `true ->`; use `if`. Keep functions small
  enough to read without scrolling — split before adding a tenth branch.
- Logging: record names, types, counts are safe. Tokens never. Record *content*
  (targets/IPs) is already logged by existing success messages — do not add new
  places that log it.

## Tests

- Location: `test/*_test.exs`, helpers in `test/support/test_helpers.exs`.
- All suites that touch application env or named processes are
  `async: false`. Keep new suites `async: false`.
- Stub HTTP with `Req.Test`: in `setup`, call
  `Req.default_options(plug: {Req.Test, __MODULE__})` and in `on_exit` restore
  `Req.default_options([])`. Pattern already used in
  `test/cloudflare_edge_error_test.exs:22` and
  `test/ddns_reconcile_inventory_test.exs:23`. Stubs route on
  `conn.request_path` / `conn.query_string`.
- Every `Application.put_env` in a test is paired with a restore in `on_exit`
  that puts back the previous value **or deletes the key only if it was nil**.
- **Green** means: `mix test` 0 failures **and** `mix test --seed 8` 0 failures
  (seed 8 is the known order-dependence reproducer, see slice 01).

## Verification loop (every slice ends with this, then its own checks)

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test --seed 8
git diff --check
```

Escalation: two failed attempts at the same step → stop and report the failing
output. Do not thrash.

## Git

- Branch per slice from `origin/main` (or from the previous slice's merged
  commit): `defdo-hardening-<NN>-<short-name>`.
- One slice per commit, Conventional Commits (`fix(monitor): ...`,
  `refactor(cloudflare): ...`). Add a `CHANGELOG.md` entry under an
  `# Unreleased` heading at the top (create it if absent) using the existing
  emoji sections (`## 🐞 Fixes`, `## 🧹 Internal`, `## 🔒 Security`).
- Never commit `.tool-versions`, `erl_crash.dump`, `graphify-out/`.

## Ecosystem

This repo has **no defdo package dependencies** (`mix.exs` deps: jason, req,
plug, bandit, ex_doc). There is no `.ai/capabilities.md` to consult. Per-need
`uses:`/`gap:` lines live in each slice.

## Reference artifact — facts computed for this set

All line numbers verified at `origin/main@2a98d69`. Re-locate with the given
grep before editing; code moves.

### A. Who reads DNS intent today (the thing slice 04 moves)

| Call site | Reads | grep |
|---|---|---|
| `monitor.ex:84` | `get_zone_id/1` each cycle | `rg -n "get_zone_id" lib/defdo/cloudflare/monitor.ex` |
| `monitor.ex:91-103` | A/AAAA hostnames via `domain_configured?/2`, `records_to_monitor/2` → `get_cloudflare_key(:domain_mappings / :aaaa_domain_mappings)` | `rg -n "records_to_monitor" lib` |
| `monitor.ex:132` | CNAMEs via `get_cname_records_for_domain/1` → `RecordStore.records()` | `rg -n "get_cname_records_for_domain" lib` |
| `monitor.ex:141` | `get_cloudflare_key(:auto_create_missing_records)` | |
| `monitor.ex:204,233` | `get_cloudflare_key(:proxy_a_records, false)` | |
| `ddns.ex:360-375` `resolve_proxied_value/1` | `:proxy_a_records`, `:proxy_exclude` (via `proxy_excluded?/1`) — reached from `input_for_update_dns_records/2` | `rg -n "resolve_proxied_value" lib` |
| `monitor.ex:462` `log_advanced_certificate_warnings/2` | `proxy_excluded?/1` → `:proxy_exclude` | |
| `monitor.ex:60` | domain list via `get_all_cloudflare_config_domains/0` = keys of A ∪ AAAA mappings. **CNAME-only domains are never processed.** | |
| `inventory.ex:907-930` | same env/RecordStore accessors | `rg -n "declared_records" lib` |
| `DesiredStateStore` readers | **none** outside the store itself and `Adoption`/`API.DNS` (writers) | `rg -n "DesiredStateStore\." lib` |

### B. Read-modify-write sites (slice 03)

| Function | File:line | Temp file |
|---|---|---|
| `DesiredStateStore.seed/1` | `desired_state_store.ex:132` | `write/2` → `file <> ".tmp"` (`:267`) |
| `DesiredStateStore.persist/1` | `:147` | same |
| `DesiredStateStore.update/1` | `:161` | same |
| `DesiredStateStore.declare/1` | `:180` | same |
| `Adoption.refresh/1` | `adoption.ex:49` | `save/1` → `file <> ".tmp"` (`:251`) |
| `Adoption.decide/3` (accept/reject) | `:173` | same |
| `Adoption.rollback/2` | `:129` | same |

Measured on 2026-09-26 (scratch script, `MIX_ENV=test`): 40 concurrent
`DesiredStateStore.declare/1` calls with distinct names → `%{ok: 2, error: 38}`,
and the file held **1** record afterwards.

### C. Req 0.6.3 options — quoted from `deps/req/lib/req/steps.ex`

- `:receive_timeout` — "socket receive timeout in milliseconds, defaults to `15_000`."
- `:retry` — "`:safe_transient` (default) - retry safe (GET/HEAD) requests on one
  of: HTTP 408/429/500/502/503/504 responses; `Req.TransportError` with
  `reason: :timeout | :econnrefused | :closed`". `false` disables.
- `:retry_delay` — default "exponential backoff: 1s, 2s, 4s, 8s, ..."; "can be set
  to a function that receives the retry count (starting at 0) and returns the
  delay". Honors `Retry-After` on 429/503 when not set.
- `:max_retries` — "defaults to `3` (for a total of `4` requests ...)".
- `:retry_log_level` — "Defaults to `:warning`." `false` disables.
- Options passed per request merge over `Req.default_options/1`; the test
  `plug:` default therefore survives explicit per-request options.

### D. Cloudflare API facts

- List DNS records (`GET /zones/:zone_id/dns_records`): query params `page`
  (min 1) and `per_page` (min 1, **max 5,000,000**) — verified against
  developers.cloudflare.com on 2026-09-26. The default page size is not stated
  on that page; do not rely on it — always send `per_page` explicitly.
- Responses carry the v4 envelope `success`, `errors`, `messages`, `result`,
  and for list endpoints `result_info` with `page`, `per_page`, `count`,
  `total_count`, `total_pages`. Treat `result_info` as optional: when absent,
  stop after the current page.
- Global rate limit: 1200 requests per 5 minutes per user token.
- Edge errors 520–527 return non-JSON bodies such as `error code: 521`.

### E. Test order-dependence (slice 01)

- `mix test --seed 8` on a clean checkout: `185 tests, 3 failures`, all
  `FunctionClauseError` in `Keyword.get/3` from `ddns.ex:612`
  (`get_cloudflare_key/2`) inside `Defdo.DDNS.RecordStoreTest`.
- Polluters: `test/api_integration_test.exs:64` and
  `test/integration_test.exs:24` call `Application.delete_env(:defdo_ddns, Cloudflare)`
  with no restore, and assert `FunctionClauseError` as expected behaviour.
- Probe: changing only `ddns.ex:612` to `Application.get_env(:defdo_ddns, Cloudflare, [])`
  makes the 3 RecordStore tests pass on seed 8 and turns exactly those two
  polluter tests red — they are the tests pinning the bug.
