# 0.2.1

## ✨ New Features

- Added `CLOUDFLARE_PROXY_A_RECORDS` to force Cloudflare proxy mode (`proxied=true`) for `A/AAAA` records during updates and auto-creation.

## 🐛 Bug Fixes

- Normalized logs for container dashboards: removed ANSI/emoji log output and disabled console colors to improve log readability.
- Removed Cloudflare `modified_on` timestamp from success log lines to avoid broken rendering in dashboards that misparse ISO8601 text.
- When `CLOUDFLARE_PROXY_A_RECORDS=true`, records with correct IP but `proxied=false` are now patched to enable proxy mode.
- Set explicit logger format without leading blank line (`$time [$level] $message`) to improve compatibility with log viewers.
- Relative wildcard entries in `CLOUDFLARE_DOMAIN_MAPPINGS` (e.g. `*.idp-dev`, `*.rnu`) are now expanded to the current zone (e.g. `*.idp-dev.defdo.ninja`).
- Proxy-mode updates now enforce Cloudflare Auto TTL (`ttl=1`) for proxied records, preventing update failures on some wildcard records.
- Improved Cloudflare API error handling for DNS create/update calls to log errors whenever the API returns `success=false` (including `result=nil` responses).
- Duplicate A/AAAA records for the same `name+type` are now handled safely: if one record is already in desired state, conflicting updates are skipped and a warning with record IDs is logged.

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
