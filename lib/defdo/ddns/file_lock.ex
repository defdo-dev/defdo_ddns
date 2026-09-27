defmodule Defdo.DDNS.FileLock do
  @moduledoc """
  Serializes read-modify-write on one file path within this node.

  Both JSON stores used to load, transform and rename a shared `<file>.tmp`
  with nothing ordering concurrent callers. Bandit serves requests
  concurrently, so two provisioning calls declaring different records raced:
  measured, 40 concurrent declarations left one record on disk.

  `:global.trans/4` is used because it needs no process of ours — the stores
  are deliberately not in the supervision tree. The lock is released when the
  holder exits, so a crashed writer cannot wedge the store.

  `:global.trans/4` is **not** re-entrant: a nested `trans` on the same
  resource deletes the lock when it returns, while the outer holder is still
  inside. Re-entrancy is therefore tracked here, in the process dictionary: a
  nested `with_lock/2` on a path this process already holds runs `fun`
  directly. That matters because `DesiredStateStore.update/1` and `declare/1`
  reach `seed/0` (which locks) from inside their own lock when the file is
  missing.
  """

  @held :defdo_ddns_file_locks_held

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
    trans = fn ->
      Process.put(@held, MapSet.put(held, resource))

      try do
        fun.()
      after
        Process.put(@held, held)
      end
    end

    case :global.trans({resource, self()}, trans, [node()], :infinity) do
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
