defmodule Defdo.DDNS.RecordStores.FileEtsStore do
  @moduledoc """
  Default DDNS record store backed by ETS and an optional snapshot file.
  """

  use GenServer

  require Logger

  alias Defdo.DDNS.RecordStore
  alias Defdo.DDNS.RecordSnapshot

  @behaviour Defdo.DDNS.RecordStore
  @table __MODULE__

  defmodule State do
    @moduledoc false
    defstruct records: [],
              snapshot: %{},
              bootstrap_source: nil,
              last_loaded_at: nil,
              last_persisted_at: nil,
              last_error: nil,
              runtime_snapshot_path: nil,
              init_file_path: nil,
              allow_empty_records: false,
              persist_runtime_changes: false
  end

  @impl true
  def start_link(opts \\ []) do
    opts = Keyword.merge(default_start_options(), opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) when is_list(opts) do
    case bootstrap_records(opts) do
      {:ok, state} ->
        table = ensure_table()
        write_state(table, state)

        case maybe_persist_bootstrap(state) do
          {:ok, persisted_state} ->
            write_state(table, persisted_state)
            {:ok, persisted_state}

          {:error, reason} ->
            error_state = put_last_error(state, reason)
            write_state(table, error_state)
            {:stop, reason}
        end

      {:error, reason} ->
        Logger.error(format_bootstrap_error(reason))
        {:stop, reason}
    end
  end

  @impl true
  def list_records(_opts \\ []) do
    case read_table(:records) do
      records when is_list(records) -> records
      _ -> []
    end
  end

  def records do
    list_records()
  end

  @impl true
  def export_snapshot(_opts \\ []) do
    case read_table(:snapshot) do
      snapshot when is_map(snapshot) -> snapshot
      _ -> empty_snapshot([])
    end
  end

  def snapshot do
    export_snapshot()
  end

  @impl true
  def status(opts \\ []) when is_list(opts) do
    call_server({:status, opts})
  end

  @impl true
  def reload(opts \\ []) when is_list(opts) do
    call_server({:reload, opts})
  end

  @impl true
  def replace_records(records) when is_list(records) do
    call_server({:replace_records, records})
  end

  @impl true
  def persist(opts \\ []) when is_list(opts) do
    call_server({:persist, opts})
  end

  @impl true
  def write_snapshot(path, opts \\ []) when is_binary(path) and is_list(opts) do
    call_server({:write_snapshot, path, opts})
  end

  @impl true
  def handle_call({:reload, opts}, _from, state) do
    case bootstrap_records(Keyword.merge(RecordStore.start_options(), opts)) do
      {:ok, new_state} ->
        write_state(ensure_table(), new_state)

        case maybe_persist_bootstrap(new_state) do
          {:ok, persisted_state} ->
            write_state(ensure_table(), persisted_state)
            {:reply, :ok, persisted_state}

          {:error, reason} ->
            error_state = put_last_error(new_state, reason)
            write_state(ensure_table(), error_state)
            {:reply, {:error, reason}, error_state}
        end

      {:error, reason} ->
        Logger.error(format_bootstrap_error(reason))
        error_state = put_last_error(state, reason)
        write_state(ensure_table(), error_state)
        {:reply, {:error, reason}, error_state}
    end
  end

  @impl true
  def handle_call({:replace_records, records}, _from, state) do
    case RecordSnapshot.new(records, updated_at: current_timestamp()) do
      {:ok, snapshot} ->
        new_state = put_snapshot(state, snapshot, :runtime_update)
        write_state(ensure_table(), new_state)

        case maybe_persist_runtime(new_state) do
          {:ok, persisted_state} ->
            write_state(ensure_table(), persisted_state)
            {:reply, :ok, persisted_state}

          {:error, reason} ->
            error_state = put_last_error(new_state, reason)
            write_state(ensure_table(), error_state)
            {:reply, {:error, reason}, error_state}
        end

      {:error, reason} ->
        error_state = put_last_error(state, reason)
        write_state(ensure_table(), error_state)
        {:reply, {:error, reason}, error_state}
    end
  end

  @impl true
  def handle_call({:persist, _opts}, _from, state) do
    case persist_snapshot(state) do
      {:ok, persisted_state} ->
        write_state(ensure_table(), persisted_state)
        {:reply, :ok, persisted_state}

      {:error, reason} ->
        error_state = put_last_error(state, reason)
        write_state(ensure_table(), error_state)
        {:reply, {:error, reason}, error_state}
    end
  end

  @impl true
  def handle_call({:write_snapshot, path, _opts}, _from, state) do
    case write_snapshot_file(path, state.snapshot) do
      :ok ->
        Logger.info("Wrote DDNS record snapshot to #{path}")
        cleared_state = clear_last_error(state)
        write_state(ensure_table(), cleared_state)
        {:reply, :ok, cleared_state}

      {:error, reason} ->
        Logger.error("Failed to write DDNS record snapshot to #{path}: #{inspect(reason)}")
        error_state = put_last_error(state, reason)
        write_state(ensure_table(), error_state)
        {:reply, {:error, reason}, error_state}
    end
  end

  @impl true
  def handle_call({:status, _opts}, _from, state) do
    {:reply, status_map(state), state}
  end

  defp default_start_options do
    RecordStore.start_options()
  end

  defp bootstrap_records(opts) do
    allow_empty_records? = Keyword.get(opts, :allow_empty_records, false)
    runtime_snapshot_path = clean_path(Keyword.get(opts, :runtime_snapshot_path))
    init_file_path = clean_path(Keyword.get(opts, :init_file_path))
    loaded_at = current_timestamp()

    with {:ok, source, snapshot} <-
           load_bootstrap_snapshot(runtime_snapshot_path, init_file_path, allow_empty_records?) do
      records = Map.get(snapshot, "records", [])

      {:ok,
       %State{
         records: records,
         snapshot: snapshot,
         bootstrap_source: source,
         last_loaded_at: loaded_at,
         last_persisted_at: nil,
         last_error: nil,
         runtime_snapshot_path: runtime_snapshot_path,
         init_file_path: init_file_path,
         allow_empty_records: allow_empty_records?,
         persist_runtime_changes: Keyword.get(opts, :persist_runtime_changes, false)
       }}
    end
  end

  defp load_bootstrap_snapshot(runtime_snapshot_path, init_file_path, allow_empty_records?) do
    case maybe_load_snapshot_file(runtime_snapshot_path) do
      {:loaded, source, snapshot} ->
        {:ok, source, snapshot}

      {:skip, :missing} ->
        case maybe_load_init_file(init_file_path) do
          {:loaded, source, snapshot} ->
            {:ok, source, snapshot}

          {:skip, :missing} ->
            maybe_load_legacy_env(allow_empty_records?)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_load_snapshot_file(nil), do: {:skip, :missing}

  defp maybe_load_snapshot_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case RecordSnapshot.decode(contents) do
          {:ok, snapshot} ->
            records = Map.get(snapshot, "records", [])
            log_bootstrap(:snapshot_file, records, path)

            if legacy_env_records_available?() do
              Logger.warning(
                "Ignoring deprecated CLOUDFLARE_CNAME_RECORDS_JSON because snapshot file exists at #{path}"
              )
            end

            {:loaded, :snapshot_file, snapshot}

          {:error, reason} ->
            {:error, map_snapshot_error(path, reason)}
        end

      {:error, :enoent} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, {:snapshot_read_failed, path, reason}}
    end
  end

  defp maybe_load_init_file(nil), do: {:skip, :missing}

  defp maybe_load_init_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case RecordSnapshot.decode(contents) do
          {:ok, snapshot} ->
            records = Map.get(snapshot, "records", [])
            log_bootstrap(:init_file, records, path)

            if legacy_env_records_available?() do
              Logger.warning(
                "Ignoring deprecated CLOUDFLARE_CNAME_RECORDS_JSON because init file exists at #{path}"
              )
            end

            {:loaded, :init_file, snapshot}

          {:error, reason} ->
            {:error, map_init_file_error(path, reason)}
        end

      {:error, :enoent} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, {:init_read_failed, path, reason}}
    end
  end

  defp maybe_load_legacy_env(allow_empty_records?) do
    legacy_records = legacy_env_records()

    case RecordSnapshot.from_legacy_cname_records(legacy_records, updated_at: current_timestamp()) do
      {:ok, snapshot} ->
        records = Map.get(snapshot, "records", [])

        cond do
          records != [] ->
            log_bootstrap(:legacy_env, records, nil)
            {:ok, :legacy_env, snapshot}

          allow_empty_records? ->
            log_empty_bootstrap()
            {:ok, :empty_state, snapshot}

          true ->
            {:error, :empty_state_not_allowed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_snapshot(%State{} = state, snapshot, source) when is_map(snapshot) do
    %State{
      state
      | records: Map.get(snapshot, "records", []),
        snapshot: snapshot,
        bootstrap_source: source,
        last_error: nil
    }
  end

  defp empty_snapshot(records) do
    case RecordSnapshot.new(records, updated_at: current_timestamp()) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> %{"version" => 1, "updated_at" => current_timestamp(), "records" => []}
    end
  end

  defp write_state(table, %State{} = state) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {:records, state.records})
    :ets.insert(table, {:snapshot, state.snapshot})
    :ets.insert(table, {:bootstrap_source, state.bootstrap_source})
    :ok
  end

  defp status_map(%State{} = state) do
    %{
      source: status_source(state.bootstrap_source),
      record_count: length(state.records),
      record_types: record_type_counts(state.records),
      writable?: true,
      persistent?: should_persist_runtime?(state),
      last_loaded_at: state.last_loaded_at,
      last_persisted_at: state.last_persisted_at,
      last_error: state.last_error
    }
  end

  defp status_source(:empty_state), do: :empty
  defp status_source(source), do: source

  defp record_type_counts(records) do
    Enum.reduce(records, %{}, fn record, acc ->
      case Map.get(record, "type") do
        nil -> acc
        type -> Map.update(acc, type, 1, &(&1 + 1))
      end
    end)
  end

  defp put_last_error(%State{} = state, reason) do
    %State{state | last_error: reason}
  end

  defp clear_last_error(%State{} = state) do
    %State{state | last_error: nil}
  end

  defp put_last_persisted_at(%State{} = state) do
    %State{state | last_persisted_at: current_timestamp(), last_error: nil}
  end

  defp read_table(key) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, value}] -> value
          _ -> nil
        end
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

      table ->
        table
    end
  end

  defp call_server(request) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, request)
    else
      {:error, :not_started}
    end
  end

  defp maybe_persist_bootstrap(%State{} = state) do
    if should_persist_bootstrap?(state) do
      persist_snapshot(state)
    else
      {:ok, state}
    end
  end

  defp should_persist_bootstrap?(%State{
         bootstrap_source: source,
         runtime_snapshot_path: runtime_snapshot_path,
         persist_runtime_changes: persist_runtime_changes
       }) do
    persist_runtime_changes and not is_nil(runtime_snapshot_path) and
      source in [:init_file, :legacy_env, :empty_state]
  end

  defp maybe_persist_runtime(%State{} = state) do
    if should_persist_runtime?(state) do
      persist_snapshot(state)
    else
      {:ok, state}
    end
  end

  defp should_persist_runtime?(%State{
         runtime_snapshot_path: runtime_snapshot_path,
         persist_runtime_changes: persist_runtime_changes
       }) do
    persist_runtime_changes and not is_nil(runtime_snapshot_path)
  end

  defp persist_snapshot(%State{runtime_snapshot_path: nil}) do
    {:error, :missing_runtime_snapshot_path}
  end

  defp persist_snapshot(%State{runtime_snapshot_path: path, snapshot: snapshot} = state) do
    case write_snapshot_file(path, snapshot) do
      :ok ->
        Logger.info("Persisted DDNS record snapshot to #{path}")
        {:ok, put_last_persisted_at(state)}

      {:error, reason} ->
        Logger.error("Failed to persist DDNS record snapshot to #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write_snapshot_file(path, snapshot) do
    with {:ok, encoded} <- RecordSnapshot.encode(snapshot),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      temp_path = temp_snapshot_path(path)

      case File.write(temp_path, encoded <> "\n") do
        :ok ->
          File.rename(temp_path, path)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp temp_snapshot_path(path) do
    directory = Path.dirname(path)
    filename = Path.basename(path)
    suffix = "#{filename}.#{System.unique_integer([:positive])}.tmp"
    Path.join(directory, suffix)
  end

  defp current_timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp legacy_env_records_available? do
    legacy_env_records() != []
  end

  defp legacy_env_records do
    Application.get_env(:defdo_ddns, Cloudflare, [])
    |> Keyword.get(:cname_records, [])
    |> List.wrap()
  end

  defp log_bootstrap(source, records, path) do
    types =
      records
      |> Enum.map(&Map.get(&1, "type"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    type_text =
      case types do
        [] -> "[]"
        values -> Enum.join(values, ",")
      end

    source_text =
      case source do
        :snapshot_file -> "snapshot file#{path_suffix(path)}"
        :init_file -> "init file#{path_suffix(path)}"
        :legacy_env -> "legacy CLOUDFLARE_CNAME_RECORDS_JSON (deprecated)"
        :empty_state -> "empty state"
        other -> inspect(other)
      end

    level =
      case source do
        :legacy_env -> :warning
        _ -> :info
      end

    message =
      "Loaded DDNS records from #{source_text} (count=#{length(records)}, types=#{type_text})"

    case level do
      :warning -> Logger.warning(message)
      _ -> Logger.info(message)
    end
  end

  defp log_empty_bootstrap do
    Logger.warning("Bootstrapped DDNS record store with empty state (explicitly allowed)")
  end

  defp path_suffix(nil), do: ""
  defp path_suffix(path), do: " at #{path}"

  defp format_bootstrap_error({:snapshot_read_failed, path, reason}) do
    "Failed to read DDNS snapshot file #{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:init_read_failed, path, reason}) do
    "Failed to read DDNS init file #{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:unsupported_snapshot_version, path, version}) do
    "Invalid DDNS snapshot file #{path}: unsupported version #{inspect(version)}"
  end

  defp format_bootstrap_error({:invalid_snapshot_records, path}) do
    "Invalid DDNS snapshot file #{path}: records must be a list"
  end

  defp format_bootstrap_error({:invalid_snapshot_updated_at, path}) do
    "Invalid DDNS snapshot file #{path}: updated_at must be a valid ISO8601 timestamp"
  end

  defp format_bootstrap_error({:invalid_snapshot_record, path, reason}) do
    "Invalid DDNS snapshot file #{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:invalid_snapshot, path, reason}) do
    "Invalid DDNS snapshot file #{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:invalid_init, path, reason}) do
    "Invalid DDNS init file #{path}: #{inspect(reason)}"
  end

  defp format_bootstrap_error({:empty_state_not_allowed, source, path}) do
    "DDNS record store bootstrap resolved to empty state from #{inspect(source)}#{path_suffix(path)}; set allow_empty_records: true to permit it"
  end

  defp format_bootstrap_error(:empty_state_not_allowed) do
    "DDNS record store bootstrap resolved to empty state; set allow_empty_records: true to permit it"
  end

  defp format_bootstrap_error(reason) do
    "Failed to bootstrap DDNS record store: #{inspect(reason)}"
  end

  defp clean_path(nil), do: nil

  defp clean_path(path) when is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: nil, else: trimmed
  end

  defp clean_path(_), do: nil

  defp map_snapshot_error(path, reason) do
    case reason do
      {:unsupported_snapshot_version, version} ->
        {:unsupported_snapshot_version, path, version}

      :invalid_snapshot_records ->
        {:invalid_snapshot_records, path}

      :invalid_snapshot_updated_at ->
        {:invalid_snapshot_updated_at, path}

      {:invalid_snapshot_record, nested_reason} ->
        {:invalid_snapshot_record, path, nested_reason}

      :snapshot_must_be_a_map ->
        {:invalid_snapshot, path, "expected object"}

      other ->
        {:invalid_snapshot, path, other}
    end
  end

  defp map_init_file_error(path, reason) do
    case reason do
      {:unsupported_snapshot_version, version} ->
        {:invalid_init, path, {:unsupported_snapshot_version, version}}

      :invalid_snapshot_records ->
        {:invalid_init, path, :invalid_snapshot_records}

      :invalid_snapshot_updated_at ->
        {:invalid_init, path, :invalid_snapshot_updated_at}

      {:invalid_snapshot_record, nested_reason} ->
        {:invalid_init, path, {:invalid_snapshot_record, nested_reason}}

      :snapshot_must_be_a_map ->
        {:invalid_init, path, "expected object"}

      other ->
        {:invalid_init, path, other}
    end
  end
end
