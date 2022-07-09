import Config

config :defdo_ddns, Cloudflare,
  auth_token: System.get_env("CLOUDFLARE_API_TOKEN"),
  domain: System.get_env("CLOUDFLARE_DOMAIN"),
  subdomains: System.get_env("CLOUDFLARE_SUBDOMAINS")
