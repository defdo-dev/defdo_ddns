# Slice 02 - Monitor Consumes Desired State

## Goal

Switch monitor execution from env-driven DNS intent to the file-backed desired state.

After this slice lands:

- `Defdo.Cloudflare.Monitor` reads A/AAAA/CNAME intent from the desired-state store.
- `Defdo.Cloudflare.DDNS.get_cname_records_for_domain/1` no longer depends on env-backed record config.
- The app can restart with the seed env vars removed and still recover the same DNS intent from the desired-state file.
- Runtime behavior stays deterministic and release-safe.

## Preconditions

- Read `00-conventions.md`.
- Merge `01-desired-state-store.md` first.

## Targets

- `lib/defdo/cloudflare/monitor.ex:90-176` verified at `main@22226c2` - re-locate with `rg "configured_cname_records|a_records_to_monitor|aaaa_records_to_monitor"`.
- `lib/defdo/cloudflare/ddns.ex:477-484` verified at `main@22226c2` - re-locate with `rg "get_cname_records_for_domain"`.
- `config/runtime.exs:11-27` verified at `main@22226c2` - re-locate with `rg "CLOUDFLARE_A_RECORDS_JSON|CLOUDFLARE_AAAA_RECORDS_JSON|CLOUDFLARE_CNAME_RECORDS_JSON"`.
- `README.md:146-181` verified at `main@22226c2` - re-locate with `rg "Runtime Record Store|legacy seed"`.
- `test/cloudflare_monitor_test.exs` - re-locate with `rg "checkup|monitor"`.
- `test/cloudflare_ddns_test.exs` - re-locate with `rg "get_cname_records_for_domain"`.

## Step 1 - Read desired state from the store

Add a single source of truth for DNS intent, exposed through the new desired-state store.

The store should provide domain-scoped helpers for:

- A hostnames to monitor
- AAAA hostnames to monitor
- CNAME records to sync
- `auto_create_missing_records`
- `proxy_a_records`
- `proxy_exclude`

Keep `CLOUDFLARE_API_TOKEN` and other provider secrets in env.

## Step 2 - Update the monitor and DNS facade

Refactor the monitor to consume the desired-state store helpers instead of `Application.get_env/3` for DNS intent.

Rules:

- Preserve the existing A, AAAA, and CNAME sync logic.
- Preserve the current behavior when a hostname is managed as CNAME and should not auto-create A/AAAA records.
- Preserve the current proxy and TTL rules.
- Preserve the current logging style for skipped records and cloudflare errors.
- Do not add a file watcher. A restart or explicit reload is enough for this slice.

## Step 3 - Update docs and boot narrative

Document the new operational contract:

- Env seed vars are bootstrap-only after the file exists.
- Editing the desired-state file and restarting should apply the new intent.
- Runtime snapshots remain separate and still use `DDNS_RECORD_SNAPSHOT_PATH`.
- `DDNS_RECORD_INIT_PATH` remains only a runtime record-store seed path, not the desired-state source of truth.

## Tests

Add or update tests to prove:

- monitor reads A/AAAA/CNAME intent from the file-backed desired state
- restart without seed env still works once the file exists
- the existing CNAME normalization and A/AAAA auto-create behavior still works
- bootstrap precedence still prefers the file over env seed values

## Verification

```sh
mix compile --warnings-as-errors
mix test test/cloudflare_ddns_test.exs test/cloudflare_monitor_test.exs
mix test
```

## Acceptance criteria

- [ ] Monitor sync uses file-backed desired state for A, AAAA, and CNAME intent.
- [ ] Env seed vars are no longer required after the desired-state file exists.
- [ ] Existing CNAME and A/AAAA synchronization behavior is preserved.
- [ ] The docs explain file editing + restart as the operator workflow.
- [ ] No file watcher or auto-merge loop is introduced.

