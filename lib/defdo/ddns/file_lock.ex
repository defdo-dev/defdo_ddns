defmodule Defdo.DDNS.FileLock do
  @moduledoc """
  Serializes read-modify-write on one file path within this node.

  Both JSON stores used to load, transform and rename a shared `<file>.tmp`
  with nothing ordering concurrent callers. Bandit serves requests
  concurrently, so two provisioning calls declaring different records raced:
  measured, 40 concurrent declarations left one record on disk.

  `:global` locks are used because they need no process of ours — the stores
  are deliberately not in the supervision tree — and `:global` releases a lock
  when its holder exits, so a crashed writer cannot wedge the store.

  Acquisition is a non-blocking `:global.set_lock/3` (0 retries) polled every
  5–15 ms up to `@timeout_ms`. `:global.trans/4`'s own retry loop backs off
  randomly and grows to seconds under contention: 30 concurrent writers took
  over 5 s.

  `:global` locks are **not** re-entrant: a nested set/del on the same
  resource deletes the lock while the outer holder is still inside.
  Re-entrancy is therefore tracked here, in the process dictionary: a nested
  `with_lock/2` on a path this process already holds runs `fun` directly. That
  matters because `DesiredStateStore.update/1` and `declare/1` reach `seed/0`
  (which locks) from inside their own lock when the file is missing.
  """

  @held :defdo_ddns_file_locks_held
  @timeout_ms 30_000

  @doc """
  Run `fun` while holding the lock for `path`. Returns `fun`'s result, or
  `{:error, {:lock_unavailable, path}}` if the lock could not be taken.
  Re-entrant for the calling process.
  """
  @spec with_lock(Path.t(), (-> result)) :: result | {:error, {:lock_unavailable, Path.t()}}
        when result: term()
  def with_lock(path, fun) when is_binary(path) and is_function(fun, 0) do
    resource = {__MODULE__, Path.expand(path)}
    held = Process.get(@held, MapSet.new())

    if MapSet.member?(held, resource) do
      fun.()
    else
      locked(resource, held, path, fun)
    end
  end

  defp locked(resource, held, path, fun) do
    lock_id = {resource, self()}
    deadline = System.monotonic_time(:millisecond) + @timeout_ms

    case acquire(lock_id, deadline) do
      :ok ->
        Process.put(@held, MapSet.put(held, resource))

        try do
          fun.()
        after
          Process.put(@held, held)
          :global.del_lock(lock_id, [node()])
        end

      :timeout ->
        {:error, {:lock_unavailable, path}}
    end
  end

  defp acquire(lock_id, deadline) do
    cond do
      :global.set_lock(lock_id, [node()], 0) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(5 + :rand.uniform(10))
        acquire(lock_id, deadline)
    end
  end

  @doc "A temp path unique to this write, beside `path` so rename stays atomic."
  @spec temp_path(Path.t()) :: Path.t()
  def temp_path(path) do
    "#{path}.#{System.unique_integer([:positive])}.tmp"
  end
end
