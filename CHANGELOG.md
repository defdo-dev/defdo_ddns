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