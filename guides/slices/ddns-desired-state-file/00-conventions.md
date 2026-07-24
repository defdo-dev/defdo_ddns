# Slice 00 - Conventions

## Environment and Build

- Repository: `/Volumes/data/defdo_projects/defdo_ddns`
- Branch at authoring time: `main`
- Commit at authoring time: `22226c2`
- Use `mix format`, `mix compile --warnings-as-errors`, and `mix test` as the default ladder.
- For a clean verification run, use `mix clean && rm -rf _build deps && mix deps.get` before the commands above.
- Runtime config is loaded from `config/runtime.exs`; do not move release boot logic into ad hoc `.exs` helpers.
- The project already has a runtime record snapshot store; this set adds a separate desired-state file and does not replace the runtime snapshot file.

## Ownership Rules

- `Defdo.DDNS.RecordStore` keeps owning runtime record snapshot persistence.
- `Defdo.DDNS.DesiredStateStore` is the new owner of the file-backed desired state for A, AAAA, CNAME, and DNS-planning flags.
- `Defdo.Cloudflare.Monitor` owns sync execution only; it should consume desired state, not parse env directly.
- `config/runtime.exs` may seed the desired-state store from env, but it is not the long-term source of truth.
- `CLOUDFLARE_API_TOKEN` remains env-only.
- Do not add Ecto, migrations, a file watcher, or multi-writer coordination in this slice set.

## Language and Framework Rules

- Keep portable file payloads as string-keyed maps to match the existing snapshot style.
- Preserve deterministic ordering when exporting lists or counts.
- Do not use `String.to_atom/1` on any input path.
- Use `Logger.warning/1` for deprecated env bootstrap or empty fallback conditions.
- Safe diagnostics must never expose raw DNS payloads, tokens, verification strings, or full CNAME targets.

## i18n

- No gettext or translation workflow changes are part of this set.
- Do not add localization strings just to implement the desired-state file.

## Tests

- Existing coverage to protect:
  - `test/ddns_record_store_test.exs`
  - `test/cloudflare_ddns_test.exs`
  - `test/cloudflare_monitor_test.exs`
- New coverage must prove:
  - the desired-state file can seed from current env config once
  - the desired-state file can reload from disk after restart
  - diagnostics stay safe and redacted
  - monitor behavior is unchanged once env vars are removed and the file is present
- "Green" means the full suite passes in a clean environment, not just in a warm working tree.

## Verification Loop

Run these in order:

```sh
mix format
mix compile --warnings-as-errors
mix test test/ddns_desired_state_store_test.exs
mix test test/cloudflare_ddns_test.exs test/cloudflare_monitor_test.exs
mix test
git diff --check
```

## Git

- Use branch prefix `defdo-` when creating a branch for implementation.
- Keep one slice per commit.
- For docs-only work, use `docs(ddns): ...`.
- For implementation work, prefer one logical change per commit and keep the subject under 72 chars.

## Reference Artifact

Current facts verified at `main@22226c2`; re-locate with `rg` before editing if the code has moved.

| Current source of truth | Evidence | Why it matters for this set |
| --- | --- | --- |
| `CLOUDFLARE_A_RECORDS_JSON` / `CLOUDFLARE_AAAA_RECORDS_JSON` / `CLOUDFLARE_CNAME_RECORDS_JSON` are loaded in runtime config | `config/runtime.exs:11-27` | These are the env inputs the new desired-state file must replace after seeding. |
| The monitor reads A/AAAA/CNAME desired inputs at runtime | `lib/defdo/cloudflare/monitor.ex:114-176` | This is the call site that must switch to the file-backed desired state. |
| CNAME lookup already flows through the record-store facade | `lib/defdo/cloudflare/ddns.ex:477-484` | The new desired-state source must preserve the same normalized shape for CNAME entries. |
| Safe runtime diagnostics already exist for the record store | `lib/defdo/ddns/record_store.ex:81-100` and `lib/defdo/ddns/record_stores/file_ets_store.ex:357-391` | The new store should mirror the same redaction and status style. |
| The runtime record snapshot path remains separate | `config/runtime.exs:29-40` and `lib/defdo/ddns/application.ex:13-36` | This set must not collapse runtime snapshots into the desired-state file. |

