# Slice 03 - Verification Gate

## Goal

Lock the desired-state file change behind a clean-environment verification gate.

This gate proves the implementation is release-safe, deterministic, and still compatible with the existing DDNS runtime snapshot store.

## Preconditions

- Read `00-conventions.md`.
- Merge `01-desired-state-store.md` and `02-monitor-consumes-desired-state.md`.

## Targets

- `test/ddns_desired_state_store_test.exs` - re-locate with `rg "DesiredStateStore"`.
- `test/cloudflare_monitor_test.exs` - re-locate with `rg "checkup|monitor"`.
- `test/cloudflare_ddns_test.exs` - re-locate with `rg "get_cname_records_for_domain"`.
- `README.md:146-181` verified at `main@22226c2` - re-locate with `rg "Runtime Record Store|desired state"`.
- `CHANGELOG.md:1-40` verified at `main@22226c2` - re-locate with `rg "Unreleased|desired state"`.

## Step 1 - Verify clean-environment behavior

Run the suite in a clean environment, not a warm workspace.

The commands below are the gate:

```sh
mix clean && rm -rf _build deps && mix deps.get
mix compile --warnings-as-errors
mix test test/ddns_desired_state_store_test.exs
mix test test/cloudflare_ddns_test.exs test/cloudflare_monitor_test.exs
mix test
git diff --check
```

## Step 2 - Check the operator workflow

Confirm the release story in one end-to-end smoke:

- create or edit the desired-state file
- remove the env seed vars
- restart the app
- verify the monitor still sees the same A/AAAA/CNAME intent
- verify the runtime snapshot store still persists records independently

## Tests

This slice does not add new product tests. It turns the existing targeted tests into the durable acceptance gate for the set.

## Verification

The commands in Step 1 are the verification.

## Acceptance criteria

- [ ] The clean-environment full suite passes.
- [ ] The desired-state file can be edited and reloaded without env seed vars.
- [ ] The runtime snapshot store still persists independently of the desired-state file.
- [ ] `git diff --check` is clean.

