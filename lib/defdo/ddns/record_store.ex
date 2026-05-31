defmodule Defdo.DDNS.RecordStore do
  @moduledoc """
  Behaviour and runtime facade for DDNS record persistence.

  The configured backend is responsible for storing generic DDNS record
  definitions and exposing them to the rest of the application.
  """

  @type record :: %{required(String.t()) => any()}

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback list_records(keyword()) :: [record()]
  @callback export_snapshot(keyword()) :: map()
  @callback status(keyword()) :: map() | {:error, term()}
  @callback write_snapshot(String.t(), keyword()) :: :ok | {:error, term()}
  @callback reload(keyword()) :: :ok | {:error, term()}
  @callback replace_records([record()]) :: :ok | {:error, term()}
  @callback persist(keyword()) :: :ok | {:error, term()}

  @default_module Defdo.DDNS.RecordStores.FileEtsStore

  @doc """
  Returns the configured backend module.
  """
  @spec backend_module() :: module()
  def backend_module do
    config() |> Keyword.get(:module, @default_module)
  end

  @doc """
  Returns the backend start options.

  These include the generic record-store flags plus any adapter-specific
  options configured under `:options`.
  """
  @spec start_options() :: keyword()
  def start_options do
    adapter_options() ++ generic_options()
  end

  @doc """
  Returns the backend child spec tuple for the supervisor.
  """
  @spec child_spec() :: {module(), keyword()}
  def child_spec do
    {backend_module(), start_options()}
  end

  @doc """
  Returns the current records from the configured backend.
  """
  @spec records() :: [record()]
  def records do
    list_records()
  end

  @doc """
  Returns the current records from the configured backend.
  """
  @spec list_records(keyword()) :: [record()]
  def list_records(opts \\ []) when is_list(opts) do
    backend_module().list_records(opts)
  end

  @doc """
  Returns the current snapshot from the configured backend.
  """
  @spec export_snapshot(keyword()) :: map()
  def export_snapshot(opts \\ []) when is_list(opts) do
    backend_module().export_snapshot(opts)
  end

  @doc """
  Returns the current snapshot from the configured backend.
  """
  @spec snapshot() :: map()
  def snapshot do
    export_snapshot()
  end

  @doc """
  Returns safe runtime diagnostics from the configured backend.
  """
  @spec status(keyword()) :: map() | {:error, term()}
  def status(opts \\ []) when is_list(opts) do
    case backend_module().status(opts) do
      {:error, reason} ->
        {:error, reason}

      backend_status when is_map(backend_status) ->
        Map.merge(backend_status, diagnostic_context())
    end
  end

  @doc """
  Alias for `status/1`.
  """
  @spec diagnostics(keyword()) :: map() | {:error, term()}
  def diagnostics(opts \\ []) when is_list(opts) do
    status(opts)
  end

  @doc """
  Reloads the configured backend from its current bootstrap sources.
  """
  @spec reload(keyword()) :: :ok | {:error, term()}
  def reload(opts \\ []) when is_list(opts) do
    backend_module().reload(opts)
  end

  @doc """
  Replaces the configured backend records with a new list.
  """
  @spec replace_records([record()]) :: :ok | {:error, term()}
  def replace_records(records) when is_list(records) do
    backend_module().replace_records(records)
  end

  @doc """
  Persists the configured backend snapshot to disk if supported.
  """
  @spec persist(keyword()) :: :ok | {:error, term()}
  def persist(opts \\ []) when is_list(opts) do
    backend_module().persist(opts)
  end

  @doc """
  Writes the current backend snapshot to an explicit path.
  """
  @spec write_snapshot(String.t(), keyword()) :: :ok | {:error, term()}
  def write_snapshot(path, opts \\ []) when is_binary(path) and is_list(opts) do
    backend_module().write_snapshot(path, opts)
  end

  defp config do
    Application.get_env(:defdo_ddns, __MODULE__, [])
  end

  defp adapter_options do
    Keyword.get(config(), :options, []) |> List.wrap()
  end

  defp generic_options do
    [
      runtime_snapshot_path: runtime_snapshot_path(),
      init_file_path: init_file_path(),
      allow_empty_records: allow_empty_records(),
      persist_runtime_changes: persist_runtime_changes()
    ]
  end

  defp diagnostic_context do
    [
      backend: backend_module(),
      snapshot_path: runtime_snapshot_path(),
      init_path: init_file_path(),
      allow_empty_records?: allow_empty_records(),
      persist_runtime_records?: persist_runtime_changes()
    ]
    |> Enum.into(%{})
  end

  defp runtime_snapshot_path do
    Keyword.get(config(), :runtime_snapshot_path)
  end

  defp init_file_path do
    Keyword.get(config(), :init_file_path)
  end

  defp allow_empty_records do
    Keyword.get(config(), :allow_empty_records, false)
  end

  defp persist_runtime_changes do
    Keyword.get(config(), :persist_runtime_changes, false)
  end
end
