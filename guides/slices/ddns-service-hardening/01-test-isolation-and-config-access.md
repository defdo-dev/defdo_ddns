---
kind: implementation
serves: []  # internal: makes the suite trustworthy and the package embeddable without config
skills: [defdo-exunit-quality-tests]
---

# Slice H01 — Test isolation and nil-safe config access

## Ecosystem

- uses: none (no defdo deps in this repo).

## Goal

`Defdo.Cloudflare.DDNS.get_cloudflare_key/2` returns its default when
`config :defdo_ddns, Cloudflare` is absent, instead of raising
`FunctionClauseError`. `mix test` is green on **every** seed, including
`--seed 8`, which fails 3 tests today.

## Preconditions

- Read `00-conventions.md` (reference artifact section E).
- No slice dependencies.

## Targets

Verified at `origin/main@2a98d69`. Re-locate with the grep before editing.

- `lib/defdo/cloudflare/ddns.ex:609-614` — `rg -n "def get_cloudflare_key" lib/defdo/cloudflare/ddns.ex`
- `test/api_integration_test.exs:63-75` — `rg -n "handles nil configuration" test`
- `test/integration_test.exs:23-32` — `rg -n "handles missing API token gracefully" test`
- `CHANGELOG.md` (top)

## Step 1 — Reproduce first

Run `mix test --seed 8`. Expected today: `185 tests, 3 failures`, all
`FunctionClauseError` in `Keyword.get/3` called from `get_cloudflare_key/2`.
If the output differs, STOP and report it: the reference artifact is stale.

## Step 2 — Make the accessor nil-safe

In `lib/defdo/cloudflare/ddns.ex`, replace the body of `get_cloudflare_key/2`:

```elixir
  def get_cloudflare_key(key, default) do
    :defdo_ddns
    |> Application.get_env(Cloudflare, [])
    |> Keyword.get(key, default)
  end
```

Keep the `@spec`, `@doc` and the bodiless head
`def get_cloudflare_key(key, default \\ "")` unchanged.

## Step 3 — Fix the two tests that pin the bug and pollute the env

Both tests delete the global config, never restore it, and assert the crash.
Their own comments say the intent is "should handle nil gracefully".

In `test/api_integration_test.exs`, replace the `"handles nil configuration"`
test body with:

```elixir
    test "handles nil configuration" do
      previous = Application.get_env(:defdo_ddns, Cloudflare)
      Application.delete_env(:defdo_ddns, Cloudflare)

      on_exit(fn ->
        if previous, do: Application.put_env(:defdo_ddns, Cloudflare, previous)
      end)

      assert DDNS.get_cloudflare_key(:domain_mappings, %{}) == %{}
      assert DDNS.get_cloudflare_key(:api_token) == ""
      assert DDNS.get_all_cloudflare_config_domains() == []
    end
```

In `test/integration_test.exs`, replace the `"handles missing API token gracefully"`
test body with the same restore pattern and:

```elixir
      assert DDNS.get_cloudflare_key(:api_token) == ""
      assert DDNS.get_cloudflare_key(:auth_token, nil) == nil
```

Use whatever alias the file already uses for `Defdo.Cloudflare.DDNS` (check the
top of each file; do not add a second alias).

## Step 4 — Sweep for the same polluter shape

Run:

```
rg -n "delete_env\(:defdo_ddns" test
```

For every hit **not** inside an `on_exit` callback or a `restore`/`restore_env`
helper that runs from `on_exit`, add the previous-value restore shown in
Step 3. Hits inside restore helpers that delete only when the previous value
was `nil` are correct — leave them.

## Step 5 — CHANGELOG

Under `# Unreleased` → `## 🐞 Fixes`:

```
- `get_cloudflare_key/2` returns its default when `config :defdo_ddns, Cloudflare`
  is absent instead of raising. A host app embedding the package without that
  config no longer crashes on first call, and the test suite no longer fails
  depending on seed.
```

## Tests

- `"handles nil configuration"` (rewritten) — proves the accessor returns
  defaults with the config absent, and restores env.
- `"handles missing API token gracefully"` (rewritten) — same for the token.
- The pre-existing `Defdo.DDNS.RecordStoreTest` tests that failed on seed 8
  are the regression proof; no new test is needed for them.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/api_integration_test.exs test/integration_test.exs
mix test --seed 8
mix test --seed 0
mix test
! grep -n "assert_raise FunctionClauseError" test/api_integration_test.exs test/integration_test.exs
grep -q 'Application.get_env(Cloudflare, \[\])' lib/defdo/cloudflare/ddns.ex
git diff --check
```

## Acceptance criteria

- [ ] `mix test --seed 8` reports 0 failures.
- [ ] `mix test` reports 0 failures.
- [ ] No test in the two target files asserts `FunctionClauseError`.
- [ ] Every `delete_env(:defdo_ddns, ...)` in `test/` outside a restore path has a matching restore.
- [ ] `CHANGELOG.md` has the Unreleased entry.

## What wrong looks like

- Wrapping the call in `rescue` instead of passing a default to `get_env/3`.
- "Fixing" the flake by setting `seed: 0` or `async: false` somewhere — the
  suites are already `async: false`; the defect is state that leaks, not
  concurrency.
