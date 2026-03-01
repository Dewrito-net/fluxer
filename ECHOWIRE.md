# Dewrito

Self-hosted [Fluxer](https://github.com/fluxerapp/fluxer) deployment at **https://dewrito.net**.

## Architecture

```
Users → Cloudflare CDN → Vultr VPS (Caddy edge proxy)
                              ↓ NetBird mesh VPN
                         NC VM (primary backend)
                              ↓ ScyllaDB replication
                         MI VM (secondary/standby)
```

### Infrastructure

| Site | Host | NetBird IP | Specs | Role |
|------|------|-----------|-------|------|
| **Vultr VPS** | 108.61.203.190 | 100.70.229.86 | 1 vCPU, 3.8GB RAM | Edge proxy (Caddy) + NetBird mgmt |
| **NC VM** (Proxmox) | 10.9.50.30 | 100.70.10.204 | 4 vCPU, 8GB RAM, 60GB | Primary — all services |
| **MI VM** (Proxmox) | 10.77.77.200 | 100.70.49.120 | 4 vCPU, 4GB RAM, 60GB | Secondary — Cassandra replica + standby |

### Voice Servers (5 dedicated Vultr VPS)

| Label | Region | IP | Domain |
|-------|--------|-----|--------|
| voice-ewr | New Jersey | 45.77.98.230 | voice-ewr.dewrito.net |
| voice-atl | Atlanta | 96.30.205.1 | voice-atl.dewrito.net |
| voice-ord | Chicago | 104.207.138.140 | voice-ord.dewrito.net |
| voice-lax | Los Angeles | 45.76.170.23 | voice-lax.dewrito.net |
| voice-dfw | Dallas | 216.128.143.25 | voice-dfw.dewrito.net |

Each runs: Docker (LiveKit + Redis) + Caddy (host, auto-TLS)
UFW ports: 22, 80, 443, 7881/tcp, 7882/udp
DNS: grey cloud (DNS only, no proxy — LiveKit needs direct UDP)

## Services (NC VM)

All services run via Docker Compose at `/opt/Dewrito/compose.yaml`:

| Service | Image | Purpose |
|---------|-------|---------|
| fluxer_server | fluxer-server:latest | Monolith: API + Gateway + App Proxy |
| cassandra | scylladb/scylla:latest | Primary database (datacenter1) |
| valkey | valkey/valkey:8.0.6-alpine | KV store / cache |
| nats | nats:2.11-alpine | Gateway↔API RPC + JetStream |
| meilisearch | getmeili/meilisearch:v1.14 | Full-text search |

### MI VM (Secondary)

Runs ScyllaDB replica (datacenter2) + Valkey replica. Standby services (NATS, Meilisearch, fluxer_server) defined with `profiles: ['active']` — activate with:

```bash
docker compose --profile active up -d
```

## Config System

The refactor branch uses a JSON config file loaded via `FLUXER_CONFIG` env var:

- **NC VM config**: `/opt/Dewrito/config.json` (local_dc: datacenter1)
- **MI VM config**: `/opt/Dewrito/config.json` (local_dc: datacenter2)
- **Schema**: Zod validation in `packages/config/`
- **Env overrides**: `FLUXER_CONFIG__path__to__key` pattern

## Networking

### NetBird Mesh VPN (Self-Hosted)

- **Management UI**: https://nb.dewrito.net
- **Deployed at**: `/opt/netbird/` on Vultr
- **All 4 nodes connected**: Vultr, NC VM, MI VM, local workstation

### Proxmox Access

- **NC PVE**: https://10.9.50.10:8006
- **MI PVE**: https://10.77.77.74:8006

### SSH Access

```bash
# NC VM (via Proxmox jump host)
ssh -J root@10.9.50.10 root@10.9.50.30

# MI VM (direct, or via NetBird)
sshpass -p '' ssh root@100.70.49.120

# Vultr VPS
ssh root@108.61.203.190

# Voice servers
ssh root@45.77.98.230   # voice-ewr
ssh root@96.30.205.1    # voice-atl
ssh root@104.207.138.140 # voice-ord
ssh root@45.76.170.23   # voice-lax
ssh root@216.128.143.25  # voice-dfw
```

## External Services

| Service | Details |
|---------|---------|
| **Domain** | dewrito.net (Cloudflare CDN → Caddy auto-TLS) |
| **Storage** | Cloudflare R2 — 6 buckets (fluxer, fluxer-uploads, fluxer-downloads, fluxer-reports, fluxer-harvests, fluxer-static) |
| **CDN** | R2 public URL: `https://pub-01ca5f8f442643b18e2a4a79fb29f911.r2.dev` |
| **Email** | smtp2go — mail.smtp2go.com:2525 |
| **GIFs** | Klipy API (replaced Tenor) |
| **Payments** | Stripe — Freemium model (Monthly $5, Yearly $48, Visionary $256) |
| **Admin** | https://dewrito.net/admin (Gleam app, OAuth2) |

## Dewrito Customizations (vs upstream Fluxer)

These changes are committed on the `Dewrito-refactor` branch on top of upstream's `refactor` branch:

### Already handled by refactor branch (no patches needed)
- Email provider abstraction (SMTP built-in via config)
- CDN endpoint configurable via `CDN_ENDPOINT` env var
- Beta code removed from registration
- Premium modal checks `stripe_enabled` flag
- Download URLs use relative `/download` path
- "Join Fluxer HQ" nagbar hidden when `isSelfHosted`
- SendGrid webhooks removed

### Our patches (committed)
- **Branding**: All logos/icons replaced with Dewrito waveform
- **index.html**: Title, description, favicons, theme color (#3B82F6)
- **manifest.json**: Generated with Dewrito name + theme
- **Desktop icons**: All sizes replaced (icons-stable/)
- **STABLE_APP_URL**: Points to https://dewrito.net
- **Dockerfile**: Fixed for refactor branch (new packages, WASM build, lingui)
- **Stripe routes**: Gated by `Config.stripe.enabled`

### Files changed from upstream

| File | Change |
|------|--------|
| `.dockerignore` | Fixed exclusions for build |
| `compose.yaml` | Per-site deployment config |
| `fluxer_app/index.html` | Dewrito title, favicon, theme |
| `fluxer_app/rspack.config.mjs` | CDN_ENDPOINT env var |
| `fluxer_app/scripts/build/rspack/static-files.mjs` | Dewrito manifest + browserconfig |
| `fluxer_app/src/components/icons/FluxerIcon.tsx` | Dewrito waveform SVG |
| `fluxer_app/src/images/fluxer-logo-*.svg` | Dewrito logos (3 files) |
| `fluxer_desktop/build_resources/icons-stable/*` | Dewrito icons (25 files) |
| `fluxer_desktop/src/common/Constants.tsx` | STABLE_APP_URL |
| `fluxer_server/Dockerfile` | Build fixes for refactor |
| `packages/api/src/app/ControllerRegistry.tsx` | Stripe route gating |
| `packages/api/src/middleware/ServiceMiddleware.tsx` | Stripe middleware gating |

## Git Workflow

### Remotes

```
origin   = https://github.com/fluxerapp/fluxer.git   (upstream)
Dewrito = gitea.proudtech.net/cproudlock/Dewrito    (our fork)
```

### Pulling upstream changes

```bash
cd ~/projects/voip/fluxer

# Fetch latest from upstream
git fetch origin

# Rebase our customizations on top
git rebase origin/refactor

# Resolve conflicts if any, then push to Gitea
git push Dewrito Dewrito-refactor:main
```

### Deploying to production

```bash
# 1. Build Docker image (from workstation)
cd ~/projects/voip/fluxer
FLUXER_CONFIG=config/config.json docker build \
  --build-arg INCLUDE_NSFW_ML=true \
  -f fluxer_server/Dockerfile \
  -t fluxer-server:latest .

# 2. Export and transfer to NC VM
docker save fluxer-server:latest | gzip > /tmp/fluxer-server.tar.gz
sshpass -p '' scp /tmp/fluxer-server.tar.gz root@100.70.10.204:/tmp/

# 3. Load and restart on NC VM
sshpass -p '' ssh root@100.70.10.204 \
  "docker load < /tmp/fluxer-server.tar.gz && \
   cd /opt/Dewrito && \
   docker compose up -d && \
   sleep 5 && \
   docker compose restart gateway"

# Note: Gateway MUST be restarted after API recreate (Erlang RPC doesn't auto-reconnect)

# 4. Verify
curl -s https://dewrito.net/_health | python3 -m json.tool
```

### Updating MI VM standby

```bash
# Transfer same image to MI VM
sshpass -p '' ssh root@100.70.10.204 \
  "cat /tmp/fluxer-server.tar.gz" | \
  sshpass -p '' ssh root@100.70.49.120 \
  "cat > /tmp/fluxer-server.tar.gz && docker load < /tmp/fluxer-server.tar.gz"
```

## Desktop App

- **Build dir**: `~/projects/voip/fluxer/fluxer_desktop/`
- **Current version**: v1.6.0
- **Build**: `npx electron-builder --config electron-builder.config.cjs --win --x64` (Windows via Wine), `--linux --x64` (Linux)
- **Auto-updater**: `latest.yml` + `latest-linux.yml` on R2 at `s3://fluxer-downloads/desktop/stable/`
- **Download page**: `https://dewrito.net/download`

## Android App

- **Project**: `~/projects/voip/Dewrito-android/`
- **Current version**: v1.0.4 (native WebView, not TWA)
- **Build**: `ANDROID_HOME=~/android-sdk ./gradlew assembleRelease --no-daemon`
- **APK on R2**: `s3://fluxer-downloads/android/`

## Secrets

All secrets are stored in `secrets.env` (gitignored, never committed). See that file for:
- Infrastructure access (Vultr, Proxmox, VMs)
- Cloudflare API tokens
- NetBird mesh VPN keys
- Application secrets (NATS, Meilisearch, media proxy, admin, gateway, auth)
- Stripe keys + price IDs
- SMTP credentials
- LiveKit API keys (global + per-server)
- Klipy API key
- Gitea credentials
- Android keystore credentials

## Gotchas

- `docker compose restart` does NOT reload env/config — use `up -d` to recreate
- **ALWAYS restart gateway after recreating API** — Erlang RPC doesn't auto-reconnect
- **ALWAYS restart Caddy after rebuilding frontend** — rspack recreates dist/, Docker bind mount goes stale
- **ALWAYS bump version number** when rebuilding desktop/mobile apps
- Voice DNS must be grey cloud (DNS only) — LiveKit needs direct UDP for WebRTC
- `pnpm exec rspack build` not `npx rspack` (pnpm compatibility)
- ScyllaDB requires CPU with PCLMUL support — use `host` CPU type in Proxmox
- LFS budget exceeded — badge SVGs must be downloaded from fluxerstatic.com CDN manually
- Reusing same version number with different sha512 causes auto-updater to reject the update
- R2 auto-updater files must exist at BOTH `desktop/stable/` (for updater) AND `desktop/stable/{platform}/x64/` (for download page)
