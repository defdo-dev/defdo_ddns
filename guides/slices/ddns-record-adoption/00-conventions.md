# Slice 00 - Conventions

## Environment and Build

- Repository: `defdo_ddns`
- Branch at authoring time: `defdo-cloudflare-edge-resilience`
- Commit at authoring time: `e79d088` (0.3.4)
- Ladder: `mix format`, `mix compile --warnings-as-errors`, `mix test`.
- Branch prefix for implementation: `defdo-`. One slice per commit.

## Ownership Rules

- `Defdo.DDNS.Reconcile.Inventory` is the new owner of "what is live in the zone
  versus what we declare". It reads; it never writes to Cloudflare.
- `Defdo.DDNS.Adoption` is the new owner of pending/accepted/rejected state.
- `Defdo.DDNS.DesiredStateStore` (from `ddns-desired-state-file`) stays the owner
  of desired state. Adoption writes into it through its public API only.
- `Defdo.Cloudflare.Monitor` keeps owning sync execution. It must not gain
  adoption logic; at most it triggers an inventory refresh.
- `Defdo.Cloudflare.DDNS.list_dns_records/2` is the read primitive. Do not add a
  second HTTP path to Cloudflare.

## Safety Rules

- **No deletions.** No slice in this set may call a Cloudflare delete endpoint.
- **No auto-adoption.** A discovered record enters `pending` and stays there
  until an operator accepts it. There is no config flag that skips this.
- Rejections persist. Re-running inventory must not resurface a rejected record
  as pending.
- Adoption must be idempotent: accepting the same record twice is a no-op, not a
  duplicate desired-state entry.

## Language and Framework Rules

- Keep persisted payloads as string-keyed maps, matching `RecordSnapshot`.
- Preserve deterministic ordering when exporting lists or counts.
- Do not use `String.to_atom/1` on any input path.
- Do not add Ecto, migrations, or a file watcher.
- Reuse `Defdo.DDNS.RecordSnapshot` normalization so an adopted record and a
  declared record are byte-identical in the store.

## Diagnostics and Redaction

- Safe diagnostics must never expose tokens or full record targets.
- Counts, record names and types are safe to log. Content/target values are not;
  truncate or omit them.
- Follow the existing redaction style in `Defdo.DDNS.RecordStore` diagnostics.

## Tests

- Existing coverage to protect:
  - `test/ddns_record_store_test.exs`
  - `test/cloudflare_ddns_test.exs`
  - `test/cloudflare_monitor_test.exs`
  - `test/cloudflare_edge_error_test.exs`
- New coverage must prove:
  - inventory classifies managed / unmanaged / missing correctly
  - an unmanaged record becomes pending exactly once
  - a rejected record never returns to pending
  - accepting promotes into desired state and is idempotent
  - no Cloudflare write or delete is issued by inventory
  - a Cloudflare edge error during inventory degrades without raising
- Stub Cloudflare with `Req.Test`, as `test/cloudflare_edge_error_test.exs` does.

## Verification Loop

```sh
mix format
mix compile --warnings-as-errors
mix test test/ddns_adoption_test.exs
mix test test/ddns_reconcile_inventory_test.exs
mix test
git diff --check
```

## Reference Artifact

| Current fact | Evidence | Why it matters |
| --- | --- | --- |
| Desired state is env-driven today | `config/runtime.exs` `CLOUDFLARE_A_RECORDS_JSON` / `CLOUDFLARE_CNAME_RECORDS_JSON` | Adoption has nowhere durable to write until the desired-state store lands. |
| Live zone holds ~30 CNAMEs, config declares ~13 | Cloudflare zone `defdo.ninja`, verified 2026-07-24 | This is the drift the set exists to close. |
| Record listing is the only read primitive | `lib/defdo/cloudflare/ddns.ex` `list_dns_records/2` | Inventory must reuse it, including its hardened error handling. |
| Cloudflare edge errors return non-JSON bodies | `lib/defdo/cloudflare/ddns.ex` `decode_envelope/2`, 0.3.4 | Inventory must treat an empty/failed listing as "unknown", never as "everything is unmanaged". |
| Snapshot normalization already exists | `Defdo.DDNS.RecordSnapshot` | Adopted records must normalize through it to stay comparable. |
