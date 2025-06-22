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

Create your domain mapping string in this format:
```
domain1.com:subdomain1,subdomain2;domain2.com:api,blog
```

**Examples**:
- Root domain only: `example.com:`
- With subdomains: `example.com:www,api,blog`
- Multiple domains: `example.com:www,api;mysite.org:home,server`

### Step 3: Run with Docker

```bash
docker run -d \
  --name defdo-ddns \
  --restart unless-stopped \
  -e CLOUDFLARE_API_TOKEN="your_token_here" \
  -e CLOUDFLARE_DOMAIN_MAPPINGS="example.com:www,api" \
  -e AUTO_CREATE_DNS_RECORDS="true" \
  paridin/defdo_ddns
```

### Step 4: Verify It's Working

Check the logs to see if it's working:
```bash
docker logs defdo-ddns
```

You should see messages like:
```
🏪 Executing the checkup...
🏪 example.com
✅ Success - www.example.com dns record change to a new ip 203.0.113.1
🏪 checkup completed!
```

## ⚙️ Configuration Options

| Environment Variable | Required | Default | Description |
|---------------------|----------|---------|-------------|
| `CLOUDFLARE_API_TOKEN` | ✅ Yes | - | Your Cloudflare API token |
| `CLOUDFLARE_DOMAIN_MAPPINGS` | ✅ Yes | - | Domain to subdomain mappings |
| `AUTO_CREATE_DNS_RECORDS` | ❌ No | `false` | Auto-create missing DNS records |

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
    -e CLOUDFLARE_DOMAIN_MAPPINGS="example.com:www,api" \
    -e AUTO_CREATE_DNS_RECORDS="true" \
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
      - CLOUDFLARE_DOMAIN_MAPPINGS=example.com:www,api
      - AUTO_CREATE_DNS_RECORDS=true
```

## 🔧 Troubleshooting

### Common Issues

**❌ "DNS record not found"**
- Enable `AUTO_CREATE_DNS_RECORDS=true` to create missing records automatically
- Or manually create A records in Cloudflare dashboard

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

## 🛣️ Roadmap

- [ ] Web dashboard for monitoring
- [ ] Webhook notifications
- [ ] Support for other DNS providers
- [ ] IPv6 support
- [ ] Health check endpoint

## 🤝 Contributing

We welcome contributions! Please feel free to:
- Report bugs
- Suggest features
- Submit pull requests
- Improve documentation

## 📄 License

This project is open source. Feel free to use it for personal and commercial projects.

---

## 🇲🇽 Support Our Mission (Mexico Only)

If you love open source and want to support our work, consider joining our developer-focused mobile service in Mexico: [defdo community](https://shop.defdo.dev/?dcode=defdo_ddns&scode=github). Help us grow while getting great mobile service!

