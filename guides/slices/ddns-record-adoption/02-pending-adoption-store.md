# Slice 02 - Pending Adoption Store

## Goal

Give the `unmanaged` records from Slice 01 a durable holding area with three
terminal states, so discovery survives restarts and an operator decision is
remembered.

## Scope

New module `Defdo.DDNS.Adoption`, backed by its own file
(`DDNS_ADOPTION_PATH`), separate from both the runtime snapshot and the
desired-state file.

```elixir
@spec refresh(domain :: String.t()) :: {:ok, %{added: n, unchanged: n}} | {:error, term()}
@spec list(filter :: :pending | :accepted | :rejected | :all) :: [entry]
@spec accept(id :: String.t(), meta :: map()) :: {:ok, entry} | {:error, term()}
@spec reject(id :: String.t(), meta :: map()) :: {:ok, entry} | {:error, term()}
```

## Entry Shape

```elixir
%{
  "id"         => "cname:notifly.defdo.ninja",   # stable: "<type>:<name>", lowercased
  "record"     => %{...},                        # RecordSnapshot-normalized
  "state"      => "pending" | "accepted" | "rejected",
  "first_seen" => "2026-07-24T06:20:37Z",
  "decided_at" => nil | "...",
  "decided_by" => nil | "operator string",
  "note"       => nil | "why"
}
```

The id is derived, not random: re-discovering the same record must map to the
same entry.

## Behaviour

- `refresh/1` runs Slice 01's inventory and inserts every `unmanaged` record that
  has no entry yet as `pending`. Records with an existing entry in **any** state
  are left untouched — this is what stops a rejected record from resurfacing.
- `refresh/1` propagates inventory errors unchanged. A failed inventory writes
  nothing.
- `accept/2` and `reject/2` only act on `pending` entries; acting on an already
  decided entry is a no-op returning the existing entry, not an error.
- Accepting does **not** itself write desired state — Slice 03 owns that
  promotion. This slice only records the decision.
- Every state transition is persisted immediately; a crash must not lose a
  decision.

## Persistence

- Reuse the atomic write approach already used by the record store (write temp,
  rename) so a partial file is never observable.
- On load, a malformed file is a hard error with a clear message; do not silently
  reset to empty, because that would discard rejections and resurface records.

## Out of Scope

- Promotion into desired state (Slice 03).
- Any operator-facing surface (Slice 03).
- Automatic acceptance under any flag.

## Acceptance

- An unmanaged record appears as `pending` exactly once across repeated refreshes.
- A rejected record never returns to `pending`, including after a reload.
- Accept/reject persist across a store reload.
- A failed inventory leaves the store byte-identical.
- Ids are stable and case-insensitive on the record name.
