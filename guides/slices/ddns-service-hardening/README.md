---
kind: implementation
---

# DDNS Service Hardening

This set turns `defdo_ddns` from "a loop that usually works" into a service whose
intent has one home, whose writes cannot lose data, whose Cloudflare calls are
bounded, and whose state is observable. It is written from a full read of `lib/`
at `origin/main@2a98d69` (0.5.1) on 2026-09-26.

## Phase 1 is internal — no product.md required

Slices 01–06 change correctness, safety and structure. None of them adds
something a person sees or does, with one deliberate exception that *narrows*
access (slice 06, a security fix). Per `defdo-slice-authoring` a purely internal
set says so here instead of carrying a `product.md`.

Phase 2 (readiness/status endpoint, telemetry, heartbeat wiring) **does** change
what an operator sees. Its scenarios are in `product.md`, approved 2026-09-26.

## Why — defects found in the read (evidence in `00-conventions.md`)

| # | Defect | Where | Consequence |
|---|---|---|---|
| D1 | The monitor never reads the desired-state file. `ddns-desired-state-file/02` was never implemented. | `monitor.ex` reads `Application.get_env` + `RecordStore` only; `DesiredStateStore` is only *written* | `POST /v1/dns/upsert` "declares" records and adoption "accepts" them into a file nothing converges. 0.5.0's "managed from birth" is false in practice. Inventory also ignores the file, so accepted records stay `unmanaged`. |
| D2 | Read-modify-write on `desired_state.json` and `adoption.json` with no serialization and a shared `<file>.tmp` | `desired_state_store.ex:161-201,264-274`, `adoption.ex:49-68,173-196,243-262` | Two concurrent upserts (Bandit serves requests concurrently) → one declaration silently lost, or `File.rename` fails because the other writer already moved `.tmp`. |
| D3 | A failed listing is read as "record absent" by the monitor | `monitor.ex:146-165` uses `list_dns_records/2`, which returns `[]` on error | With `AUTO_CREATE_DNS_RECORDS=true`, one transient Cloudflare error creates a **duplicate A record** (Cloudflare allows several A records per name). |
| D4 | `get_zone_ssl_mode/1` bypasses `decode_envelope/2` | `ddns.ex:156-186` | An edge error page (binary body) hits `Map.get(body, ...)` → `BadMapError`; the per-domain rescue swallows it and the whole domain's result collapses into one error line after writes already happened. |
| D5 | No pagination on the full-zone listing | `ddns.ex:126-146`, used by `inventory.ex:895` | Zones larger than one page are inventoried partially → false `missing`, and unmanaged records on later pages are never discovered. |
| D6 | Req defaults are implicit: 15 s receive timeout, 3 retries with 1/2/4 s backoff on every GET | every `Req.*` call in `ddns.ex` | A degraded Cloudflare stretches one cycle to minutes; `Monitor.checkup/0` uses `GenServer.call/2`'s 5 s default and exits the caller. The test suite spends ~7 s sleeping in retries. |
| D7 | 3 listings per declared hostname per cycle, and `get_zone_id` every cycle | `monitor.ex:148,198,381` | N+1 against a rate-limited API (Cloudflare: 1200 requests / 5 min per user). |
| D8 | Adoption endpoints accept any tenant client token | `router.ex:54-93` call `authorize/1` but never `authorize_base_domain/2` | A tenant client scoped to `a.com` can list every host in the estate and accept/reject adoption for `b.com`. |
| D9 | Order-dependent test failures; `get_cloudflare_key/2` crashes on missing config | `ddns.ex:611-614`; `test/api_integration_test.exs:63-75`, `test/integration_test.exs:23-32` delete the env and never restore it — and assert the crash | `mix test --seed 8` fails 3 tests on a clean checkout. A host app that embeds the package without `config :defdo_ddns, Cloudflare` crashes on the first call. |
| D10 | No record of what the last cycle did | `Monitor.State` holds only `refetch_every` | Nothing can answer "is DDNS converging?" — prerequisite for the heartbeat set and for phase 2. |

## Slice order

| Slice | Title | Serves | Fixes | Depends on |
|---|---|---|---|---|
| `00-conventions.md` | read before any slice | — | — | — |
| `01-test-isolation-and-config-access.md` | green on every seed; nil-safe config | [] internal | D9 | — |
| `02-cloudflare-client-hardening.md` | bounded requests, envelope everywhere, pagination | [] internal | D4 D5 D6 | 01 |
| `03-serialized-file-writes.md` | no lost updates on either JSON file | [] internal | D2 | 01 |
| `04-monitor-consumes-desired-state.md` | one intent source for monitor and inventory | [] internal | D1 | 01, 03 |
| `05-monitor-cycle-and-status.md` | one listing per zone, safe on failure, cycle status | [] internal | D3 D7 D10 (+D6 caller timeout) | 02, 04 |
| `06-adoption-operator-only.md` | adoption requires the operator token | [] internal (security narrowing) | D8 | 01 |
| `07-verification.md` | durable gate for the set | — | — | 01–06 |

02, 03 and 06 are independent of each other and may run in parallel (their
`## Targets` do not overlap). 04 and 05 both edit `monitor.ex` and must be
sequential.

`ddns-desired-state-file/02-monitor-consumes-desired-state.md` is **superseded**
by slice 04 here. Do not execute the old one.

## Phase 2 — operability (product.md approved 2026-09-26)

| Slice | Title | Serves | Depends on |
|---|---|---|---|
| `08-status-and-readiness.md` | `/ready` probe and operator-only `GET /v1/status` | P-01, P-02 | 05, 06 |
| `09-telemetry-events.md` | `:telemetry` spans for cycles and outbound HTTP | P-04 | 05 |
| `10-heartbeat-after-cycle.md` | ping after ok/degraded cycles, silence on failed | P-03 | 05 |
| `11-verification-phase2.md` | scenarios over real HTTP + invariants | P-01..P-04 | 08–10 |

08, 09 and 10 all touch the monitor or router lightly; run them sequentially
(08 → 09 → 10) to avoid merge noise. `10` supersedes `ddns-heartbeat/01`.

## Out of scope (recorded residue)

- Error bodies return `details: inspect(reason)` on 500s (`router.ex:48,120`).
  Low risk (reasons are atoms/paths), but it is internal detail on the wire.
- `Defdo.Cloudflare.DDNS` is 974 lines holding the HTTP client, record planning
  and config parsing. Splitting it is worthwhile, but it should not happen in
  the same set that changes behaviour. Slices 02 and 04 add seams (`req_options/0`,
  `normalize_cname_records/3`, `expand_hostnames/2`) that make that split
  mechanical later.
- Promotional `comment` on every created record (`ddns.ex:208-211`) — product
  decision, not a hardening concern.

## Verified

- Commit: b62e031 (branch `defdo-service-hardening`, slices H01–H07 as commits
  31c5c12, d3d7876, c461d66, 1bbfa1f, 1e630fd, 934017d, b62e031)
- Environment: fresh `git clone` of that commit into a scratch directory,
  `mix deps.get` from `mix.lock`, Elixir 1.19.5 / OTP 28, macOS (darwin arm64)
- `mix format --check-formatted`, `mix deps.unlock --check-unused`,
  `mix compile --warnings-as-errors`: clean
- `mix test`: 225 tests, 0 failures; seeds 0, 8, 12345: 0 failures each
- Invariant self-test (07 Step 2): 5/5 failed under their violating edit, each
  with its own message (recorded in the b62e031 commit body)
- Before/after evidence per slice (each new acceptance test was run against the
  pre-change code and failed): H02 6 tests, H03 2, H04 3, H05 8, H06 4.

## Review findings fed back (2026-09-26)

An adversarial review of H01–H07 (fresh clone, diff only) returned NOT_READY.
Each fix now lives in the step that produces the code; this table says what was
missed and why, so the next author checks the same blind spot.

| # | Missed | Why it was missed | Fix lives in |
|---|---|---|---|
| 1 | `:global.trans/4` is not re-entrant: a nested trans releases the outer lock | The author's scratch check proved "no deadlock" and read it as "re-entrant"; the test pinned the same weak property. A check must assert the property that matters (exclusion after the nested call), not a neighbour of it | 03 Step 1 (FileLock code + warning), 03 Tests |
| 2 | Seeding the file turned inherited `proxied` into explicit `false` | Treated pre-existing code (`DesiredState` canonicalization) as correct because it predated the set; H04 made that code live for the first time | 04 Step 1 item 6, 04 Tests (parity) |
| 3 | No monitor-level tests for rules the slice said to preserve | "Preserve X" was stated as prose, not as a check that fails under mutation | 04 Tests (mutation-named rule tests) |
| 4 | `rollback/2` could reset a newer decision | Copied the rollback shape without asking what can change between two separately locked steps | 03 Step 3 |
| 5 | `"domains" => length(lines)` wrong on whole-cycle failure | Specified a summary field without checking what the value is on every path | 05 Step 1 |
| 6 | Case-sensitive domain de-dup (and then a case-sensitive scope match) | Identity of DNS names is case-insensitive; the slice compared strings | 04 Step 1 item 5, 04 Step 2 |
| 7 | Env-only public accessors undocumented in file mode | D-04d kept them, but nobody told callers | `lib/defdo/ddns.ex` docs |

Re-verified after the fixes: see the `fix(review)` commit.

## Verified (phase 2)

- Commit: fe76a6b (H08 b2a1cbe, H09 0e30491, H10 544dffd, H11 fe76a6b; review
  fixes for phase 1 in fa69abd)
- Environment: fresh `git clone` of that commit, `mix deps.get` from
  `mix.lock`, Elixir 1.19.5 / OTP 28, macOS (darwin arm64)
- `mix format --check-formatted`, `mix deps.unlock --check-unused`,
  `mix compile --warnings-as-errors`: clean
- `mix test`: 269 tests, 0 failures; seeds 0, 8, 12345: 0 failures each
- Product scenarios P-01..P-04 over real HTTP against Bandit: pass
- Invariant self-test: 3/3 failed under their violating edit (messages in the
  fe76a6b commit body)

### Second review pass (re-review of fa69abd)

| # | Missed | Why it was missed | Fix lives in |
|---|---|---|---|
| R1 | Case-insensitive domain de-dup dropped a mixed-case AAAA key | Fixed one comparison (de-dup) without following the value to its other consumer (exact-key lookup) | 04 Step 2 (`mappings/1`, lowercase lookup) |
| R2 | Files seeded by 0.4.0–0.5.1 already carry `proxied: false` | A fix to canonicalization cannot reach data written before it; the author reasoned about new writes only | CHANGELOG upgrade note, README |
| R3 | Inheritance resolved at write time froze the default | Chose "parity at seed" instead of asking when the operator can change the policy | 04 Step 1 item 6 |
| R4 | `/ready` could seed (write) the file | Reused `load/0` on a probe path without checking its side effects | 08 Step 2b |
| R5 | Rollback guard untested | Race guard written without a deterministic sequence test | 03 Tests (`"a failed accept does not reset a decision made meanwhile"`) |
| — | `:global.trans` backoff made 30 writers exceed 5 s | Measured correctness, not latency under contention | 03 Step 1 |

## Verified (after both review passes)

- Commit: 878abfb
- Environment: fresh `git clone`, `mix deps.get` from `mix.lock`, Elixir 1.19.5 / OTP 28, macOS arm64
- format / unused-deps / `compile --warnings-as-errors`: clean
- `mix test`: 273 tests, 0 failures on the default seed and seeds 0, 6, 8, 12345, 777; seed sweep 1–20: 0/20 failing
- Every review fix was shown to fail its test under the matching mutation
- Open item: R2 needs the owner to confirm whether any deployment on 0.4.0–0.5.1 set `DDNS_DESIRED_STATE_PATH` (upgrade note shipped either way)
