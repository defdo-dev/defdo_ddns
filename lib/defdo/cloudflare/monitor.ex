defmodule Defdo.Cloudflare.Monitor do
  @moduledoc """
  Keep watching the ip
  """
  require Logger
  import Defdo.Cloudflare.DDNS
  use GenServer

  defmodule State do
    @moduledoc false
    defstruct refetch_every: nil
  end

  # server
  @impl true
  def init(%State{} = state) do
    {:ok, state, {:continue, :start_monitor}}
  end

  @impl true
  def handle_continue(:start_monitor, state) do
    execute_monitor()
    Process.send_after(self(), :keep_monitoring, state.refetch_every)

    {:noreply, state}
  end

  @impl true
  def handle_call(:checkup, _from, state) do
    result = execute_monitor()

    {:reply, result, state}
  end

  @impl true
  def handle_info(:keep_monitoring, state) do
    execute_monitor()
    Process.send_after(self(), :keep_monitoring, state.refetch_every)

    {:noreply, state}
  end

  # client
  def start_link(state \\ []) do
    refetch_every = Keyword.get(state, :refetch_every, :timer.minutes(5))
    GenServer.start_link(__MODULE__, %State{refetch_every: refetch_every}, name: __MODULE__)
  end

  def checkup do
    GenServer.call(__MODULE__, :checkup)
  end

  defp execute_monitor do
    Logger.info("🏪 Executing the checkup...", ansi_color: :magenta)
    get_cloudflare_config_domains()
    |> Enum.map(&process/1)
  end

  defp process(domain) do
    Logger.info("🏪 #{domain}", ansi_color: :blue)
    local_ip = get_current_ip()
    zone_id = get_zone_id(domain)

    # obtained by Application config
    # retrieves the subdomains to be monitored
    dns_records_to_monitor =
      domain
      |> records_to_monitor()
      |> Enum.join(",")

    # records from cloudflare currently focus on A records or AAAA.
    online_dns_records =
      zone_id
      |> list_dns_records(name: dns_records_to_monitor)
      |> Enum.filter(& &1["type"] in ~w(A AAAA))

    result =
      online_dns_records
      |> input_for_update_dns_records(local_ip)
      |> Enum.map(fn input ->
        {success, result} = apply_update(zone_id, input)

        {message, color} =
          if success do
            {"✅ Success - #{result["modified_on"]} new ip updated!", ansi_color: :green}
          else
            {"❌ error - #{inspect(input)}", ansi_color: :red}
          end

        Logger.info(message, color)

        message
      end)

    result =
      if result == [] do
        message = "💤 Nothing to do"
        Logger.info(message, ansi_color: :blue)

        [message]
      else
        result
      end

    Logger.info("🏪 checkup completed!", ansi_color: :magenta)

    result
  end
end
