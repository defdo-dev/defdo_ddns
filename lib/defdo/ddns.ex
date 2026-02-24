defmodule Defdo.DDNS do
  @moduledoc """
  Public API for `defdo_ddns` when used as a dependency.

  This module provides one-shot and monitored checkups, plus a small
  convenience surface for common DNS operations.
  """

  alias Defdo.Cloudflare.DDNS, as: CloudflareDDNS
  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.API.DNS, as: DNSAPI

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

  defdelegate configured_domains(), to: CloudflareDDNS, as: :get_all_cloudflare_config_domains
  defdelegate records_to_monitor(domain), to: CloudflareDDNS
  defdelegate get_current_ipv4(), to: CloudflareDDNS
  defdelegate get_current_ipv6(), to: CloudflareDDNS
end
