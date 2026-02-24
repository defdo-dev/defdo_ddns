defmodule Defdo.DDNS.API.DNS do
  @moduledoc false

  require Logger

  @spec upsert_free_domain(map()) :: {:ok, map()} | {:error, term()}
  def upsert_free_domain(params) when is_map(params) do
    with {:ok, fqdn} <- fetch_required_string(params, "fqdn"),
         {:ok, base_domain} <- fetch_required_string(params, "base_domain"),
         :ok <- ensure_zone_membership(fqdn, base_domain),
         {:ok, zone_id} <- fetch_zone_id(base_domain),
         {:ok, desired_record} <- build_desired_record(params, fqdn, base_domain),
         {:ok, result} <- upsert_cname(zone_id, desired_record) do
      {:ok, result}
    end
  rescue
    error ->
      Logger.error("dns_api_upsert_failed reason=#{Exception.message(error)}")
      {:error, {:upstream, :request_failed}}
  end

  def upsert_free_domain(_), do: {:error, {:validation, %{"params" => "must be an object"}}}

  defp upsert_cname(zone_id, desired_record) do
    existing_records = ddns_module().list_dns_records(zone_id, name: desired_record["name"])
    cname_records = Enum.filter(existing_records, &(&1["type"] == "CNAME"))
    conflicting_records = Enum.reject(existing_records, &(&1["type"] == "CNAME"))

    cond do
      conflicting_records != [] ->
        conflict_types =
          conflicting_records
          |> Enum.map(& &1["type"])
          |> Enum.uniq()

        {:error, {:conflict, %{types: conflict_types}}}

      cname_records == [] ->
        case ddns_module().create_dns_record(zone_id, desired_record) do
          {true, record} when is_map(record) ->
            {:ok, %{action: "created", record: record}}

          _ ->
            {:error, {:upstream, :create_failed}}
        end

      true ->
        updates = ddns_module().input_for_update_cname_records(cname_records, desired_record)

        case updates do
          [] ->
            {:ok, %{action: "noop", record: List.first(cname_records)}}

          _ ->
            apply_updates(zone_id, updates)
        end
    end
  end

  defp apply_updates(zone_id, updates) do
    results =
      updates
      |> Enum.map(&ddns_module().apply_update(zone_id, &1))

    case Enum.find(results, fn
           {true, _} -> false
           _ -> true
         end) do
      nil ->
        last_record =
          results
          |> List.last()
          |> case do
            {true, record} -> record
            _ -> nil
          end

        {:ok, %{action: "updated", record: last_record}}

      _ ->
        {:error, {:upstream, :update_failed}}
    end
  end

  defp fetch_zone_id(base_domain) do
    case ddns_module().get_zone_id(base_domain) do
      zone_id when is_binary(zone_id) and zone_id != "" ->
        {:ok, zone_id}

      _ ->
        {:error, {:upstream, :zone_not_found}}
    end
  end

  defp build_desired_record(params, fqdn, base_domain) do
    case get_string(params, "record_type", "CNAME") |> String.upcase() do
      "CNAME" ->
        proxied = get_boolean(params, "proxied", default_proxied())

        {:ok,
         %{
           "type" => "CNAME",
           "name" => fqdn,
           "content" => resolve_target(params, base_domain),
           "proxied" => proxied,
           "ttl" => resolve_ttl(params, proxied)
         }}

      type ->
        {:error, {:validation, %{"record_type" => "unsupported value #{type}"}}}
    end
  end

  defp resolve_target(params, base_domain) do
    target = get_string(params, "target", default_target()) |> String.trim()

    cond do
      target == "@" -> base_domain
      String.contains?(target, ".") -> String.trim_trailing(target, ".")
      true -> "#{target}.#{base_domain}"
    end
  end

  defp resolve_ttl(params, proxied) do
    if proxied do
      1
    else
      case Map.get(params, "ttl") || Map.get(params, :ttl) do
        value when is_integer(value) and value > 0 ->
          value

        value when is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {int, ""} when int > 0 -> int
            _ -> 300
          end

        _ ->
          300
      end
    end
  end

  defp ensure_zone_membership(fqdn, base_domain) do
    if fqdn == base_domain or String.ends_with?(fqdn, ".#{base_domain}") do
      :ok
    else
      {:error, {:validation, %{"fqdn" => "must belong to base_domain"}}}
    end
  end

  defp fetch_required_string(params, field) when is_binary(field) do
    value = get_string(params, field, nil)

    case normalize_hostname(value) do
      nil -> {:error, {:validation, %{field => "can't be blank"}}}
      hostname -> {:ok, hostname}
    end
  end

  defp get_boolean(params, key, default) when is_binary(key) do
    case fetch_param(params, key) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        normalized =
          value
          |> String.trim()
          |> String.downcase()

        normalized in ~w(true 1 yes on)

      _ ->
        default
    end
  end

  defp get_string(params, key, default) when is_binary(key) do
    case fetch_param(params, key) do
      value when is_binary(value) -> value
      nil -> default
      value -> to_string(value)
    end
  end

  defp fetch_param(params, key) when is_binary(key) do
    case key do
      "fqdn" -> Map.get(params, "fqdn") || Map.get(params, :fqdn)
      "base_domain" -> Map.get(params, "base_domain") || Map.get(params, :base_domain)
      "record_type" -> Map.get(params, "record_type") || Map.get(params, :record_type)
      "target" -> Map.get(params, "target") || Map.get(params, :target)
      "proxied" -> Map.get(params, "proxied") || Map.get(params, :proxied)
      "ttl" -> Map.get(params, "ttl") || Map.get(params, :ttl)
      _ -> Map.get(params, key)
    end
  end

  defp normalize_hostname(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> case do
      "" -> nil
      hostname -> hostname
    end
  end

  defp normalize_hostname(_), do: nil

  defp default_target do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:default_target, "@")
  end

  defp default_proxied do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:default_proxied, true)
  end

  defp ddns_module do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:ddns_module, Defdo.Cloudflare.DDNS)
  end
end
