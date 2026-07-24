# Slice 01 - Desired State Store and File Schema

## Goal

Introduce a file-backed desired-state contract for DDNS planning data.

After this slice lands:

- A/AAAA/CNAME desired state and DNS-planning flags are stored in one canonical file.
- The file can be seeded from the current env config on first boot.
- The file is authoritative on subsequent boots.
- Diagnostics report metadata and counts only, not raw DNS payloads.

## Preconditions

- Read `00-conventions.md`.
- Use the reference artifact in `00-conventions.md` to relocate the current env-driven call sites before editing.

## Targets

- `config/runtime.exs:11-40` verified at `main@22226c2` - re-locate with `rg "CLOUDFLARE_A_RECORDS_JSON|CLOUDFLARE_AAAA_RECORDS_JSON|CLOUDFLARE_CNAME_RECORDS_JSON"`.
- `lib/defdo/ddns/application.ex:11-36` verified at `main@22226c2` - re-locate with `rg "maybe_add_record_store|maybe_add_monitor"`.
- `lib/defdo/ddns/desired_state.ex` (new) - re-locate with `rg "DesiredState"` before editing.
- `lib/defdo/ddns/desired_state_store.ex` (new) - re-locate with `rg "DesiredStateStore"` before editing.
- `test/ddns_desired_state_store_test.exs` (new) - re-locate with `rg "DesiredStateStore"` before writing tests.

## Step 1 - Define the canonical file format

Create `Defdo.DDNS.DesiredState` as the portable codec for the desired-state file.

Use a string-keyed map with this top-level shape:

```elixir
%{
  "version" => 1,
  "updated_at" => "2026-07-24T00:00:00Z",
  "cloudflare" => %{
    "domain_mappings" => %{"example.com" => ["www", "api"]},
    "aaaa_domain_mappings" => %{"example.com" => ["www"]},
    "cname_records" => [
      %{
        "domain" => "example.com",
        "name" => "join",
        "target" => "@",
        "proxied" => true,
        "ttl" => 1
      }
    ],
    "auto_create_missing_records" => true,
    "proxy_a_records" => true,
    "proxy_exclude" => ["*.internal.example.com"]
  }
}
```

Normalization rules:

- Keep `domain_mappings` and `aaaa_domain_mappings` as maps of domain to ordered hostname lists.
- Keep `cname_records` as canonical record maps, reusing the same validation rules the runtime snapshot already uses.
- Reject unknown payload types with a clear error.
- Never expose raw values in diagnostics.

## Step 2 - Add the store facade

Create `Defdo.DDNS.DesiredStateStore` with the same operational shape as the existing record-store facade:

- `status/0`
- `reload/0`
- `persist/0`
- `write_snapshot/2`
- `snapshot/0` or `export_snapshot/0`

Boot behavior:

- Read the file from `DDNS_DESIRED_STATE_PATH`.
- If the file exists, it wins.
- If the file is missing and seed env is present, canonicalize the env config and write the file atomically before starting.
- If the file is missing and no seed env exists, fail loudly instead of booting empty.

Use the same safe write pattern as the record store: temp file plus rename, never partial writes.

## Step 3 - Wire config and startup

Update runtime config so the desired-state store can be initialized from the current env config without requiring a Mix task.

Rules:

- `DDNS_DESIRED_STATE_PATH` defaults to `/var/lib/defdo_ddns/desired_state.json`.
- `DDNS_RECORD_SNAPSHOT_PATH` stays dedicated to runtime record snapshots.
- The desired-state store starts before the monitor.
- Env config remains only a bootstrap seed after the first file write.
- Do not add a merge-on-change watcher here.

## Tests

Add `test/ddns_desired_state_store_test.exs` coverage for:

- file seed from env on first boot
- file reload after env removal
- missing file without seed returns a clear error
- status counts by type without raw payload leakage
- atomic write / persist path

## Verification

```sh
mix compile --warnings-as-errors
mix test test/ddns_desired_state_store_test.exs
```

## Acceptance criteria

- [ ] `Defdo.DDNS.DesiredState` canonicalizes A, AAAA, and CNAME desired state.
- [ ] `Defdo.DDNS.DesiredStateStore` can seed a file from existing env config once.
- [ ] The desired-state file becomes authoritative after the first seed.
- [ ] Diagnostics never expose raw DNS payloads or secret data.
- [ ] Missing desired-state file without a seed fails loudly.
- [ ] No file watcher or background merge loop is added.

