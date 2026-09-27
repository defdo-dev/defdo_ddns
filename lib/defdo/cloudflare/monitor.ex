defmodule Defdo.Cloudflare.Monitor do
  @moduledoc """
  Keep watching the ip
  """
  require Logger
  import Defdo.Cloudflare.DDNS
  use GenServer

  alias Defdo.DDNS.Intent

  # Last-cycle status lives in ETS owned by this process: a GenServer call
  # would wait behind a running cycle, and :persistent_term updates trigger a
  # global GC.
  @status_table :defdo_ddns_monitor_status

  defmodule State do
    @moduledoc false
    defstruct refetch_every: nil
  end

  # server
  @impl true
  def init(%State{} = state) do
    :ets.new(@status_table, [:set, :protected, :named_table, read_concurrency: true])

    :ets.insert(
      @status_table,
      {:status,
       %{
         "outcome" => "starting",
         "consecutive_failures" => 0,
         "last_success_at" => nil,
         "refetch_every_ms" => state.refetch_every
       }}
    )

    {:ok, state, {:continue, :start_monitor}}
  end

  @impl true
  def handle_continue(:start_monitor, state) do
    run_cycle(state)
    Process.send_after(self(), :keep_monitoring, state.refetch_every)

    {:noreply, state}
  end

  @impl true
  def handle_call(:checkup, _from, state) do
    {:reply, run_cycle(state), state}
  end

  @impl true
  def handle_info(:keep_monitoring, state) do
    run_cycle(state)
    Process.send_after(self(), :keep_monitoring, state.refetch_every)

    {:noreply, state}
  end

  # client
  def start_link(state \\ []) do
    refetch_every = Keyword.get(state, :refetch_every, :timer.minutes(5))
    GenServer.start_link(__MODULE__, %State{refetch_every: refetch_every}, name: __MODULE__)
  end

  @doc """
  Run a cycle through the monitor process and return its lines. A cycle can
  take longer than `GenServer.call/2`'s 5 s default when Cloudflare is slow.
  """
  @spec checkup(timeout()) :: list()
  def checkup(timeout \\ :timer.minutes(2)) do
    GenServer.call(__MODULE__, :checkup, timeout)
  end

  @doc "Run one cycle in the caller, without the monitor process. Records no status."
  @spec checkup_once() :: list()
  def checkup_once do
    {_outcome, lines, _domains} = execute_monitor()
    lines
  end

  @doc """
  What the last cycle did. Reads ETS, so it answers immediately even while a
  cycle is running. `{:error, :not_running}` when the monitor is not started.

  Carries no hostnames, addresses or tokens.
  """
  @spec status() :: {:ok, map()} | {:error, :not_running}
  def status do
    case :ets.whereis(@status_table) do
      :undefined ->
        {:error, :not_running}

      _tid ->
        case :ets.lookup(@status_table, :status) do
          [{:status, status}] -> {:ok, status}
          [] -> {:error, :not_running}
        end
    end
  end

  defp run_cycle(state) do
    started_at = DateTime.utc_now()
    started_mono = System.monotonic_time(:millisecond)
    {:ok, previous} = status()

    {outcome, lines, domains} =
      :telemetry.span([:defdo_ddns, :cycle], %{}, fn ->
        {outcome, lines, domains} = execute_monitor()
        result = {outcome, lines, domains}

        {result,
         %{
           outcome: outcome,
           domains: domains,
           consecutive_failures: next_failures(outcome, previous)
         }}
      end)

    finished_at = DateTime.utc_now() |> DateTime.to_iso8601()
    failed? = outcome == "failed"

    :ets.insert(
      @status_table,
      {:status,
       %{
         "outcome" => outcome,
         "started_at" => DateTime.to_iso8601(started_at),
         "finished_at" => finished_at,
         "duration_ms" => System.monotonic_time(:millisecond) - started_mono,
         "domains" => domains,
         "consecutive_failures" => next_failures(outcome, previous),
         "last_success_at" => if(failed?, do: previous["last_success_at"], else: finished_at),
         "refetch_every_ms" => state.refetch_every
       }}
    )

    lines
  end

  defp next_failures("failed", previous), do: previous["consecutive_failures"] + 1
  defp next_failures(_outcome, _previous), do: 0

  # Returns {cycle_outcome, lines, domains_processed}. `lines` is the public
  # checkup shape: one list of messages per domain, or a single error message.
  defp execute_monitor do
    Logger.info("Executing checkup...")

    case Intent.load() do
      {:ok, intent} ->
        results = intent |> Intent.domains() |> Enum.map(&safe_process(&1, intent))

        {cycle_outcome(Enum.map(results, &elem(&1, 0))), Enum.map(results, &elem(&1, 1)),
         length(results)}

      {:error, reason} ->
        message = "Error - desired state unavailable, checkup skipped: #{inspect(reason)}"
        Logger.error(message)
        {"failed", [message], 0}
    end
  rescue
    error ->
      # Second line of defence. A checkup must never take the monitor down: the
      # supervisor would restart it straight into the same failing call and, after
      # the restart intensity is exhausted, shut the whole application down. A
      # failed checkup is logged and retried on the next tick instead.
      message = "Error - checkup aborted: #{Exception.message(error)}"
      Logger.error(message)
      {"failed", [message], 0}
  end

  defp cycle_outcome([]), do: "ok"

  defp cycle_outcome(outcomes) do
    cond do
      Enum.all?(outcomes, &(&1 == :failed)) -> "failed"
      Enum.all?(outcomes, &(&1 == :ok)) -> "ok"
      true -> "degraded"
    end
  end

  defp safe_process(domain, intent) do
    case process(domain, intent) do
      {:failed, lines} -> {:failed, lines}
      {:done, lines} -> {domain_outcome(lines), lines}
    end
  rescue
    error ->
      message = "Error - checkup failed for domain=#{domain}: #{Exception.message(error)}"
      Logger.error(message)
      {:failed, [message]}
  end

  defp domain_outcome(lines) do
    if Enum.any?(lines, &String.starts_with?(&1, "Error")), do: :degraded, else: :ok
  end

  defp process(domain, intent) do
    Logger.info("Processing domain: #{domain}")
    zone_id = get_zone_id(domain)

    if is_nil(zone_id) do
      message = "Error - unable to resolve Cloudflare zone id for domain=#{domain}"
      Logger.error(message)
      {:failed, [message]}
    else
      list_and_sync(domain, zone_id, intent)
    end
  end

  # One listing per zone per cycle. A failed listing fails the domain: reading
  # it as "no records" would auto-create duplicates of records that exist.
  defp list_and_sync(domain, zone_id, intent) do
    case fetch_dns_records(zone_id) do
      {:ok, live} ->
        {:done, sync_domain(domain, zone_id, intent, live)}

      {:error, reason} ->
        message =
          "Error - unable to list DNS records for domain=#{domain}; skipping this cycle (#{inspect(reason)})"

        Logger.error(message)
        {:failed, [message]}
    end
  end

  defp sync_domain(domain, zone_id, intent, live) do
    live_by_name = Enum.group_by(live, &String.downcase(&1["name"] || ""))

    a_hostnames = Intent.hostnames(intent, domain, :a)
    aaaa_hostnames = Intent.hostnames(intent, domain, :aaaa)
    a_record_name_set = MapSet.new(a_hostnames)
    aaaa_record_name_set = MapSet.new(aaaa_hostnames)

    local_ipv4 = if MapSet.size(a_record_name_set) > 0, do: get_current_ipv4()
    local_ipv6 = if MapSet.size(aaaa_record_name_set) > 0, do: get_current_ipv6()

    if MapSet.size(a_record_name_set) > 0 and is_nil(local_ipv4) do
      Logger.error("Unable to detect public IPv4 address; A records cannot be synchronized")
    end

    if MapSet.size(aaaa_record_name_set) > 0 and is_nil(local_ipv6) do
      Logger.warning(
        "Unable to detect public IPv6 address; AAAA records will be skipped for this cycle"
      )
    end

    configured_cname_records = Intent.cname_records(intent, domain)
    cname_record_names = configured_cname_records |> Enum.map(& &1["name"]) |> MapSet.new()

    monitored_names =
      (a_hostnames ++ aaaa_hostnames ++ MapSet.to_list(cname_record_names))
      |> Enum.uniq()

    ctx = %{
      zone_id: zone_id,
      ipv4: local_ipv4,
      ipv6: local_ipv6,
      a_names: a_record_name_set,
      aaaa_names: aaaa_record_name_set,
      cname_names: cname_record_names,
      auto_create: intent["auto_create_missing_records"] == true,
      proxied: intent["proxy_a_records"] == true
    }

    {online_dns_records, created} =
      Enum.reduce(monitored_names, {[], []}, fn record_name, {online, created} ->
        records = live_for(live_by_name, record_name)
        new_records = maybe_create_missing_ip_records(ctx, record_name, records)
        {online ++ records ++ new_records, created ++ new_records}
      end)

    ip_result =
      online_dns_records
      |> Enum.filter(&(&1["type"] in ~w(A AAAA)))
      |> input_for_update_dns_records(
        %{"A" => local_ipv4, "AAAA" => local_ipv6},
        Intent.proxy_opts(intent)
      )
      |> Enum.map(&apply_ip_update(zone_id, &1))

    cname_result = sync_cname_records(zone_id, configured_cname_records, live_by_name)
    result = ip_result ++ cname_result
    wrote? = result != [] or created != []

    # Re-read after writes to evaluate final state; nothing changed otherwise.
    monitored = MapSet.new(monitored_names, &String.downcase/1)

    final_dns_records =
      domain
      |> final_records(zone_id, live, wrote?)
      |> Enum.filter(&MapSet.member?(monitored, String.downcase(&1["name"] || "")))
      |> Enum.filter(&(&1["type"] in ~w(A AAAA CNAME)))

    finish_domain(domain, zone_id, intent, final_dns_records, result)
  end

  defp live_for(live_by_name, name), do: Map.get(live_by_name, String.downcase(name), [])

  defp final_records(_domain, _zone_id, live, false), do: live

  defp final_records(domain, zone_id, live, true) do
    case fetch_dns_records(zone_id) do
      {:ok, records} ->
        records

      {:error, _reason} ->
        Logger.warning(
          "Post-update re-read failed for domain=#{domain}; posture uses pre-update records"
        )

        live
    end
  end

  defp apply_ip_update(zone_id, input) do
    {success, result} = apply_update(zone_id, input)

    message =
      if success do
        "Success - #{result["name"]} DNS record updated (ip=#{result["content"]}, proxied=#{result["proxied"]})"
      else
        "Error - #{inspect(input)}"
      end

    if success, do: Logger.info(message), else: Logger.error(message)

    message
  end

  defp finish_domain(domain, zone_id, intent, final_dns_records, result) do
    log_advanced_certificate_warnings(domain, final_dns_records, intent["proxy_exclude"])

    ssl_mode = get_zone_ssl_mode(zone_id)
    posture = evaluate_domain_posture(final_dns_records, ssl_mode, intent["proxy_a_records"])
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

  defp create_missing_ip_records(ctx, record_name, existing_records) do
    proxied = ctx.proxied
    ttl = if proxied, do: 1, else: 300

    existing_record_types =
      existing_records
      |> Enum.map(&Map.get(&1, "type", ""))
      |> MapSet.new()

    record_types_to_create =
      []
      |> maybe_add_missing_record_type(
        "A",
        record_name,
        ctx.a_names,
        ctx.ipv4,
        existing_record_types
      )
      |> maybe_add_missing_record_type(
        "AAAA",
        record_name,
        ctx.aaaa_names,
        ctx.ipv6,
        existing_record_types
      )

    Enum.flat_map(record_types_to_create, fn {record_type, record_ip} ->
      Logger.info("Creating missing DNS record: #{record_type} #{record_name}")

      record_data = %{
        "type" => record_type,
        "name" => record_name,
        "content" => record_ip,
        "ttl" => ttl,
        "proxied" => proxied
      }

      case create_dns_record(ctx.zone_id, record_data) do
        {true, result} ->
          Logger.info(
            "Created DNS record: #{record_type} #{record_name} with promotional comment"
          )

          [result]

        {false, _} ->
          Logger.error("Failed to create DNS record: #{record_type} #{record_name}")
          []
      end
    end)
  end

  defp maybe_add_missing_record_type(
         acc,
         record_type,
         record_name,
         monitored_names,
         detected_ip,
         existing_record_types
       ) do
    if MapSet.member?(monitored_names, record_name) and
         not MapSet.member?(existing_record_types, record_type) do
      if is_binary(detected_ip) and detected_ip != "" do
        [{record_type, detected_ip} | acc]
      else
        Logger.warning(
          "Skipping #{record_type} auto-create for #{record_name}: no detected #{record_type} public address"
        )

        acc
      end
    else
      acc
    end
  end

  defp maybe_create_missing_ip_records(ctx, record_name, records) do
    cond do
      MapSet.member?(ctx.cname_names, record_name) ->
        if Enum.empty?(records) do
          Logger.warning("DNS record '#{record_name}' not found in Cloudflare")

          Logger.info(
            "Skipping A auto-create for '#{record_name}' because it is managed as CNAME"
          )
        end

        []

      Enum.empty?(records) and ctx.auto_create ->
        Logger.warning("DNS record '#{record_name}' not found in Cloudflare")
        create_missing_ip_records(ctx, record_name, records)

      Enum.empty?(records) ->
        Logger.warning("DNS record '#{record_name}' not found in Cloudflare")
        Logger.info("Set AUTO_CREATE_DNS_RECORDS=true to auto-create missing records")
        []

      not ctx.auto_create ->
        []

      Enum.any?(records, &(&1["type"] == "CNAME")) ->
        Logger.warning(
          "Skipping A/AAAA auto-create for '#{record_name}': CNAME record already exists"
        )

        []

      true ->
        create_missing_ip_records(ctx, record_name, records)
    end
  end

  defp sync_cname_records(_zone_id, [], _live_by_name), do: []

  defp sync_cname_records(zone_id, desired_cname_records, live_by_name) do
    desired_cname_records
    |> Enum.flat_map(&sync_cname_record(zone_id, &1, live_by_name))
  end

  defp sync_cname_record(zone_id, desired_record, live_by_name) do
    record_name = desired_record["name"]
    existing_records = live_for(live_by_name, record_name)
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

  defp log_advanced_certificate_warnings(domain, records, patterns) do
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
      |> Enum.filter(&proxy_excluded?(&1, patterns))
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
