# 🏠 Defdo DDNS - Simple Dynamic DNS for Home Labs

> **Keep your home server accessible even when your IP address changes!**

Defdo DDNS automatically updates your Cloudflare DNS records when your home internet IP address changes. Perfect for home labs, self-hosted services, and remote access.

## 🤔 What Problem Does This Solve?

**The Problem**: Your home internet provider gives you a dynamic IP address that changes periodically. This breaks access to your home servers, security cameras, or self-hosted applications.

**The Solution**: Defdo DDNS monitors your IP address and automatically updates your domain's DNS records in Cloudflare whenever it changes.

### ✨ Key Features

- 🔄 **Automatic IP monitoring** - Checks every 5 minutes by default
- 🌐 **Multiple domain support** - Handle multiple domains and subdomains
- 🚀 **Auto-creation** - Creates missing DNS records automatically
- ☁️ **Cloudflare Proxy Mode** - Force `A/AAAA` records to run behind Cloudflare proxy
- 🌐 **Real IPv6 support** - Updates `AAAA` records with detected public IPv6
- 🧭 **Declarative CNAME sync** - Manage wildcard and alias records from env config
- 🐳 **Docker ready** - Easy deployment with Docker/Podman
- 📝 **Smart logging** - Clear status updates and error messages
- ⚡ **Lightweight** - Built with Elixir for reliability and performance

## 🚀 Quick Start

### Prerequisites

1. **Domain managed by Cloudflare** (free account works fine)
2. **Cloudflare API Token** with DNS edit permissions
3. **Docker or Podman** installed on your system

### Step 1: Get Your Cloudflare API Token

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. Click "Create Token"
3. Use the "Custom token" template
4. Set permissions:
   - **Zone** → **Zone** → **Read**
   - **Zone** → **DNS** → **Edit**
5. Set zone resources to include your domain
6. Copy the generated token

### Step 2: Configure Your Domains

You can configure monitored hostnames in two formats.

Legacy string format (`CLOUDFLARE_DOMAIN_MAPPINGS`):
```
domain1.com:subdomain1,subdomain2;domain2.com:api,blog
```

**Examples**:
- Root domain only: `example.com:`
- With subdomains: `example.com:www,api,blog`
- Multiple domains: `example.com:www,api;mysite.org:home,server`

JSON format (`CLOUDFLARE_A_RECORDS_JSON`, recommended for automation):

```json
{"example.com":["www","api"],"defdo.in":[]}
```

IPv6 JSON format (`CLOUDFLARE_AAAA_RECORDS_JSON`, optional):

```json
{"example.com":["www"],"ipv6-only.net":["app"]}
```

Or array form:

```json
[{"domain":"example.com","subdomains":["www","api"]},{"domain":"defdo.in","subdomains":[]}]
```

Priority:
- If `CLOUDFLARE_A_RECORDS_JSON` is set and valid, it is used.
- If JSON is empty or invalid, the app falls back to `CLOUDFLARE_DOMAIN_MAPPINGS`.
- `CLOUDFLARE_AAAA_RECORDS_JSON` is evaluated independently and controls which hostnames are managed as `AAAA`.

### Step 3: Run with Docker

```bash
docker run -d \
  --name defdo-ddns \
  --restart unless-stopped \
  -e CLOUDFLARE_API_TOKEN="your_token_here" \
  -e CLOUDFLARE_A_RECORDS_JSON='{"example.com":["www","api"]}' \
  -e CLOUDFLARE_AAAA_RECORDS_JSON='{"example.com":["www"]}' \
  -e AUTO_CREATE_DNS_RECORDS="true" \
  -e CLOUDFLARE_PROXY_A_RECORDS="true" \
  -e CLOUDFLARE_CNAME_RECORDS_JSON='[{"name":"*","target":"@","proxied":true}]' \
  paridin/defdo_ddns
```

### Step 4: Verify It's Working

Check the logs to see if it's working:
```bash
docker logs defdo-ddns
```

You should see messages like:
```
Executing checkup...
Processing domain: example.com
Success - www.example.com DNS record updated to IP 203.0.113.1
Checkup completed
```

## ⚙️ Configuration Options

| Environment Variable | Required | Default | Description |
|---------------------|----------|---------|-------------|
| `CLOUDFLARE_API_TOKEN` | ✅ Yes | - | Your Cloudflare API token |
| `CLOUDFLARE_DOMAIN_MAPPINGS` | ✅ Yes* | - | Legacy domain mapping string (`domain.com:sub1,sub2;...`) |
| `CLOUDFLARE_A_RECORDS_JSON` | ❌ No | `""` | JSON A record mappings. When valid, overrides `CLOUDFLARE_DOMAIN_MAPPINGS` |
| `CLOUDFLARE_AAAA_RECORDS_JSON` | ❌ No | `""` | JSON AAAA record mappings. Managed independently from A mappings |
| `AUTO_CREATE_DNS_RECORDS` | ❌ No | `false` | Auto-create missing DNS records |
| `CLOUDFLARE_PROXY_A_RECORDS` | ❌ No | `false` | Force Cloudflare proxy mode (`proxied=true`) for `A/AAAA` records |
| `CLOUDFLARE_PROXY_EXCLUDE` | ❌ No | `""` | Comma/space-separated host patterns to keep `DNS only` even when proxy mode is enabled. Supports exact hosts and wildcard suffixes (`*.idp-dev.example.com`) |
| `CLOUDFLARE_CNAME_RECORDS_JSON` | ❌ No | `[]` | JSON array of managed CNAME records (`name`, `target`, optional `proxied`, `ttl`, `domain`) |
| `DDNS_ENABLE_MONITOR` | ❌ No | `true`** | Enable/disable background monitor process |
| `DDNS_REFETCH_EVERY_MS` | ❌ No | `300000` | Monitor interval in milliseconds |
| `DDNS_API_ENABLED` | ❌ No | `false` | Enable embedded HTTP API (Bandit) |
| `DDNS_API_PORT` | ❌ No | `4050` | HTTP API listen port |
| `DDNS_API_TOKEN` | ⚠️ Conditional*** | - | Global API token fallback (single-client mode) |
| `DDNS_API_CLIENTS_JSON` | ⚠️ Conditional*** | `[]` | Multi-tenant-light clients (`id`, `token`, `allowed_base_domains`) |
| `DDNS_API_ALLOW_RUNTIME_CLIENTS` | ❌ No | `false` | Allow API startup without token/clients (deny-all until runtime injection) |
| `DDNS_API_DEFAULT_TARGET` | ❌ No | `@` | Default CNAME target used by API upsert |
| `DDNS_API_DEFAULT_PROXIED` | ❌ No | `true` | Default proxied mode used by API upsert |

\* Required unless `CLOUDFLARE_A_RECORDS_JSON` or `CLOUDFLARE_AAAA_RECORDS_JSON` is provided.
\** In `test` environment the default is `false` to avoid background network checks during test runs.
\*** When `DDNS_API_ENABLED=true`, configure at least one auth mode:
- `DDNS_API_TOKEN` (legacy single-client), or
- `DDNS_API_CLIENTS_JSON` (multi-tenant-light), or
- `DDNS_API_ALLOW_RUNTIME_CLIENTS=true` and inject clients at runtime.

### Managed CNAME Records (Text Env via JSON)

`CLOUDFLARE_CNAME_RECORDS_JSON` is a plain text env var that contains JSON.
This lets you keep records declarative without adding a database.

Example:

```bash
-e CLOUDFLARE_CNAME_RECORDS_JSON='[
  {"name":"*","target":"@","proxied":true},
  {"name":"join","target":"@","proxied":true,"ttl":1,"domain":"defdo.in"},
  {"name":"www","target":"@","proxied":true}
]'
```

Rules:

- `name` supports `@`, relative hosts (`www`), wildcard (`*.idp-dev`), or FQDN.
- `target` supports `@`, relative hosts, or FQDN.
- `domain` is optional and limits an entry to one zone (recommended in multi-domain setups).
- If `proxied=true`, TTL is forced to `1` (Cloudflare Auto TTL).
- If a hostname is managed as CNAME, this app skips auto-creating `A` for that same name.

### Optional HTTP API (Bandit)

This project can expose a lightweight HTTP API using Bandit.
Enable it with:

```bash
-e DDNS_API_ENABLED=true \
-e DDNS_API_PORT=4050 \
-e DDNS_API_TOKEN="replace-with-strong-token"
```

Multi-tenant-light mode with client credentials:

```bash
-e DDNS_API_ENABLED=true \
-e DDNS_API_PORT=4050 \
-e DDNS_API_CLIENTS_JSON='[
  {"id":"tenant-a","token":"tenant-a-secret","allowed_base_domains":["defdo.in"]},
  {"id":"tenant-b","token":"tenant-b-secret","allowed_base_domains":["defdo.dev","example.com"]}
]'
```

Endpoints:

- `GET /health` returns `{ "status": "ok" }`.
- `POST /v1/dns/upsert` upserts a CNAME record for a FQDN under a base zone.

Auth headers:

- `Authorization: Bearer <token>` or `x-api-token: <token>`
- In multi-tenant-light mode (`DDNS_API_CLIENTS_JSON` or runtime clients), also send `x-client-id: <client-id>`.
- `base_domain` is validated against that client's `allowed_base_domains`.
- If clients are configured and `x-client-id` is omitted, a valid global token (`DDNS_API_TOKEN`) is accepted as fallback.

Example request:

```bash
curl -X POST "http://localhost:4050/v1/dns/upsert" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${DDNS_API_TOKEN}" \
  -d '{"fqdn":"acme-idp.defdo.in","base_domain":"defdo.in","target":"@","proxied":true}'
```

Multi-tenant-light request:

```bash
curl -X POST "http://localhost:4050/v1/dns/upsert" \
  -H "Content-Type: application/json" \
  -H "x-client-id: tenant-a" \
  -H "x-api-token: tenant-a-secret" \
  -d '{"fqdn":"acme-idp.defdo.in","base_domain":"defdo.in","target":"@","proxied":false}'
```

### defdo_auth Integration (multi-tenant-light)

`defdo_ddns` can stay stateless and only enforce technical authorization + DNS rules.
`defdo_auth` (or another upstream service) should own tenant/business data and send authorized calls.

Recommended split:

1. `defdo_auth` stores tenant/client data and decides who can upsert which domain.
2. `defdo_auth` calls `defdo_ddns` HTTP API with `x-client-id`, token, and DNS payload.
3. `defdo_ddns` validates token + allowed base domain and executes DNS upsert idempotently.

If `defdo_auth` embeds this library in the same BEAM VM, you can inject credentials in memory (ETS-backed):

```elixir
clients = [
  %{
    "id" => "tenant-a",
    "token" => "tenant-a-secret",
    "allowed_base_domains" => ["defdo.in"]
  }
]

:ok = Defdo.DDNS.set_api_clients(clients)
safe_view = Defdo.DDNS.api_clients()               # token redacted
raw_view = Defdo.DDNS.api_clients(redact: false)   # trusted local debugging only
```

To boot in deny-all mode until runtime injection:

```bash
-e DDNS_API_ENABLED=true \
-e DDNS_API_ALLOW_RUNTIME_CLIENTS=true
```

## 📋 Advanced Usage

### For UniFi Dream Machine Pro Users

Create a startup script at `/mnt/data/on_boot.d/30-defdo-ddns.sh`:

```bash
#!/bin/sh
CONTAINER=defdo-ddns

if podman container exists "$CONTAINER"; then
  podman start "$CONTAINER"
else
  podman run -d --rm \
    --net=host \
    --name "$CONTAINER" \
    --security-opt=no-new-privileges \
    -e CLOUDFLARE_API_TOKEN="your_token_here" \
    -e CLOUDFLARE_A_RECORDS_JSON='{"example.com":["www","api"]}' \
    -e CLOUDFLARE_AAAA_RECORDS_JSON='{"example.com":["www"]}' \
    -e AUTO_CREATE_DNS_RECORDS="true" \
    -e CLOUDFLARE_PROXY_A_RECORDS="true" \
    -e CLOUDFLARE_PROXY_EXCLUDE="*.idp-dev.example.com,*.iot-dev.example.com" \
    -e CLOUDFLARE_CNAME_RECORDS_JSON='[{"name":"*","target":"@","proxied":true}]' \
    paridin/defdo_ddns
fi
```

Make it executable:
```bash
chmod +x /mnt/data/on_boot.d/30-defdo-ddns.sh
```

### Docker Compose

```yaml
version: '3.8'
services:
  defdo-ddns:
    image: paridin/defdo_ddns
    container_name: defdo-ddns
    restart: unless-stopped
    environment:
      - CLOUDFLARE_API_TOKEN=your_token_here
      - 'CLOUDFLARE_A_RECORDS_JSON={"example.com":["www","api"]}'
      - 'CLOUDFLARE_AAAA_RECORDS_JSON={"example.com":["www"]}'
      - AUTO_CREATE_DNS_RECORDS=true
      - CLOUDFLARE_PROXY_A_RECORDS=true
      - CLOUDFLARE_PROXY_EXCLUDE=*.idp-dev.example.com,*.iot-dev.example.com
      - 'CLOUDFLARE_CNAME_RECORDS_JSON=[{"name":"*","target":"@","proxied":true}]'
```

## 🔧 Troubleshooting

### Common Issues

**❌ "DNS record not found"**
- Enable `AUTO_CREATE_DNS_RECORDS=true` to create missing records automatically
- Or manually create A records in Cloudflare dashboard

**❌ "CNAME not created / conflicting type"**
- A hostname cannot have `CNAME` plus `A/AAAA` at the same time.
- Remove conflicting records in Cloudflare, then re-run monitor.
- Use `domain` inside `CLOUDFLARE_CNAME_RECORDS_JSON` to avoid applying a relative name to the wrong zone.

**❌ "AAAA records not updating"**
- Ensure `CLOUDFLARE_AAAA_RECORDS_JSON` includes the hostname/domain.
- Ensure your network actually has public IPv6 reachability.
- The app skips AAAA updates/auto-create when no public IPv6 is detected in that cycle.

**❌ "Hairpin NAT / loopback issues"**
- Enable `CLOUDFLARE_PROXY_A_RECORDS=true` so records are created/updated with Cloudflare proxy enabled
- If you use deep subdomains (for example `foo.idp-dev.example.com`) and do not use Cloudflare Advanced Certificate Manager, add exclusions with `CLOUDFLARE_PROXY_EXCLUDE` to keep them in `DNS only`

### Cloudflare SSL/TLS Modes (Flexible vs Full vs Full strict)

If your records are proxied by Cloudflare (orange cloud), Cloudflare becomes the TLS client to your origin (Traefik/Nginx/Caddy).
Choosing the wrong SSL/TLS mode can cause confusing errors like `404` at the edge or origin mismatch.

| Mode | Cloudflare -> Origin | Certificate Validation | Typical Impact |
|------|-----------------------|------------------------|----------------|
| `Flexible` | HTTP (`:80`) | No TLS to origin | Can fail when origin only serves HTTPS (`websecure`) and is not recommended for production security |
| `Full` | HTTPS (`:443`) | No validation | Usually works with self-signed certs, but TLS trust is weak |
| `Full (strict)` | HTTPS (`:443`) | Yes (valid cert required) | Recommended. End-to-end TLS with proper trust and fewer routing surprises |

**Recommended for home labs with reverse proxies**: `Full (strict)`.

### Orange cloud vs gray cloud (Cloudflare DNS proxy)

In Cloudflare DNS, each record has a cloud status:

- **Orange cloud (`Proxied`)**:
  - Traffic goes through Cloudflare edge.
  - Public clients see Cloudflare IPs, not your origin IP.
  - Applies Cloudflare HTTP features and SSL mode behavior.
  - Often helps with local hairpin limitations for web apps.
- **Gray cloud (`DNS only`)**:
  - DNS resolves directly to your public origin IP.
  - Cloudflare edge rules/proxy are not in the request path.
  - Local access depends on your router/modem NAT loopback behavior.

In this project, `CLOUDFLARE_PROXY_A_RECORDS=true` means records are updated/created as **orange cloud** (`proxied=true`).
Set it to `false` for **gray cloud** (`DNS only`).

### Hairpin NAT vs Cloudflare Proxy (why behavior changes)

- `DNS only` records resolve directly to your public IP.
- Local clients then depend on router/modem NAT loopback (hairpin) support.
- If hairpin is missing or inconsistent, local access may timeout while external access still works.

With `CLOUDFLARE_PROXY_A_RECORDS=true`:
- Web traffic (`HTTP/HTTPS/WebSocket`) goes through Cloudflare first.
- This often avoids local hairpin limitations for browser-based apps.
- Non-HTTP protocols (for example raw TCP services) still need direct routing/VPN design.

### Safe Cloudflare checklist for proxied hosts

1. Set SSL/TLS mode to `Full (strict)`.
2. Keep Host header and SNI preserved unless you intentionally override them.
3. Avoid broad Origin Rules over "all incoming requests" unless you need them.
4. If behavior seems inconsistent after toggling proxy mode, flush local DNS cache and re-test.

**❌ "Authentication failed"**
- Verify your API token has correct permissions
- Check token hasn't expired

**❌ "Zone not found"**
- Ensure domain is added to your Cloudflare account
- Verify domain spelling in configuration

### Getting Help

Check logs for detailed error messages:
```bash
docker logs defdo-ddns --follow
```

### Health Status Output (`GREEN` / `YELLOW` / `RED`)

Each checkup now emits a domain posture line like:

```text
[HEALTH][GREEN] domain=example.com ssl_mode=strict edge_tls=green proxied=3/3 dns_only=0 proxy_mismatch=0 hairpin_risk=low
```

Interpretation:
- `GREEN`: strict TLS mode at Cloudflare + proxied records aligned + low hairpin risk.
- `YELLOW`: configuration works but has risk signals (for example `full` mode, DNS-only records, or proxy mismatch).
- `RED`: high-risk edge posture (for example `flexible`/`off` SSL mode).

When deep proxied hostnames are detected, logs can also include:

```text
[CERT][ACM] ... may not be covered by Cloudflare Universal SSL and can require Advanced Certificate Manager.
```

## 🛣️ Roadmap

### ✅ Completed

- [x] Automatic public IP monitoring and Cloudflare DNS updates
- [x] Multi-domain and multi-subdomain mapping
- [x] Auto-create missing DNS records
- [x] Optional Cloudflare proxy mode (`CLOUDFLARE_PROXY_A_RECORDS`)
- [x] Proxy exclusion list for nested hosts (`CLOUDFLARE_PROXY_EXCLUDE`)
- [x] Declarative CNAME management (`CLOUDFLARE_CNAME_RECORDS_JSON`)
- [x] Real AAAA synchronization with IPv6 public address detection (`CLOUDFLARE_AAAA_RECORDS_JSON`)
- [x] Duplicate DNS record detection with safe update behavior
- [x] Domain posture health output (`[HEALTH][GREEN|YELLOW|RED]`)
- [x] Troubleshooting docs for SSL modes, orange/gray cloud, and hairpin NAT behavior
- [x] Optional embedded HTTP API with Bandit (`/health`, `/v1/dns/upsert`)

### ⏭️ Next

- [ ] Fail-fast/alert mode when posture is `RED` (for example strict policy mode)
- [ ] CNAME policy validator command (report deep proxied hosts and ACM-risk before deploy)
- [ ] Webhook notifications (Slack/Discord/Telegram/email)
- [ ] Web dashboard for monitoring and history
- [ ] Support for other DNS providers

## 🤝 Contributing

We welcome contributions! Please feel free to:
- Report bugs
- Suggest features
- Submit pull requests
- Improve documentation

## 📄 License

Licensed under Apache License 2.0. See `LICENSE.md`.

---

## 🇲🇽 Support Our Mission (Mexico Only)

If you love open source and want to support our work, consider joining our developer-focused mobile service in Mexico: [defdo community](https://shop.defdo.dev/?dcode=defdo_ddns&scode=github). Help us grow while getting great mobile service!
