defmodule Defdo.DDNS.API.AuthStore do
  @moduledoc false

  use GenServer

  alias Defdo.DDNS.API.AuthConfig

  @table :defdo_ddns_api_clients

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec replace_clients(term()) :: :ok | {:error, term()}
  def replace_clients(clients_payload) do
    with {:ok, normalized} <- AuthConfig.parse_clients(clients_payload),
         {:ok, _} <- call_store({:replace_clients, normalized}) do
      :ok
    end
  end

  @spec clear_clients() :: :ok | {:error, term()}
  def clear_clients do
    with {:ok, _} <- call_store(:clear_clients) do
      :ok
    end
  end

  @spec get_clients() :: %{optional(String.t()) => map()}
  def get_clients do
    if :ets.whereis(@table) == :undefined do
      case AuthConfig.from_app_env() do
        {:ok, %{clients: clients}} -> clients
        _ -> %{}
      end
    else
      @table
      |> :ets.tab2list()
      |> Map.new()
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    seed_clients_from_config()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:replace_clients, clients}, _from, state) do
    replace_table(clients)
    {:reply, {:ok, :updated}, state}
  end

  def handle_call(:clear_clients, _from, state) do
    replace_table(%{})
    {:reply, {:ok, :cleared}, state}
  end

  defp seed_clients_from_config do
    case AuthConfig.from_app_env() do
      {:ok, %{clients: clients}} -> replace_table(clients)
      {:error, _reason} -> :ok
    end
  end

  defp replace_table(clients_map) do
    :ets.delete_all_objects(@table)

    Enum.each(clients_map, fn {client_id, client} ->
      :ets.insert(@table, {client_id, client})
    end)
  end

  defp call_store(message) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, message)
    else
      {:error, :auth_store_not_running}
    end
  end
end
