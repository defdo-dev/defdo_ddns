# 0.2.1

## ✨ New Features

- Added `CLOUDFLARE_PROXY_EXCLUDE` to keep selected hostnames in `DNS only` even when `CLOUDFLARE_PROXY_A_RECORDS=true`.
  - Supports exact hostnames and wildcard suffix patterns (for example `*.idp-dev.defdo.ninja`).
- Added `CLOUDFLARE_PROXY_A_RECORDS` to force Cloudflare proxy mode (`proxied=true`) for `A/AAAA` records during updates and auto-creation.
- Added `CLOUDFLARE_A_RECORDS_JSON` with JSON-first parsing for A monitor targets.
  - Supports object and array JSON formats for easier machine-generated config.
  - Falls back to legacy `CLOUDFLARE_DOMAIN_MAPPINGS` when JSON is empty or invalid.
- Added `CLOUDFLARE_AAAA_RECORDS_JSON` for real IPv6 record synchronization.
  - AAAA records now use detected public IPv6 independently from A record IPv4 updates.
  - Supports object and array JSON formats, matching `CLOUDFLARE_A_RECORDS_JSON`.
- Added declarative CNAME management via `CLOUDFLARE_CNAME_RECORDS_JSON`.
  - Supports `name`, `target`, optional `proxied`, `ttl`, and optional `domain` scope per record.
  - Enables wildcard/alias record management using a plain-text env var (JSON string), without requiring a database.
- Added domain posture output in monitor logs:
  - `[HEALTH][GREEN|YELLOW|RED]` summary per domain with SSL mode, proxied/dns-only counts, and hairpin risk.
- Added Cloudflare edge SSL mode checks (`strict/full/flexible/off`) to improve runtime diagnostics.
- Added ACM advisory warnings for deep hostnames that may require Cloudflare Advanced Certificate Manager when proxied.
  - Logs now include `[CERT][ACM]` hints and recommendations.

## 🐛 Bug Fixes

- Improved proxy toggle safety when exclusions are used:
  - Excluded records now resolve desired `proxied=false` during updates.
- Normalized TTL when switching from proxied to DNS-only:
  - Records with Cloudflare auto TTL (`1`) are converted to a standard DNS-only TTL (`300`) to avoid invalid DNS-only state.
- Normalized logs for container dashboards: removed ANSI/emoji log output and disabled console colors to improve log readability.
- Removed Cloudflare `modified_on` timestamp from success log lines to avoid broken rendering in dashboards that misparse ISO8601 text.
- When `CLOUDFLARE_PROXY_A_RECORDS=true`, records with correct IP but `proxied=false` are now patched to enable proxy mode.
- Set explicit logger format without leading blank line (`$time [$level] $message`) to improve compatibility with log viewers.
- Relative wildcard entries in `CLOUDFLARE_DOMAIN_MAPPINGS` (e.g. `*.idp-dev`, `*.rnu`) are now expanded to the current zone (e.g. `*.idp-dev.defdo.ninja`).
- Proxy-mode updates now enforce Cloudflare Auto TTL (`ttl=1`) for proxied records, preventing update failures on some wildcard records.
- Improved Cloudflare API error handling for DNS create/update calls to log errors whenever the API returns `success=false` (including `result=nil` responses).
- Duplicate A/AAAA records for the same `name+type` are now handled safely: if one record is already in desired state, conflicting updates are skipped and a warning with record IDs is logged.
- Improved auto-create safety:
  - When a hostname is declared in `CLOUDFLARE_CNAME_RECORDS_JSON`, monitor now skips auto-creating `A` records for that same name to avoid `A/CNAME` conflicts.
- Improved auto-create logic for IP records:
  - Missing `A` and `AAAA` records are now created independently based on configured mappings and detected address family availability.
- Added graceful handling when a zone ID cannot be resolved before DNS record operations.
- Fixed release boot crash caused by runtime helper loading:
  - Moved configuration parsing helper to compiled app code (`Defdo.ConfigHelper`) so releases do not depend on external `.exs` files at runtime.

## 📚 Documentation

- Expanded README with:
  - Cloudflare SSL/TLS mode behavior (`Flexible`, `Full`, `Full (strict)`).
  - Orange-cloud vs gray-cloud behavior and hairpin implications.
  - New `CLOUDFLARE_PROXY_EXCLUDE` configuration examples.
  - Health posture and ACM warning log interpretation.
- Updated roadmap to reflect completed work and next priorities.

# 0.2.0

## 🚨 Breaking Changes

- **Environment Variable Changes**: 
  - `CLOUDFLARE_DOMAIN` and `CLOUDFLARE_SUBDOMAINS` have been replaced with `CLOUDFLARE_DOMAIN_MAPPINGS`
  - New format: `domain1.com:subdomain1,subdomain2;domain2.com:api,blog;domain3.com:`
  - Migration required: Update your environment variables to use the new mapping format

- **Configuration Format**: 
  - Domain-to-subdomain mapping now uses a structured format instead of separate variables
  - Root domain monitoring requires explicit empty subdomain list (e.g., `example.com:`)

## ✨ New Features

- **Multiple Domain Support**: Monitor and update DNS records for multiple domains simultaneously
- **Auto-creation**: New `AUTO_CREATE_DNS_RECORDS` option to automatically create missing DNS records
- **Promotional Comments**: Auto-created DNS records include promotional comments
- **Improved Logging**: Enhanced status messages with emojis and clearer error reporting
- **Better Error Handling**: More robust error handling and validation

## 🐛 Bug Fixes

- Fixed duplicate function definitions causing compilation warnings
- Resolved configuration parsing issues in runtime.exs
- Improved DNS record validation and creation logic

## 📚 Documentation

- Complete README rewrite with step-by-step setup instructions
- Added troubleshooting section with common issues
- Docker Compose and UniFi Dream Machine Pro examples
- Clear migration guide for breaking changes

# 0.1.1

- Support for multiple domains
- Subdomains must be specific otherwise they are added to the monitor domain even if they didn't exists.

# 0.1.0

- Support for only one domain
- Bootstrap defdo_ddns
