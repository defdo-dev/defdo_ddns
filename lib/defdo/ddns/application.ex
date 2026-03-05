defmodule Defdo.DDNS.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Defdo.DDNS.API.AuthConfig

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_monitor()
      |> maybe_add_api_server()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Defdo.DDNS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_monitor(children) do
    if monitor_enabled?() do
      children ++ [{Defdo.Cloudflare.Monitor, refetch_every: monitor_refetch_every_ms()}]
    else
      Logger.info("Defdo.DDNS monitor disabled (DDNS_ENABLE_MONITOR=false)")
      children
    end
  end

  defp maybe_add_api_server(children) do
    if api_enabled?() do
      validate_api_config!()
      Logger.info("Starting Defdo.DDNS API on port #{api_port()}")

      children ++
        [
          Defdo.DDNS.API.AuthStore,
          {Bandit, plug: Defdo.DDNS.API.Router, scheme: :http, ip: {0, 0, 0, 0}, port: api_port()}
        ]
    else
      children
    end
  end

  @doc false
  def validate_api_config!(config \\ nil) do
    api_config = config || current_api_config()
    enabled? = Keyword.get(api_config, :enabled, false)
    allow_runtime_clients? = Keyword.get(api_config, :allow_runtime_clients, false)

    case AuthConfig.from_config(api_config) do
      {:ok, %{mode: _mode}} when not enabled? ->
        :ok

      {:ok, %{mode: mode}} when mode in [:token, :clients] ->
        :ok

      {:ok, %{mode: :none}} when allow_runtime_clients? ->
        :ok

      {:ok, %{mode: :none}} ->
        raise ArgumentError,
              "DDNS_API_TOKEN or DDNS_API_CLIENTS_JSON must be configured when DDNS_API_ENABLED=true"

      {:error, {:invalid_clients, reason}} ->
        raise ArgumentError, "DDNS_API_CLIENTS_JSON invalid: #{reason}"

      {:error, reason} ->
        raise ArgumentError, "DDNS API auth config invalid: #{inspect(reason)}"
    end
  end

  defp api_enabled? do
    current_api_config()
    |> Keyword.get(:enabled, false)
  end

  defp monitor_enabled? do
    Application.get_env(:defdo_ddns, :monitor_enabled, true)
  end

  defp monitor_refetch_every_ms do
    Application.get_env(:defdo_ddns, :monitor_refetch_every_ms, :timer.minutes(5))
  end

  defp api_port do
    current_api_config()
    |> Keyword.get(:port, 4050)
  end

  defp current_api_config do
    Application.get_env(:defdo_ddns, Defdo.DDNS.API, [])
  end
end
