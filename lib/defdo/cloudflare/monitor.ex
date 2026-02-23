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

    if is_nil(zone_id) do
      message = "Error - unable to resolve Cloudflare zone id for domain=#{domain}"
      Logger.error(message)
      [message]
    else
      configured_cname_records = get_cname_records_for_domain(domain)
      cname_record_names = configured_cname_records |> Enum.map(& &1["name"]) |> MapSet.new()

      # obtained by Application config
      # retrieves the subdomains to be monitored
      dns_records_to_monitor =
        domain
        |> records_to_monitor()
        |> Kernel.++(MapSet.to_list(cname_record_names))
        |> Enum.uniq()

      # Note: Making separate API calls for each DNS record due to Cloudflare API deprecation
      # of comma-separated name filtering (deprecated 2025-02-21)
      online_dns_records =
        dns_records_to_monitor
        |> Enum.flat_map(fn record_name ->
          records = zone_id |> list_dns_records(name: record_name)

          if Enum.empty?(records) do
            Logger.warning("DNS record '#{record_name}' not found in Cloudflare")

            cond do
              MapSet.member?(cname_record_names, record_name) ->
                Logger.info(
                  "Skipping A auto-create for '#{record_name}' because it is managed as CNAME"
                )

                []

              get_cloudflare_key(:auto_create_missing_records) ->
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

              true ->
                Logger.info("Set AUTO_CREATE_DNS_RECORDS=true to auto-create missing records")
                []
            end
          else
            records
          end
        end)

      ip_dns_records =
        online_dns_records
        |> Enum.filter(&(&1["type"] in ~w(A AAAA)))

      ip_result =
        ip_dns_records
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

      cname_result = sync_cname_records(zone_id, configured_cname_records)
      result = ip_result ++ cname_result

      # Re-read records after updates to evaluate final state.
      final_dns_records =
        dns_records_to_monitor
        |> Enum.flat_map(fn record_name -> list_dns_records(zone_id, name: record_name) end)
        |> Enum.filter(&(&1["type"] in ~w(A AAAA CNAME)))

      log_advanced_certificate_warnings(domain, final_dns_records)

      ssl_mode = get_zone_ssl_mode(zone_id)
      expected_proxied = get_cloudflare_key(:proxy_a_records, false)
      posture = evaluate_domain_posture(final_dns_records, ssl_mode, expected_proxied)
      posture_message = log_domain_posture(domain, posture)

      result =
        if result == [] do
          message = "Nothing to do"
          Logger.info(message)

          [message, posture_message]
        else
          result ++ [posture_message]
        end

      Logger.info("Checkup completed")

      result
    end
  end

  defp sync_cname_records(_zone_id, []), do: []

  defp sync_cname_records(zone_id, desired_cname_records) do
    desired_cname_records
    |> Enum.flat_map(&sync_cname_record(zone_id, &1))
  end

  defp sync_cname_record(zone_id, desired_record) do
    record_name = desired_record["name"]
    existing_records = list_dns_records(zone_id, name: record_name)
    cname_records = Enum.filter(existing_records, &(&1["type"] == "CNAME"))
    conflicting_records = Enum.reject(existing_records, &(&1["type"] == "CNAME"))

    cond do
      conflicting_records != [] ->
        conflicting_types =
          conflicting_records
          |> Enum.map(& &1["type"])
          |> Enum.uniq()
          |> Enum.join(",")

        message =
          "Error - cannot manage CNAME #{record_name}: conflicting DNS record type(s) exist (#{conflicting_types})"

        Logger.error(message)
        [message]

      cname_records == [] ->
        case create_dns_record(zone_id, desired_record) do
          {true, result} ->
            message =
              "Success - #{result["name"]} CNAME record created (target=#{result["content"]}, proxied=#{result["proxied"]})"

            Logger.info(message)
            [message]

          {false, _} ->
            message = "Error - failed to create CNAME record: #{record_name}"
            Logger.error(message)
            [message]
        end

      true ->
        cname_records
        |> input_for_update_cname_records(desired_record)
        |> Enum.map(fn input ->
          {success, result} = apply_update(zone_id, input)

          message =
            if success do
              "Success - #{result["name"]} CNAME record updated (target=#{result["content"]}, proxied=#{result["proxied"]})"
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
    end
  end

  defp log_domain_posture(domain, posture) do
    status = posture.overall |> to_string() |> String.upcase()

    summary =
      "[HEALTH][#{status}] domain=#{domain} ssl_mode=#{posture.ssl_mode} edge_tls=#{posture.edge_tls} " <>
        "proxied=#{posture.proxied_count}/#{posture.records_total} dns_only=#{posture.dns_only_count} " <>
        "proxy_mismatch=#{posture.proxy_mismatch_count} hairpin_risk=#{posture.hairpin_risk}"

    case posture.overall do
      :green ->
        Logger.info(summary)

      :yellow ->
        Logger.warning(
          summary <> " recommendation=Use Full (strict) and proxied records for web apps"
        )

      :red ->
        Logger.error(summary <> " recommendation=Set Cloudflare SSL/TLS mode to Full (strict)")
    end

    summary
  end

  defp log_advanced_certificate_warnings(domain, records) do
    deep_hosts =
      records
      |> Enum.map(&Map.get(&1, "name"))
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&requires_advanced_certificate?(&1, domain))
      |> Enum.uniq()

    proxied_deep_hosts =
      records
      |> Enum.filter(
        &(Map.get(&1, "proxied", false) and requires_advanced_certificate?(&1["name"], domain))
      )
      |> Enum.map(& &1["name"])
      |> Enum.uniq()

    excluded_deep_hosts =
      deep_hosts
      |> Enum.filter(&proxy_excluded?/1)
      |> Enum.uniq()

    if proxied_deep_hosts != [] do
      Logger.warning(
        "[CERT][ACM] domain=#{domain} proxied_hosts=#{Enum.join(proxied_deep_hosts, ",")} " <>
          "may not be covered by Cloudflare Universal SSL and can require Advanced Certificate Manager."
      )
    end

    if excluded_deep_hosts != [] do
      Logger.warning(
        "[CERT][ACM] domain=#{domain} excluded_hosts=#{Enum.join(excluded_deep_hosts, ",")} " <>
          "matched CLOUDFLARE_PROXY_EXCLUDE; keeping DNS only helps avoid edge TLS handshake failures without Advanced Certificate Manager."
      )
    end
  end
end
