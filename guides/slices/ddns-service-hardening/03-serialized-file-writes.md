---
kind: implementation
serves: []  # internal: data integrity of the two JSON stores
skills: [defdo-exunit-quality-tests]
---

# Slice H03 — Serialized writes for desired state and adoption

## Ecosystem

- uses: OTP kernel `:global.trans/4` (no new dependency).
- gap: file locking — **local**: a 30-line module; no defdo package owns file
  persistence, and the need is specific to these two JSON stores.

## Goal

Concurrent writers to `desired_state.json` or `adoption.json` can no longer lose
each other's changes or fail on a shared temp file. Today 40 concurrent
`DesiredStateStore.declare/1` calls produce `%{ok: 2, error: 38}` and a file with
**1** record (`00-conventions.md` §B). After this slice the same run produces 40
`:ok` and 40 records, and no `*.tmp` file is left behind.

The stores stay process-free: `DesiredStateStore`'s moduledoc explains why it
must not join the supervision tree, and `:global.trans/4` needs no process of
ours.

## Preconditions

- Read `00-conventions.md` (§B read-modify-write sites).
- Slice H01 merged.

## Targets

Verified at `origin/main@2a98d69`; re-locate with the grep.

- `lib/defdo/ddns/file_lock.ex` (new)
- `lib/defdo/ddns/desired_state_store.ex` — `seed/1` `:132`, `persist/1` `:147`,
  `update/1` `:161`, `declare/1` `:180`, `write/2` `:264-274`.
  `rg -n "def seed|def persist|def update|def declare|defp write" lib/defdo/ddns/desired_state_store.ex`
- `lib/defdo/ddns/adoption.ex` — `refresh/1` `:49-68`, `rollback/2` `:129-141`,
  `decide/3` `:173-196`, `save/1` `:243-262`.
  `rg -n "def refresh|defp rollback|defp decide|defp save" lib/defdo/ddns/adoption.ex`
- `test/ddns_concurrent_writes_test.exs` (new)
- `CHANGELOG.md`

## Step 1 — Create `Defdo.DDNS.FileLock`

`lib/defdo/ddns/file_lock.ex`:

```elixir
defmodule Defdo.DDNS.FileLock do
  @moduledoc """
  Serializes read-modify-write on one file path within this node.

  Both JSON stores used to load, transform and rename a shared `<file>.tmp`
  with nothing ordering concurrent callers. Bandit serves requests
  concurrently, so two provisioning calls declaring different records raced:
  measured, 40 concurrent declarations left one record on disk.

  `:global.trans/4` is used because it needs no process of ours — the stores
  are deliberately not in the supervision tree — and because it is re-entrant
  for the same requester, so a locked `update/1` may call a locked `persist/1`.
  The lock is released when the holder exits, so a crashed writer cannot wedge
  the store.
  """

  @doc """
  Run `fun` while holding the lock for `path`. Returns `fun`'s result, or
  `{:error, {:lock_unavailable, path}}` if the lock could not be taken.
  """
  @spec with_lock(Path.t(), (-> result)) :: result | {:error, {:lock_unavailable, Path.t()}}
        when result: term()
  def with_lock(path, fun) when is_binary(path) and is_function(fun, 0) do
    resource = {__MODULE__, Path.expand(path)}

    case :global.trans({resource, self()}, fun, [node()], :infinity) do
      :aborted -> {:error, {:lock_unavailable, path}}
      result -> result
    end
  end

  @doc "A temp path unique to this write, beside `path` so rename stays atomic."
  @spec temp_path(Path.t()) :: Path.t()
  def temp_path(path) do
    "#{path}.#{System.unique_integer([:positive])}.tmp"
  end
end
```

`:global.trans/4` signature (OTP kernel docs): `trans({ResourceId, LockRequesterId}, Fun, Nodes, Retries)`,
returns `Fun`'s result or `aborted`. `[node()]` keeps the lock local; it works
on a non-distributed node.

## Step 2 — Lock every write path in `DesiredStateStore`

Wrap, do not restructure. Each public writer's body moves inside
`FileLock.with_lock(file, fn -> ... end)` where `file` is the configured path.
Because `require_path/0` returns `{:error, :disabled}` when unset, take the
path first and lock only when it exists:

```elixir
  def persist(doc) do
    with {:ok, file} <- require_path() do
      FileLock.with_lock(file, fn ->
        with {:ok, canonical} <- DesiredState.new(doc),
             :ok <- write(file, canonical) do
          {:ok, canonical}
        end
      end)
    end
  end
```

Apply the same shape to:

- `seed/1` — the `refuse_existing/2` check **and** the write inside one lock
  (otherwise two first-boot readers both pass the check).
- `update/1` — `load()` and `persist(fun.(doc))` inside one lock.
- `declare/1` — the whole `case load() do ... end` inside one lock. When
  `path()` is nil, keep returning `{:error, :disabled}` without locking.

`load/0` stays unlocked for the read itself (rename makes readers see a whole
file). Its `seed_on_missing/1` path calls `seed/0`, which now locks — that is
enough.

In `write/2`, replace `temp = file <> ".tmp"` with
`temp = FileLock.temp_path(file)`, and on any failure after the temp write,
remove the temp file: add `File.rm(temp)` in the `else` branch (ignore its
result).

## Step 3 — Lock every write path in `Adoption`

- `refresh/1`: keep `Inventory.inventory(domain)` **outside** the lock (it is
  network I/O). Move `known = load()`, the reduce, and `save(entries)` inside
  `FileLock.with_lock(path(), fn -> ... end)`.
- `decide/3`: whole body inside the lock.
- `rollback/2`: whole body inside the lock.
- `accept/2`: do **not** add a lock around the whole function — `decide/3` and
  `rollback/2` lock `adoption.json`, `promote/1` locks `desired_state.json`
  through `DesiredStateStore.declare/1`. Holding one while taking the other
  invites lock-order inversion later.
- `save/1`: `FileLock.temp_path(file)` instead of `file <> ".tmp"`, and
  `File.rm(temp)` on failure.

`path/0` for adoption always returns a string (it defaults), so no nil branch.

## Step 4 — CHANGELOG

Under `# Unreleased` → `## 🐞 Fixes`:

```
- Concurrent writes to the desired-state and adoption files no longer lose
  updates. Parallel `POST /v1/dns/upsert` calls each read the file, added their
  record and renamed a shared temp file over it; measured, 40 concurrent
  declarations left 1 record. Writes are now serialized per file and use a
  unique temp file.
```

## Tests

`test/ddns_concurrent_writes_test.exs`, `async: false`. Setup: a unique tmp dir
(pattern from `test/ddns_desired_state_store_test.exs` setup), point
`DesiredStateStore` and `Adoption` at files inside it via
`Application.put_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore, path: ...)` and
`Application.put_env(:defdo_ddns, Defdo.DDNS.Adoption, path: ...)`, set
`Application.put_env(:defdo_ddns, Cloudflare, [])` so no env seed exists;
restore all three and `File.rm_rf` the dir in `on_exit`.

- `"40 concurrent declarations all persist"` — `Task.async_stream(1..40, ..., max_concurrency: 40)`
  calling `DesiredStateStore.declare(%{"domain" => "example.com", "name" => "h#{i}.example.com", "content" => "example.com", "proxied" => true, "ttl" => 1})`;
  assert every result is `{:ok, _}` and `load/0` returns 40 `cname_records`.
  **This test must fail on `origin/main`** — run it once before Step 2 and
  record the failure in the commit body.
- `"concurrent rejections are all recorded"` — write `adoption.json` directly
  with 30 pending entries (`%{"entries" => %{"cname:hN.example.com" => %{"id" => ..., "state" => "pending", "record" => %{"type" => "CNAME", "name" => ...}, "first_seen" => "2026-01-01T00:00:00Z", "decided_at" => nil, "decided_by" => nil, "note" => nil}}}`),
  reject all 30 concurrently, assert `Adoption.list(:rejected)` has 30 entries.
- `"no temp files are left behind"` — after the two runs above (same test or a
  third one repeating a 20-way declare), `Path.wildcard(Path.join(dir, "*.tmp"))`
  is `[]`.
- `"the lock is re-entrant"` — `FileLock.with_lock(p, fn -> FileLock.with_lock(p, fn -> :inner end) end) == :inner`.
- `"the lock excludes concurrent holders"` — 20 tasks each do
  `with_lock(p, fn -> n = :counters.add(c, 1, 1) ...` : increment an
  "inside" counter, read it, `Process.sleep(2)`, decrement; record the max
  observed value in a second counter via `:counters.get/2`; assert max == 1.

## Verification

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/ddns_concurrent_writes_test.exs
mix test test/ddns_desired_state_store_test.exs test/ddns_adoption_test.exs test/ddns_api_declares_test.exs
mix test
mix test --seed 8
test -f lib/defdo/ddns/file_lock.ex
! grep -n 'file <> ".tmp"' lib/defdo/ddns/desired_state_store.ex lib/defdo/ddns/adoption.ex
test "$(grep -c 'FileLock.with_lock' lib/defdo/ddns/desired_state_store.ex)" -ge 4
test "$(grep -c 'FileLock.with_lock' lib/defdo/ddns/adoption.ex)" -ge 3
git diff --check
```

The two `test -f` / count lines guard against the refutation passing because a
file moved: the `! grep` only means something while both files exist, and the
`-ge` counts prove the locks were added rather than the temp suffix merely
renamed.

## Acceptance criteria

- [ ] `Defdo.DDNS.FileLock` exists with `with_lock/2` and `temp_path/1`.
- [ ] `seed/1`, `persist/1`, `update/1`, `declare/1` lock; `load/0` does not.
- [ ] `refresh/1` (store part only), `decide/3`, `rollback/2` lock; `accept/2` holds no lock itself.
- [ ] No `file <> ".tmp"` remains in either store.
- [ ] The 40-way declare test failed before the change (noted in commit body) and passes after.
- [ ] Full suite green on default seed and seed 8.

## What wrong looks like

- Adding a GenServer to the supervision tree to serialize writes (contradicts
  the store's documented no-process design).
- Locking `Inventory.inventory/1` — a slow Cloudflare call would block every
  adoption decision.
- One global lock for both files, or `accept/2` holding the adoption lock
  while declaring.
