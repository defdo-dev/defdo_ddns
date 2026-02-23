import Config

config :defdo_ddns, Cloudflare,
  auth_token: System.get_env("CLOUDFLARE_API_TOKEN"),
  domain_mappings:
    Defdo.ConfigHelper.parse_domain_mappings(System.get_env("CLOUDFLARE_DOMAIN_MAPPINGS", "")),
  auto_create_missing_records:
    Defdo.ConfigHelper.parse_boolean_env("AUTO_CREATE_DNS_RECORDS", false),
  proxy_a_records: Defdo.ConfigHelper.parse_boolean_env("CLOUDFLARE_PROXY_A_RECORDS", false),
  proxy_exclude: Defdo.ConfigHelper.parse_list_env("CLOUDFLARE_PROXY_EXCLUDE", []),
  cname_records: Defdo.ConfigHelper.parse_json_env("CLOUDFLARE_CNAME_RECORDS_JSON", [])

config :logger, :console,
  format: "$time [$level] $message\n",
  colors: [enabled: false]
