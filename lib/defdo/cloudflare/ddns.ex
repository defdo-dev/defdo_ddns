defmodule Defdo.Cloudflare.DDNS do
  @moduledoc """
  We fetch the current domain ip in order to set your ip on cloudflare
  """
  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @zone_endpoint @base_url <> "/zones"
  @ipv4_lookup_url "https://ipv4.icanhazip.com"
  @ipv6_lookup_url "https://ipv6.icanhazip.com"

  @doc """
  Backward compatible helper for public IPv4 retrieval.
  """
  @spec get_current_ip :: String.t() | nil
  def get_current_ip do
    get_current_ipv4()
  end

  @doc """
  Get current public IPv4 for the running service.
  """
  @spec get_current_ipv4 :: String.t() | nil
  def get_current_ipv4 do
    get_current_ip_family(:ipv4)
  end

  @doc """
  Get current public IPv6 for the running service.
  """
  @spec get_current_ipv6 :: String.t() | nil
  def get_current_ipv6 do
    get_current_ip_family(:ipv6)
  end

  defp get_current_ip_family(:ipv4), do: fetch_public_ip(@ipv4_lookup_url, :ipv4)
  defp get_current_ip_family(:ipv6), do: fetch_public_ip(@ipv6_lookup_url, :ipv6)

  defp fetch_public_ip(url, family) when family in [:ipv4, :ipv6] do
    case Req.get(url) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body
        |> to_string()
        |> String.trim()
        |> normalize_public_ip(family)

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Unable to detect public #{family} address (status=#{status})")
        nil

      {:error, reason} ->
        Logger.warning("Unable to detect public #{family} address: #{inspect(reason)}")
        nil
    end
  end

  defp normalize_public_ip(ip_value, expected_family) when is_binary(ip_value) do
    case :inet.parse_address(String.to_charlist(ip_value)) do
      {:ok, parsed}
      when expected_family == :ipv4 and is_tuple(parsed) and tuple_size(parsed) == 4 ->
        :inet.ntoa(parsed) |> to_string()

      {:ok, parsed}
      when expected_family == :ipv6 and is_tuple(parsed) and tuple_size(parsed) == 8 ->
        :inet.ntoa(parsed) |> to_string()

      _ ->
        Logger.warning("Unable to parse detected public #{expected_family} address: #{ip_value}")
        nil
    end
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
  Retrieve current SSL mode configured in Cloudflare for a zone.

  Typical values:
  - "strict"
  - "full"
  - "flexible"
  - "off"
  """
  @spec get_zone_ssl_mode(String.t()) :: String.t() | nil
  def get_zone_ssl_mode(zone_id) do
    case Req.get(
           "#{@zone_endpoint}/#{zone_id}/settings/ssl",
           headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case body do
          %{"success" => true, "result" => %{"value" => ssl_mode}} when is_binary(ssl_mode) ->
            ssl_mode

          _ ->
            errors = Map.get(body, "errors", [])

            Logger.warning(
              "Cloudflare SSL mode check returned unexpected response: #{inspect(errors)}"
            )

            nil
        end

      {:ok, %Req.Response{body: body}} ->
        errors = Map.get(body, "errors", [])
        Logger.warning("Cloudflare SSL mode check failed: #{inspect(errors)}")
        nil

      {:error, reason} ->
        Logger.warning("Cloudflare SSL mode check failed: #{inspect(reason)}")
        nil
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
  @spec input_for_update_dns_records(list(), String.t() | map()) :: list()
  def input_for_update_dns_records(records, local_ip) when is_binary(local_ip) do
    input_for_update_dns_records(records, %{"A" => local_ip, "AAAA" => local_ip})
  end

  def input_for_update_dns_records(records, local_ips_by_type) when is_map(local_ips_by_type) do
    records
    |> Enum.group_by(&{&1["name"], &1["type"]})
    |> Enum.flat_map(fn {{name, type}, grouped_records} ->
      desired_ip = Map.get(local_ips_by_type, type)

      if is_binary(desired_ip) and desired_ip != "" do
        {updates, skipped} = plan_updates_for_group(grouped_records, desired_ip)

        if skipped != [] do
          skipped_ids = skipped_record_ids(skipped)

          Logger.warning(
            "Duplicate DNS records detected for #{type} #{name}. Skipping #{length(skipped)} record(s) (ids: #{skipped_ids}). Remove duplicates in Cloudflare."
          )
        end

        updates
      else
        []
      end
    end)
  end

  def input_for_update_dns_records(_records, _local_ips_by_type), do: []

  @doc """
  Check CNAME records that must be updated to match a desired record definition.
  """
  @spec input_for_update_cname_records(list(), map()) :: list()
  def input_for_update_cname_records(records, desired_record)
      when is_list(records) and is_map(desired_record) do
    desired_content = Map.get(desired_record, "content")
    desired_proxied = Map.get(desired_record, "proxied", false)
    desired_ttl = resolve_ttl(desired_record, desired_proxied)

    if is_binary(desired_content) do
      records
      |> Enum.filter(&(&1["type"] == "CNAME"))
      |> Enum.group_by(&{&1["name"], &1["type"]})
      |> Enum.flat_map(fn {{name, type}, grouped_records} ->
        {updates, skipped} =
          plan_updates_for_group(grouped_records, desired_content, desired_proxied, desired_ttl)

        if skipped != [] do
          skipped_ids = skipped_record_ids(skipped)

          Logger.warning(
            "Duplicate DNS records detected for #{type} #{name}. Skipping #{length(skipped)} record(s) (ids: #{skipped_ids}). Remove duplicates in Cloudflare."
          )
        end

        updates
      end)
    else
      []
    end
  end

  def input_for_update_cname_records(_records, _desired_record), do: []

  @doc """
  Resolve if DNS record should be proxied.

  By default, keep current Cloudflare proxied value.
  Set `CLOUDFLARE_PROXY_A_RECORDS=true` to force proxied mode,
  except for hostnames matched by `CLOUDFLARE_PROXY_EXCLUDE`.
  """
  @spec resolve_proxied_value(map()) :: boolean()
  def resolve_proxied_value(record) do
    case get_cloudflare_key(:proxy_a_records, false) do
      true ->
        record_name = Map.get(record, "name", "")

        if proxy_excluded?(record_name) do
          false
        else
          true
        end

      false ->
        Map.get(record, "proxied", false)
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
      case Map.get(record, "ttl") do
        1 -> 300
        nil -> 300
        ttl -> ttl
      end
    end
  end

  @doc """
  Retrieve normalized proxy exclusion patterns from configuration.

  Values come from `CLOUDFLARE_PROXY_EXCLUDE` and support exact names or
  wildcard suffixes using `*.`.
  """
  @spec get_proxy_exclude_patterns() :: list(String.t())
  def get_proxy_exclude_patterns do
    get_cloudflare_key(:proxy_exclude, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        String.split(value, ~r/[,\s]+/, trim: true)

      value ->
        [to_string(value)]
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Check if a record name matches any exclusion pattern from
  `CLOUDFLARE_PROXY_EXCLUDE`.
  """
  @spec proxy_excluded?(String.t(), list(String.t())) :: boolean()
  def proxy_excluded?(record_name, patterns \\ get_proxy_exclude_patterns())

  def proxy_excluded?(record_name, patterns)
      when is_binary(record_name) and is_list(patterns) do
    Enum.any?(patterns, fn pattern -> proxy_pattern_match?(record_name, pattern) end)
  end

  def proxy_excluded?(_record_name, _patterns), do: false

  @doc """
  Returns `true` when a hostname is deeper than one label under the zone.

  Example for zone `example.com`:
  - `api.example.com` => false (covered by Universal wildcard)
  - `foo.bar.example.com` => true (usually requires ACM for proxied edge cert)
  """
  @spec requires_advanced_certificate?(String.t(), String.t()) :: boolean()
  def requires_advanced_certificate?(record_name, domain)
      when is_binary(record_name) and is_binary(domain) do
    suffix = ".#{domain}"

    cond do
      record_name == domain ->
        false

      not String.ends_with?(record_name, suffix) ->
        false

      true ->
        relative = String.replace_suffix(record_name, suffix, "")

        relative
        |> String.split(".", trim: true)
        |> length()
        |> Kernel.>(1)
    end
  end

  def requires_advanced_certificate?(_record_name, _domain), do: false

  @doc """
  Evaluate domain posture to quickly detect risky edge configurations.

  Returned map is intended for monitor logs and lightweight health checks.
  """
  @spec evaluate_domain_posture(list(), String.t() | nil, boolean()) :: map()
  def evaluate_domain_posture(records, ssl_mode, expected_proxied) do
    total_records = length(records)
    proxied_count = Enum.count(records, &Map.get(&1, "proxied", false))
    dns_only_count = total_records - proxied_count

    proxy_mismatch_count =
      Enum.count(records, fn record ->
        Map.get(record, "proxied", false) != expected_proxied
      end)

    edge_tls = ssl_mode_to_status(ssl_mode)
    hairpin_risk = if dns_only_count > 0, do: :high, else: :low

    overall =
      cond do
        edge_tls == :red ->
          :red

        total_records == 0 ->
          :yellow

        edge_tls == :green and proxy_mismatch_count == 0 and hairpin_risk == :low ->
          :green

        true ->
          :yellow
      end

    %{
      overall: overall,
      edge_tls: edge_tls,
      ssl_mode: ssl_mode || "unknown",
      expected_proxied: expected_proxied,
      records_total: total_records,
      proxied_count: proxied_count,
      dns_only_count: dns_only_count,
      proxy_mismatch_count: proxy_mismatch_count,
      hairpin_risk: hairpin_risk
    }
  end

  @doc """
  Retrieve the records to be used to monitor for a specific domain.
  """
  def records_to_monitor(domain) do
    records_to_monitor(domain, :domain_mappings)
  end

  @doc """
  Retrieve records to monitor for a specific domain and mapping key.
  """
  def records_to_monitor(domain, mapping_key) when is_atom(mapping_key) do
    [domain | get_subdomains_for_domain(domain, mapping_key)]
  end

  @doc """
  Retrieve configured CNAME records normalized for a specific zone/domain.

  Config comes from `CLOUDFLARE_CNAME_RECORDS_JSON`.
  Supported keys per entry:
  - `name` (required): `@`, relative host (e.g. `www`), wildcard (e.g. `*.idp-dev`) or FQDN.
  - `target` (required): `@`, relative host or FQDN.
  - `proxied` (optional): boolean; defaults to `CLOUDFLARE_PROXY_A_RECORDS`.
  - `ttl` (optional): integer/string; proxied records force TTL `1`.
  - `domain` (optional): restrict entry to a specific zone.
  """
  @spec get_cname_records_for_domain(String.t()) :: list(map())
  def get_cname_records_for_domain(domain) when is_binary(domain) do
    default_proxied = get_cloudflare_key(:proxy_a_records, false)

    get_cloudflare_key(:cname_records, [])
    |> List.wrap()
    |> Enum.flat_map(&normalize_cname_record_config(&1, domain, default_proxied))
    |> Enum.uniq_by(&{&1["name"], &1["content"], &1["proxied"], &1["ttl"]})
  end

  def get_cname_records_for_domain(_domain), do: []

  @doc """
  Get subdomains specifically configured for a domain.
  """
  def get_subdomains_for_domain(domain) do
    get_subdomains_for_domain(domain, :domain_mappings)
  end

  def get_subdomains_for_domain(domain, mapping_key) when is_atom(mapping_key) do
    domain_mappings = get_cloudflare_key(mapping_key, %{})

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
    get_cloudflare_config_domains(:domain_mappings)
  end

  def get_cloudflare_config_domains(mapping_key) when is_atom(mapping_key) do
    case get_cloudflare_key(mapping_key, %{}) do
      mappings when is_map(mappings) -> Map.keys(mappings)
      _ -> []
    end
  end

  @doc """
  Get combined configured domains from A and AAAA mappings.
  """
  def get_all_cloudflare_config_domains do
    (get_cloudflare_config_domains(:domain_mappings) ++
       get_cloudflare_config_domains(:aaaa_domain_mappings))
    |> Enum.uniq()
  end

  @doc """
  Check if a domain is configured for a specific mapping key.
  """
  def domain_configured?(domain, mapping_key \\ :domain_mappings) when is_atom(mapping_key) do
    case get_cloudflare_key(mapping_key, %{}) do
      mappings when is_map(mappings) -> Map.has_key?(mappings, domain)
      _ -> false
    end
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

  defp plan_updates_for_group(records, desired_content) do
    planned_updates =
      Enum.map(records, fn record ->
        desired_proxied = resolve_proxied_value(record)
        desired_ttl = resolve_ttl(record, desired_proxied)
        build_update_plan(record, desired_content, desired_proxied, desired_ttl)
      end)

    resolve_group_update_plan(planned_updates)
  end

  defp plan_updates_for_group(records, desired_content, desired_proxied, desired_ttl) do
    planned_updates =
      Enum.map(records, fn record ->
        build_update_plan(record, desired_content, desired_proxied, desired_ttl)
      end)

    resolve_group_update_plan(planned_updates)
  end

  defp resolve_group_update_plan(planned_updates) do
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

  defp build_update_plan(record, desired_content, desired_proxied, desired_ttl) do
    current_content = Map.get(record, "content")
    current_proxied = Map.get(record, "proxied", false)
    current_ttl = Map.get(record, "ttl")

    %{
      record: record,
      desired_content: desired_content,
      desired_proxied: desired_proxied,
      desired_ttl: desired_ttl,
      needs_update?:
        current_content != desired_content or current_proxied != desired_proxied or
          current_ttl != desired_ttl
    }
  end

  defp build_update_entry(%{
         record: record,
         desired_content: desired_content,
         desired_proxied: desired_proxied,
         desired_ttl: desired_ttl
       }) do
    body =
      %{
        "type" => record["type"],
        "name" => record["name"],
        "ttl" => desired_ttl,
        "proxied" => desired_proxied,
        "content" => desired_content
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

  defp ssl_mode_to_status("strict"), do: :green
  defp ssl_mode_to_status("full"), do: :yellow
  defp ssl_mode_to_status("flexible"), do: :red
  defp ssl_mode_to_status("off"), do: :red
  defp ssl_mode_to_status(_), do: :yellow

  defp proxy_pattern_match?(record_name, pattern)
       when is_binary(record_name) and is_binary(pattern) do
    clean_pattern = String.trim(pattern)

    cond do
      clean_pattern == "" ->
        false

      String.starts_with?(clean_pattern, "*.") ->
        wildcard_suffix = String.trim_leading(clean_pattern, "*.")
        String.ends_with?(record_name, ".#{wildcard_suffix}") and record_name != wildcard_suffix

      true ->
        record_name == clean_pattern
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

  defp normalize_cname_record_config(config, domain, default_proxied)
       when is_map(config) and is_binary(domain) do
    with :ok <- matches_domain_scope?(config, domain),
         {:ok, normalized_name} <- normalize_cname_name(config, domain),
         {:ok, normalized_target} <- normalize_cname_target(config, domain),
         true <- record_belongs_to_zone?(normalized_name, domain),
         false <- same_record_target?(normalized_name, normalized_target) do
      desired_proxied = get_config_boolean(config, "proxied", default_proxied)
      desired_ttl = resolve_ttl(%{"ttl" => get_config_ttl(config)}, desired_proxied)

      [
        %{
          "type" => "CNAME",
          "name" => normalized_name,
          "content" => normalized_target,
          "proxied" => desired_proxied,
          "ttl" => desired_ttl
        }
      ]
    else
      :skip ->
        []

      {:error, reason} ->
        Logger.warning("Ignoring invalid CNAME config for domain #{domain}: #{reason}")
        []

      false ->
        Logger.warning(
          "Ignoring CNAME config outside zone #{domain}: name=#{inspect(get_config_value(config, "name"))}"
        )

        []

      true ->
        Logger.warning(
          "Ignoring CNAME config where name and target are equal for domain #{domain}: name=#{inspect(get_config_value(config, "name"))}"
        )

        []
    end
  end

  defp normalize_cname_record_config(_config, _domain, _default_proxied), do: []

  defp matches_domain_scope?(config, domain) do
    case get_config_string(config, "domain") do
      nil -> :ok
      "" -> :ok
      ^domain -> :ok
      _other -> :skip
    end
  end

  defp normalize_cname_name(config, domain) do
    case get_config_string(config, "name") do
      nil ->
        {:error, "missing name"}

      "" ->
        {:error, "missing name"}

      "@" ->
        {:ok, domain}

      name ->
        {:ok, normalize_subdomain(name, domain)}
    end
  end

  defp normalize_cname_target(config, domain) do
    case get_config_string(config, "target") do
      nil ->
        {:error, "missing target"}

      "" ->
        {:error, "missing target"}

      "@" ->
        {:ok, domain}

      target ->
        clean_target = target |> String.trim_trailing(".")

        normalized_target =
          if String.contains?(clean_target, ".") do
            clean_target
          else
            "#{clean_target}.#{domain}"
          end

        {:ok, normalized_target}
    end
  end

  defp same_record_target?(record_name, record_target) do
    normalize_dns_name(record_name) == normalize_dns_name(record_target)
  end

  defp normalize_dns_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp record_belongs_to_zone?(record_name, domain)
       when is_binary(record_name) and is_binary(domain) do
    record_name == domain or String.ends_with?(record_name, ".#{domain}")
  end

  defp get_config_value(config, key) when is_map(config) and is_binary(key) do
    case key do
      "name" -> Map.get(config, "name", Map.get(config, :name))
      "target" -> Map.get(config, "target", Map.get(config, :target))
      "proxied" -> Map.get(config, "proxied", Map.get(config, :proxied))
      "ttl" -> Map.get(config, "ttl", Map.get(config, :ttl))
      "domain" -> Map.get(config, "domain", Map.get(config, :domain))
      _ -> nil
    end
  end

  defp get_config_string(config, key) do
    case get_config_value(config, key) do
      value when is_binary(value) ->
        value
        |> String.trim()

      value when is_atom(value) ->
        value
        |> to_string()
        |> String.trim()

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        nil
    end
  end

  defp get_config_boolean(config, key, default) do
    case get_config_value(config, key) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> Kernel.in(["true", "1", "yes", "on"])

      _ ->
        default
    end
  end

  defp get_config_ttl(config) do
    case get_config_value(config, "ttl") do
      ttl when is_integer(ttl) and ttl > 0 ->
        ttl

      ttl when is_binary(ttl) ->
        case Integer.parse(String.trim(ttl)) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
