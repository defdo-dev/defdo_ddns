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
          subdomains = String.split(subdomains_str, ",", trim: true)
          Map.put(acc, domain, subdomains)

        _ ->
          acc
      end
    end)
  end
end

config :defdo_ddns, Cloudflare,
  auth_token: System.get_env("CLOUDFLARE_API_TOKEN"),
  domain_mappings:
    ConfigHelper.parse_domain_mappings(System.get_env("CLOUDFLARE_DOMAIN_MAPPINGS", "")),
  auto_create_missing_records: System.get_env("AUTO_CREATE_DNS_RECORDS", "false") == "true"
