defmodule Defdo.Cloudflare.DDNS do
  @moduledoc """
  We fetch the current domain ip in order to set your ip on cloudflare
  """
  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @zone_endpoint @base_url <> "/zones"

  @doc """
  Get the current ip for the running service.

  Keep in mind that you use it to get the current ip and most probably is your pc/router at your home lab.

      iex> Defdo.Cloudflare.DDNS.get_current_ip()
  """
  @spec get_current_ip :: String.t()
  def get_current_ip do
    key = "ip"

    {^key, current_ip} =
      "https://www.cloudflare.com/cdn-cgi/trace"
      |> Req.get()
      |> parse_cl_trace(key)

    current_ip
  end

  @doc """
  Retrieve the zone id for specific domain

      iex> Defdo.Cloudflare.DDNS.get_zone_id("defdo.de")
  """
  @spec get_zone_id(bitstring) :: String.t() | nil
  def get_zone_id(domain) when is_bitstring(domain) do
    body_response =
      Req.get!(
        @zone_endpoint,
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        params: [name: domain]
      ).body

    if Map.has_key?(body_response, "result") && not is_nil(body_response["result"]) do
      [zone | _] = body_response["result"]
      zone["id"]
    else
      errors = body_response["errors"]
      Logger.error("Cloudflare API error: #{inspect(errors)}")
      nil
    end
  end

  @doc """
  Get the List of DNS records

  use the params to filter the result and get only which are interested

  Note: As of 2025-02-21, Cloudflare deprecated comma-separated name filtering.
  Use separate API calls for multiple DNS records.

      iex> Defdo.Cloudflare.DDNS.list_dns_records(zone_id, [name: "defdo.de"])
      iex> Defdo.Cloudflare.DDNS.list_dns_records(zone_id, [name: "h.defdo.de"])
  """
  @spec list_dns_records(String.t(), list()) :: list()
  def list_dns_records(zone_id, params \\ []) do
    body_response =
      Req.get!(
        "#{@zone_endpoint}/#{zone_id}/dns_records",
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        params: params
      ).body

    if Map.has_key?(body_response, "result") && not is_nil(body_response["result"]) do
      body_response["result"]
    else
      errors = body_response["errors"]
      Logger.error("Cloudflare API error: #{inspect(errors)}")
      []
    end
  end

  @doc """
  Applies to cloudflare the record update.
  """
  @spec apply_update(String.t(), {String.t(), String.t()}) :: tuple()
  def apply_update(zone_id, {record_id, body}) when is_bitstring(body) do
    body_response =
      Req.put!(
        "#{@zone_endpoint}/#{zone_id}/dns_records/#{record_id}",
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        body: body
      ).body

    if body_response["success"] == true and Map.has_key?(body_response, "result") and
         not is_nil(body_response["result"]) do
      {true, body_response["result"]}
    else
      errors = body_response["errors"]
      Logger.error("Cloudflare API error: #{inspect(errors)}")
      {body_response["success"] == true, nil}
    end
  end

  @doc """
  Creates a new DNS record in Cloudflare with a promotional comment.
  """
  @spec create_dns_record(String.t(), map()) :: tuple()
  def create_dns_record(zone_id, record_data) do
    # Add promotional comment to the record
    app_name = Application.get_application(__MODULE__) |> to_string()

    comment =
      "Created using #{app_name}, want to contribute? Visit https://shop.defdo.dev and subscribe (only MX)"

    record_with_comment = Map.put(record_data, "comment", comment)

    body_response =
      Req.post!(
        "#{@zone_endpoint}/#{zone_id}/dns_records",
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        body: Jason.encode!(record_with_comment)
      ).body

    if body_response["success"] == true and Map.has_key?(body_response, "result") and
         not is_nil(body_response["result"]) do
      {true, body_response["result"]}
    else
      errors = body_response["errors"]
      Logger.error("Cloudflare API error: #{inspect(errors)}")
      {body_response["success"] == true, nil}
    end
  end

  @doc """
  Check the records which must be updated

  We filter the updatable records and transform them to give the input to apply_update/2

  In fact this give the second parameter to execute the update.
  """
  @spec input_for_update_dns_records(list(), String.t()) :: list()
  def input_for_update_dns_records(records, local_ip) do
    records
    |> Enum.group_by(&{&1["name"], &1["type"]})
    |> Enum.flat_map(fn {{name, type}, grouped_records} ->
      {updates, skipped} = plan_updates_for_group(grouped_records, local_ip)

      if skipped != [] do
        skipped_ids = skipped_record_ids(skipped)

        Logger.warning(
          "Duplicate DNS records detected for #{type} #{name}. Skipping #{length(skipped)} record(s) (ids: #{skipped_ids}). Remove duplicates in Cloudflare."
        )
      end

      updates
    end)
  end

  @doc """
  Resolve if DNS record should be proxied.

  By default, keep current Cloudflare proxied value.
  Set `CLOUDFLARE_PROXY_A_RECORDS=true` to force proxied mode.
  """
  @spec resolve_proxied_value(map()) :: boolean()
  def resolve_proxied_value(record) do
    case get_cloudflare_key(:proxy_a_records, false) do
      true -> true
      false -> Map.get(record, "proxied", false)
    end
  end

  @doc """
  Resolve record TTL.

  Cloudflare proxied records should use Auto TTL (`1`).
  """
  @spec resolve_ttl(map(), boolean()) :: integer()
  def resolve_ttl(record, desired_proxied) do
    if desired_proxied do
      1
    else
      Map.get(record, "ttl", 300)
    end
  end

  @doc """
  Retrieve the records to be used to monitor for a specific domain.
  """
  def records_to_monitor(domain) do
    [domain | get_subdomains_for_domain(domain)]
  end

  @doc """
  Get subdomains specifically configured for a domain.
  """
  def get_subdomains_for_domain(domain) do
    domain_mappings = get_cloudflare_key(:domain_mappings, %{})

    case Map.get(domain_mappings, domain) do
      nil ->
        Logger.warning("No subdomains configured for domain: #{domain}")
        []

      subdomains when is_list(subdomains) ->
        subdomains
        |> Enum.map(&normalize_subdomain(&1, domain))
        |> Enum.uniq()
    end
  end

  @doc """
  Get all configured domains from domain mappings.
  """
  def get_cloudflare_config_domains do
    domain_mappings = get_cloudflare_key(:domain_mappings, %{})
    Map.keys(domain_mappings)
  end

  @doc """
  Get the key from the the Application.
  """
  @spec get_cloudflare_key(atom(), any()) :: any()
  def get_cloudflare_key(key, default \\ "")

  def get_cloudflare_key(key, default) do
    Application.get_env(:defdo_ddns, Cloudflare)
    |> Keyword.get(key, default)
  end

  @doc """
  By parsing the Application config retrieves a list of domains defined.
  """
  def get_cloudflare_config_subdomains(subdomain \\ get_cloudflare_key(:subdomains))

  def get_cloudflare_config_subdomains(subdomain) when subdomain not in [nil, ""] do
    parse_string_config(subdomain)
    # |> Enum.reject(&(&1 == ""))
  end

  def get_cloudflare_config_subdomains(_), do: []

  defp parse_string_config(string) do
    case String.split(string, ~r/(,|\s)/, trim: true) do
      [] ->
        Logger.warning("Cannot parse config: values must be separated by comma or space")

        {:error, :missing_config}

      list when is_list(list) ->
        list
    end
  end

  defp parse_cl_trace({:ok, %Req.Response{body: body, status: 200}}, key) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn str ->
      [key, value] = String.split(str, "=")
      {key, value}
    end)
    |> Enum.filter(fn {k, _value} -> k == key end)
    |> List.first()
  end

  defp parse_cl_trace(_, "ip") do
    {"ip", "127.0.0.1"}
  end

  defp plan_updates_for_group(records, local_ip) do
    planned_updates = Enum.map(records, &build_update_plan(&1, local_ip))
    needs_update = Enum.filter(planned_updates, & &1.needs_update?)
    already_desired = Enum.reject(planned_updates, & &1.needs_update?)

    cond do
      needs_update == [] ->
        {[], []}

      already_desired != [] ->
        {[], needs_update}

      true ->
        [first | skipped] = needs_update
        {[build_update_entry(first)], skipped}
    end
  end

  defp build_update_plan(record, local_ip) do
    desired_proxied = resolve_proxied_value(record)
    desired_ttl = resolve_ttl(record, desired_proxied)
    current_ip = Map.get(record, "content")
    current_proxied = Map.get(record, "proxied", false)
    current_ttl = Map.get(record, "ttl")

    %{
      record: record,
      desired_ip: local_ip,
      desired_proxied: desired_proxied,
      desired_ttl: desired_ttl,
      needs_update?:
        current_ip != local_ip or current_proxied != desired_proxied or current_ttl != desired_ttl
    }
  end

  defp build_update_entry(%{
         record: record,
         desired_ip: desired_ip,
         desired_proxied: desired_proxied,
         desired_ttl: desired_ttl
       }) do
    body =
      %{
        "type" => record["type"],
        "name" => record["name"],
        "ttl" => desired_ttl,
        "proxied" => desired_proxied,
        "content" => desired_ip
      }
      |> Jason.encode!()

    {record["id"], body}
  end

  defp skipped_record_ids(skipped_records) do
    skipped_records
    |> Enum.map(&Map.get(&1.record, "id"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "unknown"
      ids -> Enum.join(ids, ", ")
    end
  end

  defp normalize_subdomain(subdomain, domain) when is_binary(subdomain) do
    clean_subdomain = String.trim(subdomain)
    wildcard_target = String.trim_leading(clean_subdomain, "*.")

    cond do
      # Relative wildcard, e.g. "*.idp-dev" => "*.idp-dev.example.com"
      String.starts_with?(clean_subdomain, "*.") and not String.contains?(wildcard_target, ".") ->
        "#{clean_subdomain}.#{domain}"

      # Fully-qualified domain (or wildcard FQDN), keep as is
      String.contains?(clean_subdomain, ".") ->
        clean_subdomain

      # Relative subdomain, append current domain
      true ->
        "#{clean_subdomain}.#{domain}"
    end
  end
end
