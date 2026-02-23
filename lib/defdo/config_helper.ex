defmodule Defdo.ConfigHelper do
  @moduledoc false

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
end
