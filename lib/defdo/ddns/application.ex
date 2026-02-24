defmodule Defdo.DDNS.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

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
      Logger.info("Starting Defdo.DDNS API on port #{api_port()}")

      children ++
        [
          {Bandit, plug: Defdo.DDNS.API.Router, scheme: :http, ip: {0, 0, 0, 0}, port: api_port()}
        ]
    else
      children
    end
  end

  defp api_enabled? do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:enabled, false)
  end

  defp monitor_enabled? do
    Application.get_env(:defdo_ddns, :monitor_enabled, true)
  end

  defp monitor_refetch_every_ms do
    Application.get_env(:defdo_ddns, :monitor_refetch_every_ms, :timer.minutes(5))
  end

  defp api_port do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:port, 4050)
  end
end
