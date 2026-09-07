# cloudflare-tunnel-iac: ngrok-style helpers around a terraform-managed cloudflared tunnel.
# Requires: CFT_DIR set to this repo's path, terraform, jq, cloudflared, CLOUDFLARE_API_TOKEN in env.

_cft_check_deps() {
  if [ -z "$CFT_DIR" ]; then
    echo "CFT_DIR is not set (export CFT_DIR=/path/to/cloudflare-tunnel-iac)" >&2
    return 1
  fi
  for bin in terraform jq cloudflared curl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin" >&2; return 1; }
  done
}

# Fast local pre-check: ask Cloudflare directly whether <sub>.<domain>
# already exists and points somewhere other than our own tunnel (e.g. the
# selfhosted-server tunnel). This is best-effort only -- it can't see
# pre-emptive reservations that don't have a DNS record yet, or run before
# the first `terraform apply` (no outputs to read yet). The real hard stop
# is main.tf's lifecycle.precondition, which always runs before any API call
# that could touch a record.
_cft_is_reserved() {
  local sub="$1"
  local zone_id domain tunnel_id
  zone_id=$(cd "$CFT_DIR" && terraform output -raw zone_id 2>/dev/null)
  domain=$(cd "$CFT_DIR" && terraform output -raw domain 2>/dev/null)
  tunnel_id=$(cd "$CFT_DIR" && terraform output -raw tunnel_id 2>/dev/null)
  [ -z "$zone_id" ] || [ -z "$domain" ] || [ -z "$tunnel_id" ] && return 1

  local content
  content=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${sub}.${domain}" \
    | jq -r '.result[0].content // empty')
  [ -n "$content" ] && [ "$content" != "${tunnel_id}.cfargotunnel.com" ]
}

_cft_apply() {
  (cd "$CFT_DIR" && terraform apply -auto-approve -input=false)
}

_cft_ensure_daemon() {
  local pidfile="$CFT_DIR/.cloudflared.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi
  local tunnel_id
  tunnel_id=$(cd "$CFT_DIR" && terraform output -raw tunnel_id 2>/dev/null)
  if [ -z "$tunnel_id" ]; then
    echo "could not read tunnel_id from terraform output" >&2
    return 1
  fi
  # No local <uuid>.json credentials file is required: fetch a connector
  # token on the fly (cert.pem from `cloudflared tunnel login` must already
  # be present and own this tunnel).
  local token
  token=$(cloudflared tunnel token "$tunnel_id" 2>/dev/null)
  if [ -z "$token" ]; then
    echo "could not fetch token for tunnel $tunnel_id (run: cloudflared tunnel login)" >&2
    return 1
  fi
  nohup cloudflared tunnel run --token "$token" > "$CFT_DIR/cloudflared.log" 2>&1 &
  echo $! > "$pidfile"
  sleep 2
}

cft-help() {
  cat <<'EOF'
cft <port> [subdomain]   Expose localhost:<port> at https://<subdomain>.<domain>
                         (default subdomain: dev). Writes routes.json, runs
                         terraform apply, starts the cloudflared daemon if needed.
cft-list                 Show all currently configured subdomain -> port routes.
cft-rm <subdomain>       Remove a route and apply the change.
cft-stop                 Kill the background cloudflared daemon.
cft-help                 Show this message.
EOF
}

cft() {
  _cft_check_deps || return 1
  local port="$1"
  local sub="${2:-dev}"
  if [ -z "$port" ]; then
    echo "usage: cft <port> [subdomain]   -- expose localhost:<port> at https://<subdomain>.<domain> (run 'cft-help' for all commands)" >&2
    return 1
  fi
  if _cft_is_reserved "$sub"; then
    echo "refusing: '$sub' is reserved for the other (selfhosted-server) tunnel on this zone" >&2
    return 1
  fi

  jq --arg sub "$sub" --argjson port "$port" '.routes[$sub] = $port' \
    "$CFT_DIR/routes.json" > "$CFT_DIR/routes.json.tmp" \
    && mv "$CFT_DIR/routes.json.tmp" "$CFT_DIR/routes.json"

  _cft_apply || return 1
  _cft_ensure_daemon || return 1

  local domain
  domain=$(cd "$CFT_DIR" && terraform output -raw domain 2>/dev/null)
  echo "https://${sub}.${domain} -> localhost:${port}"
}

cft-list() {
  _cft_check_deps || return 1
  jq -r '.routes | to_entries[] | "\(.key) -> localhost:\(.value)"' "$CFT_DIR/routes.json"
}

cft-rm() {
  _cft_check_deps || return 1
  local sub="$1"
  if [ -z "$sub" ]; then
    echo "usage: cft-rm <subdomain>   -- remove that route and apply the change" >&2
    return 1
  fi

  jq --arg sub "$sub" 'del(.routes[$sub])' \
    "$CFT_DIR/routes.json" > "$CFT_DIR/routes.json.tmp" \
    && mv "$CFT_DIR/routes.json.tmp" "$CFT_DIR/routes.json"

  _cft_apply
}

cft-stop() {
  local pidfile="$CFT_DIR/.cloudflared.pid"
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null
    rm -f "$pidfile"
    echo "tunnel daemon stopped"
  else
    echo "no running daemon tracked"
  fi
}

echo "cft tunnel helpers loaded (cft, cft-list, cft-rm, cft-stop) — run 'cft-help' for details"
