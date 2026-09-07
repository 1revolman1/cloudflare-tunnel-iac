# cloudflare-tunnel-iac

Ngrok-style local dev tunnels on top of a real Cloudflare Tunnel: `cft <port> [subdomain]`
writes the desired port mapping to `routes.json`, runs `terraform apply` to update DNS +
tunnel ingress config, and makes sure `cloudflared` is running — one command, no dashboard
clicking.

```
cft 3000 app
# -> https://app.<your-domain> is now live, forwarding to localhost:3000
```

## How it works

- `routes.json` is the single source of truth for `{ subdomain: port }` mappings.
- Terraform (`main.tf`) reads it and, per subdomain, creates a `cloudflare_dns_record`
  (CNAME to the tunnel) and pushes an ingress rule into the tunnel's remote-managed
  config (`cloudflare_zero_trust_tunnel_cloudflared_config`). There's no local
  `config.yml` — `cloudflared` pulls ingress rules from Cloudflare's edge.
- `cft.sh` is a thin wrapper: it edits `routes.json`, runs `terraform apply`, and starts
  `cloudflared tunnel run --token ...` in the background if it isn't already running. The
  connector token is fetched on demand via `cloudflared tunnel token <id>` — no local
  `<uuid>.json` credentials file needed, only `~/.cloudflared/cert.pem` from a one-time
  `cloudflared tunnel login`.
- **Safety guard**: this project shares its Cloudflare zone with another, independently
  managed tunnel. Before touching any subdomain, both `cft.sh` (a live API check) and
  Terraform (`lifecycle.precondition` in `main.tf`) refuse to create/update a DNS record
  that already exists and points somewhere other than *this* tunnel. The reserved list is
  auto-detected from the zone's live DNS records — nothing to maintain by hand. See
  `variables.tf`'s `reserved_subdomains` if you ever need to pre-reserve a name that
  doesn't have a DNS record yet.

## Prerequisites

- macOS with Homebrew, zsh
- `terraform` (`brew install hashicorp/tap/terraform` — HashiCorp pulled it from
  homebrew-core, use their own tap)
- `jq`, `cloudflared` (`brew install jq cloudflared`)
- `cloudflared tunnel login` already run once (creates `~/.cloudflared/cert.pem`)
- An existing Cloudflare Tunnel (`cloudflared tunnel create <name>`) — this project
  manages DNS + ingress for it, not the tunnel resource itself
- A Cloudflare API token with:
  - `Zone / DNS / Edit` — scoped to your specific zone
  - `Account / Cloudflare Tunnel / Edit` — scoped to your account
  (each must be its own policy row scoped to the matching resource type — an
  account-scoped resource does not grant zone-scoped permission groups, even if the
  permission group is in the same token)

## Setup

```bash
git clone <this-repo> ~/cloudflare-tunnel-iac
cd ~/cloudflare-tunnel-iac
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: account_id, zone_id, tunnel_id, domain

export CLOUDFLARE_API_TOKEN="..."
terraform init
terraform apply   # safe to run with an empty routes.json — just sets up tunnel config
```

Add to `~/.zshrc`:

```bash
export CFT_DIR="$HOME/cloudflare-tunnel-iac"
export CLOUDFLARE_API_TOKEN="..."
source "$CFT_DIR/cft.sh"
```

```bash
source ~/.zshrc
```

## Usage

```bash
cft <port> [subdomain]   # expose localhost:<port>, default subdomain "dev"
cft-list                 # show current routes
cft-rm <subdomain>       # remove a route
cft-stop                 # stop the background cloudflared daemon
cft-help                 # show all commands
```

## Files

| File | Purpose |
|---|---|
| `main.tf` | DNS record + tunnel ingress config, reserved-subdomain guard |
| `variables.tf` | `account_id`, `zone_id`, `tunnel_id`, `domain`, `reserved_subdomains` |
| `outputs.tf` | `domain`, `tunnel_id`, `zone_id`, `urls` (read by `cft.sh`) |
| `routes.json` | `{ "routes": { "subdomain": port } }` — the only file `cft` writes |
| `cft.sh` | shell functions: `cft`, `cft-list`, `cft-rm`, `cft-stop`, `cft-help` |
| `terraform.tfvars.example` | template — copy to `terraform.tfvars` (gitignored) and fill in |

`terraform.tfvars`, `*.tfstate*`, `.terraform/`, `.cloudflared.pid` and `cloudflared.log`
are gitignored — never commit those. `terraform.tfvars.example`, `.terraform.lock.hcl`,
and `routes.json` are safe to commit (no secrets).
