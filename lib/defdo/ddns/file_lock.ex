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
