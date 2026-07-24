# DDNS Record Adoption

This slice set makes DDNS aware of records that already exist in Cloudflare but
were never declared locally, and gives them a path into managed desired state
through an **explicit human acceptance step**.

## Why

The live `defdo.ninja` zone carries roughly 30 CNAMEs. The DDNS configuration
declares about 13. Everything else — `foss`, `tailwind-hub`, `travel`, `wa`,
`git`, `vault`, `woodpecker`, `hub`, `notifly` — was created by hand, directly in
Cloudflare or through the API side-channel, and DDNS does not know it exists.

That gap is invisible today: nothing reports it, and nothing can converge it.
It also means DDNS cannot be trusted as the source of truth, because "not in the
config" currently means both "should not exist" and "nobody told us yet".

## Principles

- **Discovery is automatic, adoption is not.** An undeclared record is reported,
  never silently absorbed and never silently deleted.
- **Acceptance is explicit and recorded.** Adopting a record is an operator
  decision with an audit trail, not a side effect of a sync run.
- **Rejection is durable.** A record refused once must not reappear as pending on
  every subsequent run.
- **This set never deletes anything in Cloudflare.** Pruning unmanaged records is
  deliberately out of scope; the blast radius is too large for a first pass.

## Slice Order

1. `00-conventions.md`
2. `01-zone-inventory.md`
3. `02-pending-adoption-store.md`
4. `03-acceptance-surface.md`
5. `04-verification.md`

## Dependencies

- Read `00-conventions.md` before any implementation slice.
- This set assumes `ddns-desired-state-file/01-desired-state-store.md` is merged:
  adoption promotes records **into** the desired-state store. If that set is not
  merged yet, merge it first — adopting into env vars is not a target state.
- `04-verification.md` is the durable gate for the whole set.
