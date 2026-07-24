# Slice 01 - Zone Inventory

## Goal

Answer one question truthfully: for each configured zone, which live Cloudflare
records do we declare, which do we not, and which do we declare but are absent?

Read-only. No writes, no adoption, no deletion.

## Scope

New module `Defdo.DDNS.Reconcile.Inventory`.

```elixir
@spec inventory(domain :: String.t()) :: {:ok, report} | {:error, term()}

# report
%{
  "domain" => "defdo.ninja",
  "managed"   => [record, ...],  # declared and live
  "unmanaged" => [record, ...],  # live but not declared
  "missing"   => [record, ...],  # declared but not live
  "counts"    => %{"managed" => 13, "unmanaged" => 17, "missing" => 0}
}
```

Each `record` is normalized through `Defdo.DDNS.RecordSnapshot` so an adopted
record and a declared record compare byte-for-byte.

## Behaviour

1. Resolve the zone id via `get_zone_id/1`. A `nil` zone id is `{:error, :zone_unresolved}`.
2. List live records via `list_dns_records/2` for the types DDNS manages
   (`A`, `AAAA`, `CNAME`). Ignore other types entirely — they are not ours and
   must never appear as unmanaged.
3. Read declared records from the desired-state store.
4. Match on the identity tuple `{type, name}`. Content differences do **not**
   change the class: a declared record whose live content drifted is still
   `managed` (converging it is the monitor's job, not inventory's).
5. Classify and return.

## Failure Handling

This is the subtle part and the reason the slice exists separately.

An empty or failed listing must **never** be read as "everything is unmanaged"
or "everything is missing" — that would turn a transient Cloudflare 521 into a
flood of bogus pending adoptions.

- `list_dns_records/2` returning `[]` after a logged error → `{:error, :listing_failed}`.
- Distinguish "the zone genuinely has no records" from "the call failed" by
  checking the call outcome, not the emptiness of the list. If the current
  return shape cannot express that difference, add a sibling function that
  returns `{:ok, list} | {:error, reason}` rather than inferring from `[]`.

## Out of Scope

- Persisting anything.
- Any mutation of Cloudflare or of desired state.
- Pruning or suggesting deletion of unmanaged records.

## Acceptance

- `inventory/1` returns the three classes with correct counts against a stubbed zone.
- Non-managed record types never appear in any class.
- A stubbed 521 yields `{:error, :listing_failed}` and logs once — it does not
  raise and does not report unmanaged records.
- A declared record with drifted content is classified `managed`, not `missing`.
