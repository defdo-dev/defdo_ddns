import Config

# Helper function to parse domain mappings
defmodule ConfigHelper do
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

  defp parse_boolean(nil, default), do: default

  defp parse_boolean(value, _default) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes", "on"])
  end
end

config :defdo_ddns, Cloudflare,
  auth_token: System.get_env("CLOUDFLARE_API_TOKEN"),
  domain_mappings:
    ConfigHelper.parse_domain_mappings(System.get_env("CLOUDFLARE_DOMAIN_MAPPINGS", "")),
  auto_create_missing_records: ConfigHelper.parse_boolean_env("AUTO_CREATE_DNS_RECORDS", false),
  proxy_a_records: ConfigHelper.parse_boolean_env("CLOUDFLARE_PROXY_A_RECORDS", false)

config :logger, :console,
  format: "$time [$level] $message\n",
  colors: [enabled: false]
