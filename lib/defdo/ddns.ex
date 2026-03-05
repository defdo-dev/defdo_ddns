defmodule Defdo.DDNS do
  @moduledoc """
  Public API for `defdo_ddns` when used as a dependency.

  This module provides one-shot and monitored checkups, plus a small
  convenience surface for common DNS operations.
  """

  alias Defdo.Cloudflare.DDNS, as: CloudflareDDNS
  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.API.AuthStore
  alias Defdo.DDNS.API.DNS, as: DNSAPI

  @redacted_token "[REDACTED]"

  @doc """
  Runs a checkup through the monitor process if it is running.
  Falls back to a one-shot checkup when monitor is disabled.
  """
  @spec checkup() :: list()
  def checkup do
    if monitor_running?() do
      Monitor.checkup()
    else
      checkup_once()
    end
  end

  @doc """
  Runs a one-shot checkup without requiring the monitor process.
  """
  @spec checkup_once() :: list()
  def checkup_once do
    Monitor.checkup_once()
  end

  @doc """
  Returns whether monitor startup is enabled in app config.
  """
  @spec monitor_enabled?() :: boolean()
  def monitor_enabled? do
    Application.get_env(:defdo_ddns, :monitor_enabled, true)
  end

  @doc """
  Returns whether the monitor process is currently running.
  """
  @spec monitor_running?() :: boolean()
  def monitor_running? do
    Process.whereis(Monitor) != nil
  end

  @doc """
  Starts the monitor process manually.
  """
  @spec start_monitor(keyword()) :: GenServer.on_start()
  def start_monitor(opts \\ []) do
    Monitor.start_link(opts)
  end

  @doc """
  Stops the monitor process if it is currently running.
  """
  @spec stop_monitor(timeout()) :: :ok
  def stop_monitor(timeout \\ 5_000) do
    case Process.whereis(Monitor) do
      nil ->
        :ok

      _pid ->
        GenServer.stop(Monitor, :normal, timeout)
    end
  end

  @doc """
  Upserts a managed CNAME record using the internal DNS API logic.
  """
  @spec upsert_free_domain(map()) :: {:ok, map()} | {:error, term()}
  def upsert_free_domain(params) do
    DNSAPI.upsert_free_domain(params)
  end

  @doc """
  Replaces API client credentials in memory for multi-tenant-light auth mode.

  Expected format:
  [
    %{
      "id" => "client-id",
      "token" => "secret-token",
      "allowed_base_domains" => ["example.com"]
    }
  ]
  """
  @spec set_api_clients(list()) :: :ok | {:error, term()}
  def set_api_clients(clients) when is_list(clients) do
    AuthStore.replace_clients(clients)
  end

  @doc """
  Clears API client credentials from in-memory auth store.
  """
  @spec clear_api_clients() :: :ok | {:error, term()}
  def clear_api_clients do
    AuthStore.clear_clients()
  end

  @doc """
  Returns API client credentials currently loaded in memory.

  By default tokens are redacted. Use `api_clients(redact: false)` only for trusted,
  local debugging contexts.
  """
  @spec api_clients(keyword()) :: %{optional(String.t()) => map()}
  def api_clients(opts \\ []) do
    clients = AuthStore.get_clients()

    if Keyword.get(opts, :redact, true) do
      redact_clients(clients)
    else
      clients
    end
  end

  defdelegate configured_domains(), to: CloudflareDDNS, as: :get_all_cloudflare_config_domains
  defdelegate records_to_monitor(domain), to: CloudflareDDNS
  defdelegate get_current_ipv4(), to: CloudflareDDNS
  defdelegate get_current_ipv6(), to: CloudflareDDNS

  defp redact_clients(clients) when is_map(clients) do
    Map.new(clients, fn {client_id, client} ->
      redacted =
        client
        |> maybe_redact_key(:token)
        |> maybe_redact_key("token")

      {client_id, redacted}
    end)
  end

  defp maybe_redact_key(map, key) do
    if Map.has_key?(map, key) do
      Map.put(map, key, @redacted_token)
    else
      map
    end
  end
end
