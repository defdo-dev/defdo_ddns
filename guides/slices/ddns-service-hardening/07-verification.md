---
kind: implementation
serves: []  # internal: durable gate for the set
skills: [defdo-exunit-quality-tests, defdo-adversarial-review]
---

# Slice H07 — Verification gate

## Ecosystem

- uses: none.
- gap: none.

## Goal

The invariants slices H01–H06 established are enforced by CI on every push,
not by memory: a source-invariant test file runs in `mix test` (which
`.woodpecker/ci.yml` already runs), and the set is proven green in a clean
clone.

## Preconditions

- Read `00-conventions.md`.
- H01–H06 merged.

## Targets

- `test/ddns_hardening_invariants_test.exs` (new)
- `guides/slices/ddns-service-hardening/README.md` — append a `## Verified` section
- `CHANGELOG.md` — promote `# Unreleased` only if the owner asks for a release (not part of this slice)

## Step 1 — Source invariants as a test

`test/ddns_hardening_invariants_test.exs`, `async: true` (reads files only):

```elixir
defmodule Defdo.DDNS.HardeningInvariantsTest do
  @moduledoc """
  Source-level invariants from the ddns-service-hardening slice set. Each one
  guards a defect that was measured, not imagined; see that set's README.
  Every check asserts its file exists before looking inside it, so deleting or
  renaming a file cannot turn a refutation green.
  """
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  defp source!(relative) do
    path = Path.join(@root, relative)
    assert File.regular?(path), "expected #{relative} to exist"
    File.read!(path)
  end

  test "the monitor reads intent through Intent, not env accessors (H04)" do
    src = source!("lib/defdo/cloudflare/monitor.ex")
    assert src =~ "Intent.load()"

    for forbidden <- ~w(get_cloudflare_key records_to_monitor domain_configured? get_cname_records_for_domain get_all_cloudflare_config_domains) do
      refute src =~ forbidden, "monitor.ex must not call #{forbidden}"
    end
  end

  test "the monitor never uses the absence-hiding listing (H05)" do
    src = source!("lib/defdo/cloudflare/monitor.ex")
    assert src =~ "fetch_dns_records("
    refute src =~ "list_dns_records("
  end

  test "every Req call in the Cloudflare client carries req_options (H02)" do
    src = source!("lib/defdo/cloudflare/ddns.ex")
    calls = Regex.scan(~r/Req\.(get|put|post)\(/, src) |> length()
    uses = src |> String.split("\n") |> Enum.reject(&(&1 =~ "@spec")) |> Enum.count(&(&1 =~ "req_options()"))

    assert calls >= 6, "expected at least 6 Req calls, found #{calls}"
    assert uses >= calls, "#{calls} Req calls but only #{uses} req_options() uses"
  end

  test "stores write through a lock and a unique temp file (H03)" do
    for relative <- ["lib/defdo/ddns/desired_state_store.ex", "lib/defdo/ddns/adoption.ex"] do
      src = source!(relative)
      assert src =~ "FileLock.with_lock", "#{relative} must lock its writes"
      assert src =~ "FileLock.temp_path", "#{relative} must use a unique temp path"
      refute src =~ ~s(<> ".tmp"), "#{relative} still uses a shared temp file"
    end
  end

  test "adoption routes are operator-only (H06)" do
    src = source!("lib/defdo/ddns/api/router.ex")
    assert src =~ "defp authorize_operator("

    uses =
      src
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ "defp authorize"))
      |> Enum.count(&(&1 =~ "authorize(conn)"))

    assert uses == 2, "only upsert and authorize_operator/1 may call authorize/1 (found #{uses})"
  end
end
```

## Step 2 — Prove each invariant can fail

For each of the five tests, make the smallest violating edit, run
`mix test test/ddns_hardening_invariants_test.exs`, confirm **that** test
fails with **its** message, then revert:

| Test | Violating edit |
|---|---|
| intent | add `_ = get_cloudflare_key(:x)` inside `monitor.ex` `process/2` |
| listing | add `_ = list_dns_records("z")` anywhere in `monitor.ex` |
| req_options | remove `++ req_options()` from `get_zone_id/1` |
| stores | change `FileLock.temp_path(file)` back to `file <> ".tmp"` in `adoption.ex` |
| adoption | replace one `authorize_operator(conn)` with `authorize(conn)` in `router.ex` |

Record the five observed failure messages in the commit body. An invariant
that stays green under its violating edit is decoration — fix the test.

## Step 3 — Clean-environment run

From a fresh clone of the pushed branch (never the working checkout):

```
git clone --branch <branch> <repo-url> /tmp/ddns-gate && cd /tmp/ddns-gate
mix deps.get
```

(The driver has no internet: the **author/reviewer** does this step, not the
implementing model.) Then run the Verification block below in that clone.

## Step 4 — Record the result

Append to `guides/slices/ddns-service-hardening/README.md`:

```
## Verified

- Commit: <sha>
- Environment: fresh clone, Elixir <x> / OTP <y>, `mix deps.get` from lock
- `mix test`: <N> tests, 0 failures; seeds 0, 8, 12345: 0 failures
- Invariant self-test (07 Step 2): 5/5 failed under their violating edit
```

Fill every placeholder with the real value. A count without an environment is
not evidence.

## Verification

```sh
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix test test/ddns_hardening_invariants_test.exs
mix test
mix test --seed 0
mix test --seed 8
mix test --seed 12345
test -f test/ddns_hardening_invariants_test.exs
grep -q "^## Verified" guides/slices/ddns-service-hardening/README.md
! grep -n "<sha>\|<N>\|<x>\|<y>" guides/slices/ddns-service-hardening/README.md
git diff --check
```

## Acceptance criteria

- [ ] `test/ddns_hardening_invariants_test.exs` exists with the five tests and passes.
- [ ] Each invariant was shown to fail under its violating edit (messages in commit body).
- [ ] Clean-clone run green on default seed and seeds 0, 8, 12345.
- [ ] README `## Verified` section filled with real values.
- [ ] An adversarial review (`defdo-adversarial-review`) of H01–H07 found no open blocker.

## What wrong looks like

- Invariant tests that `File.read/1` and treat `{:error, :enoent}` as "nothing forbidden found".
- A hardcoded count that the next legitimate `Req` call breaks — the
  `req_options` check compares two counts, it does not pin one.
- Running the gate in the checkout that produced the code and calling it clean.
