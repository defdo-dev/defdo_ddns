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
    Logger.info("Executing checkup...")

    get_cloudflare_config_domains()
    |> Enum.map(&process/1)
  end

  defp process(domain) do
    Logger.info("Processing domain: #{domain}")
    local_ip = get_current_ip()
    zone_id = get_zone_id(domain)

    # obtained by Application config
    # retrieves the subdomains to be monitored
    dns_records_to_monitor =
      domain
      |> records_to_monitor()

    # records from cloudflare currently focus on A records or AAAA.
    # Note: Making separate API calls for each DNS record due to Cloudflare API deprecation
    # of comma-separated name filtering (deprecated 2025-02-21)
    online_dns_records =
      dns_records_to_monitor
      |> Enum.flat_map(fn record_name ->
        records = zone_id |> list_dns_records(name: record_name)

        if Enum.empty?(records) do
          Logger.warning("DNS record '#{record_name}' not found in Cloudflare")

          if get_cloudflare_key(:auto_create_missing_records) do
            Logger.info("Creating missing DNS record: #{record_name}")

            proxied = get_cloudflare_key(:proxy_a_records, false)
            ttl = if proxied, do: 1, else: 300

            record_data = %{
              "type" => "A",
              "name" => record_name,
              "content" => local_ip,
              "ttl" => ttl,
              "proxied" => proxied
            }

            case create_dns_record(zone_id, record_data) do
              {true, result} ->
                Logger.info("Created DNS record: #{record_name} with promotional comment")

                [result]

              {false, _} ->
                Logger.error("Failed to create DNS record: #{record_name}")
                []
            end
          else
            Logger.info("Set AUTO_CREATE_DNS_RECORDS=true to auto-create missing records")

            []
          end
        else
          records
        end
      end)
      |> Enum.filter(&(&1["type"] in ~w(A AAAA)))

    result =
      online_dns_records
      |> input_for_update_dns_records(local_ip)
      |> Enum.map(fn input ->
        {success, result} = apply_update(zone_id, input)

        message =
          if success do
            "Success - #{result["name"]} DNS record updated (ip=#{result["content"]}, proxied=#{result["proxied"]})"
          else
            "Error - #{inspect(input)}"
          end

        if success do
          Logger.info(message)
        else
          Logger.error(message)
        end

        message
      end)

    result =
      if result == [] do
        message = "Nothing to do"
        Logger.info(message)

        [message]
      else
        result
      end

    Logger.info("Checkup completed")

    result
  end
end
