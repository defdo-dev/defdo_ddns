# Slice 04 - Verification

The durable gate for the adoption set. Run this in a clean environment, not a
warm working tree.

```sh
mix clean && rm -rf _build deps && mix deps.get
mix format
mix compile --warnings-as-errors
mix test
git diff --check
```

## Functional Gate

Against a `Req.Test`-stubbed zone:

1. **Discovery** — a zone with declared and undeclared records yields the correct
   managed / unmanaged / missing split, and only for `A`, `AAAA`, `CNAME`.
2. **Idempotent discovery** — three consecutive `refresh/1` runs produce the same
   pending set; `added` is zero after the first.
3. **Rejection is durable** — reject, refresh, reload: the record is still
   `rejected` and never `pending`.
4. **Acceptance promotes** — accept, then re-run inventory: the record is now
   `managed`.
5. **Acceptance is atomic** — with the desired-state write forced to fail, the
   entry stays `pending` and the call errors.
6. **Edge error safety** — a stubbed Cloudflare 521 during refresh writes nothing
   and reports an error. This is the regression that matters most: the incident
   that motivated 0.3.4 must not be able to manufacture 30 bogus pending records.
7. **No writes** — assert the stub receives zero POST/PUT/DELETE requests during
   inventory and refresh.

## Operational Gate

Run once against the real zone before considering the set done:

```sh
mix defdo.ddns.adoption.refresh defdo.ninja
mix defdo.ddns.adoption.list --state pending
```

### Measured 2026-07-24 (0.3.4 + adoption set)

Run against the live `defdo.ninja` zone with `DDNS_ENABLE_MONITOR=false` — the
monitor writes, and this gate must prove that nothing here does.

| Check | Result |
| --- | --- |
| Zone records before / after | **55 / 55** — zero writes |
| First refresh | **33 new** |
| Second and third refresh | **0 new, 33 already known** — idempotent |
| Reject one, then refresh | stays rejected; **32 pending, 1 rejected** |

The authoring estimate of "roughly 17" was wrong: it counted only the
application hosts. The real unmanaged set is 33, because the zone also carries
infrastructure records nobody thought of as DDNS's business — an ACME validation
CNAME, `k3s2-etcdb`, `consul`, `db-ninja-nas-prod`, a Mailgun delegation. Most of
those should be *rejected*, not adopted, which is the argument for the decision
step existing at all: a set this size is not something to absorb wholesale.

Expect zero accepted and zero rejected on a first run, and **no change in
Cloudflare** — verify the zone record count is identical before and after.

## Redaction Gate

- No log line or task output contains the Cloudflare token.
- No log line or task output contains a full record target.
- Diagnostics expose counts and states only.
