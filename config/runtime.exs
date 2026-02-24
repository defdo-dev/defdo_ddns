import Config

# Runtime config depends on Defdo.ConfigHelper from compiled app code.
# Keep it in `lib/` (not ad-hoc .exs) so release boot remains stable.

api_port = Defdo.ConfigHelper.parse_integer_env("DDNS_API_PORT", 4050, min: 1, max: 65_535)

monitor_enabled_default = config_env() != :test

config :defdo_ddns, Cloudflare,
  auth_token: System.get_env("CLOUDFLARE_API_TOKEN"),
  domain_mappings:
    Defdo.ConfigHelper.resolve_domain_mappings(
      System.get_env("CLOUDFLARE_DOMAIN_MAPPINGS", ""),
      System.get_env("CLOUDFLARE_A_RECORDS_JSON", "")
    ),
  aaaa_domain_mappings:
    Defdo.ConfigHelper.resolve_json_domain_mappings(
      System.get_env("CLOUDFLARE_AAAA_RECORDS_JSON", ""),
      %{}
    ),
  auto_create_missing_records:
    Defdo.ConfigHelper.parse_boolean_env("AUTO_CREATE_DNS_RECORDS", false),
  proxy_a_records: Defdo.ConfigHelper.parse_boolean_env("CLOUDFLARE_PROXY_A_RECORDS", false),
  proxy_exclude: Defdo.ConfigHelper.parse_list_env("CLOUDFLARE_PROXY_EXCLUDE", []),
  cname_records: Defdo.ConfigHelper.parse_json_env("CLOUDFLARE_CNAME_RECORDS_JSON", [])

config :defdo_ddns,
  monitor_enabled:
    Defdo.ConfigHelper.parse_boolean_env("DDNS_ENABLE_MONITOR", monitor_enabled_default),
  monitor_refetch_every_ms:
    Defdo.ConfigHelper.parse_integer_env("DDNS_REFETCH_EVERY_MS", :timer.minutes(5), min: 1_000)

config :defdo_ddns, Defdo.DDNS.API,
  enabled: Defdo.ConfigHelper.parse_boolean_env("DDNS_API_ENABLED", false),
  port: api_port,
  token: System.get_env("DDNS_API_TOKEN"),
  default_target: System.get_env("DDNS_API_DEFAULT_TARGET", "@"),
  default_proxied: Defdo.ConfigHelper.parse_boolean_env("DDNS_API_DEFAULT_PROXIED", true)

config :logger, :console,
  format: "$time [$level] $message\n",
  colors: [enabled: false]
