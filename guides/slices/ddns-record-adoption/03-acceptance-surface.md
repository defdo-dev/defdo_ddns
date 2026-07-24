# Slice 03 - Acceptance Surface

## Goal

Let an operator see what was discovered and decide, and make acceptance actually
promote the record into managed desired state.

## Scope

Two surfaces over `Defdo.DDNS.Adoption`, plus the promotion step.

### Promotion

`accept/2` becomes two-phase and atomic from the caller's view:

1. record the decision (Slice 02),
2. write the record into `Defdo.DDNS.DesiredStateStore`.

If the desired-state write fails, the decision must roll back to `pending` and
the call returns `{:error, reason}`. A record must never be marked accepted while
absent from desired state — that state is indistinguishable from a rejection at
the next sync and silently drops the record.

Promotion is idempotent: if the record is already declared, it is a no-op.

### Mix task (operator surface)

```
mix defdo.ddns.adoption.list [--state pending|accepted|rejected|all]
mix defdo.ddns.adoption.accept <id> [--by NAME] [--note TEXT]
mix defdo.ddns.adoption.reject <id> [--by NAME] [--note TEXT]
mix defdo.ddns.adoption.refresh <domain>
```

`list` prints type, name, state and first-seen. It must not print record targets
in full (see conventions on redaction).

### HTTP surface (optional, behind the existing API flag)

Only if `DDNS_API_ENABLED` is true, and reusing the existing auth:

```
GET    /v1/adoption            -> list (filterable by state)
POST   /v1/adoption/:id/accept -> accept
POST   /v1/adoption/:id/reject -> reject
```

These are read/decide endpoints over local state. They do not write to Cloudflare.

## Notes on the existing API

`POST /v1/dns/upsert` currently writes straight to Cloudflare and records nothing
locally, which is precisely how the current drift accumulated. This slice does
not remove it, but any record it creates must be discoverable by `refresh/1` on
the next inventory and land as `pending`. Retiring or rerouting that endpoint
into desired state is separate work — call it out, do not fold it in here.

## Out of Scope

- Deleting or pruning records.
- A web UI.
- Changing `upsert` semantics.

## Acceptance

- `accept` promotes into desired state and the record is `managed` on the next
  inventory.
- A failed desired-state write leaves the entry `pending` and reports an error.
- Accepting twice is a no-op and produces no duplicate desired-state entry.
- The mix tasks operate without a running API.
- Listing redacts targets.
