defmodule Defdo.ConfigHelper do
  @moduledoc """
  Runtime-safe configuration parsing helpers.

  This module is intentionally compiled under `lib/` because `config/runtime.exs`
  depends on it at release boot time. Keeping it compiled avoids release crashes
  caused by missing ad-hoc `.exs` helper files.
  """

  def parse_domain_mappings(""), do: %{}

  def parse_domain_mappings(mappings_string) do
    mappings_string
    |> String.split(";")
    |> Enum.reduce(%{}, fn mapping, acc ->
      case String.split(mapping, ":") do
        [domain, subdomains_str] ->
          clean_domain = String.trim(domain)

          subdomains =
            subdomains_str
            |> String.split(",", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if clean_domain == "" do
            acc
          else
            Map.update(acc, clean_domain, subdomains, fn existing_subdomains ->
              (existing_subdomains ++ subdomains)
              |> Enum.uniq()
            end)
          end

        _ ->
          acc
      end
    end)
  end

  @doc """
  Resolve domain mappings from JSON-first config with legacy fallback.

  Priority:
  1. `a_records_json` (CLOUDFLARE_A_RECORDS_JSON)
  2. `legacy_mappings` (CLOUDFLARE_DOMAIN_MAPPINGS)
  """
  @spec resolve_domain_mappings(String.t() | nil, String.t() | nil) :: map()
  def resolve_domain_mappings(legacy_mappings, a_records_json) do
    legacy_value = legacy_mappings |> to_string_safe()
    json_value = a_records_json |> to_string_safe() |> String.trim()

    if json_value == "" do
      parse_domain_mappings(legacy_value)
    else
      case parse_domain_mappings_json(json_value) do
        {:ok, parsed} ->
          parsed

        {:error, reason} ->
          IO.warn(
            "CLOUDFLARE_A_RECORDS_JSON is invalid (#{reason}). Falling back to CLOUDFLARE_DOMAIN_MAPPINGS."
          )

          parse_domain_mappings(legacy_value)
      end
    end
  end

  @doc """
  Resolve domain mappings from JSON input only.

  Useful for record-specific mapping vars (for example AAAA records)
  where we do not want legacy string fallback semantics.
  """
  @spec resolve_json_domain_mappings(String.t() | nil, map()) :: map()
  def resolve_json_domain_mappings(json_mappings, default \\ %{}) do
    json_value = json_mappings |> to_string_safe() |> String.trim()

    if json_value == "" do
      default
    else
      case parse_domain_mappings_json(json_value) do
        {:ok, parsed} ->
          parsed

        {:error, reason} ->
          IO.warn(
            "JSON mapping source is invalid (#{reason}). Falling back to default mapping value."
          )

          default
      end
    end
  end

  @doc """
  Parse JSON domain mappings.

  Supported formats:

  1) Object map:
  `{"example.com":["www","api"],"zone.net":[]}`

  2) Array entries:
  `[{"domain":"example.com","subdomains":["www","api"]}]`
  (`subdomains` may also be named `hosts` or `records`)
  """
  @spec parse_domain_mappings_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_domain_mappings_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, decoded} ->
        normalize_domain_mapping_json(decoded)

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  def parse_boolean_env(env_var, default \\ false) do
    env_var
    |> System.get_env()
    |> parse_boolean(default)
  end

  def parse_list_env(env_var, default \\ []) do
    env_var
    |> System.get_env()
    |> parse_list(default)
  end

  def parse_json_env(env_var, default \\ []) do
    env_var
    |> System.get_env()
    |> parse_json(default, env_var)
  end

  defp parse_boolean(nil, default), do: default

  defp parse_boolean(value, _default) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes", "on"])
  end

  defp parse_list(nil, default), do: default

  defp parse_list(value, _default) when is_binary(value) do
    value
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_json(nil, default, _env_var), do: default

  defp parse_json(value, default, env_var) when is_binary(value) do
    trimmed_value = String.trim(value)

    if trimmed_value == "" do
      default
    else
      case Jason.decode(trimmed_value) do
        {:ok, parsed} ->
          parsed

        {:error, _reason} ->
          IO.warn("#{env_var} contains invalid JSON. Falling back to default value.")
          default
      end
    end
  end

  defp normalize_domain_mapping_json(decoded) when is_map(decoded) do
    decoded
    |> Enum.reduce_while({:ok, %{}}, fn {domain, subdomains}, {:ok, acc} ->
      case normalize_domain_mapping_entry(domain, subdomains) do
        {:ok, clean_domain, clean_subdomains} ->
          {:cont, {:ok, merge_domain_mapping(acc, clean_domain, clean_subdomains)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_domain_mapping_json(decoded) when is_list(decoded) do
    decoded
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, acc} ->
      case normalize_domain_mapping_array_entry(entry) do
        {:ok, clean_domain, clean_subdomains} ->
          {:cont, {:ok, merge_domain_mapping(acc, clean_domain, clean_subdomains)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_domain_mapping_json(_decoded) do
    {:error, "expected object or array"}
  end

  defp normalize_domain_mapping_array_entry(entry) when is_map(entry) do
    domain = map_get(entry, "domain")

    subdomains =
      map_get(entry, "subdomains") || map_get(entry, "hosts") || map_get(entry, "records")

    normalize_domain_mapping_entry(domain, subdomains || [])
  end

  defp normalize_domain_mapping_array_entry(_entry) do
    {:error, "array entries must be objects"}
  end

  defp normalize_domain_mapping_entry(domain, subdomains) do
    clean_domain = domain |> to_string_safe() |> String.trim()

    cond do
      clean_domain == "" ->
        {:error, "domain must be a non-empty string"}

      true ->
        case normalize_subdomains(subdomains) do
          {:ok, clean_subdomains} ->
            {:ok, clean_domain, clean_subdomains}

          {:error, reason} ->
            {:error, "invalid subdomains for #{clean_domain}: #{reason}"}
        end
    end
  end

  defp normalize_subdomains(subdomains) when is_list(subdomains) do
    clean_subdomains =
      subdomains
      |> Enum.map(&to_string_safe/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, clean_subdomains}
  end

  defp normalize_subdomains(subdomains) when is_binary(subdomains) do
    subdomains
    |> String.split(~r/[,\s]+/, trim: true)
    |> normalize_subdomains()
  end

  defp normalize_subdomains(nil), do: {:ok, []}
  defp normalize_subdomains(_), do: {:error, "must be list or string"}

  defp merge_domain_mapping(acc, domain, subdomains) do
    Map.update(acc, domain, subdomains, fn existing_subdomains ->
      (existing_subdomains ++ subdomains)
      |> Enum.uniq()
    end)
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      case key do
        "domain" -> :domain
        "subdomains" -> :subdomains
        "hosts" -> :hosts
        "records" -> :records
        _ -> nil
      end

    case atom_key do
      nil -> Map.get(map, key)
      _ -> Map.get(map, key, Map.get(map, atom_key))
    end
  end

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)
end
