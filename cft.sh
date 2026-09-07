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

# --- request inspector / basic auth (mitmproxy reverse proxy) -----------
#
# routes.json always holds the port cloudflared's ingress forwards to. When
# --inspect and/or --auth is used, that's this local mitmproxy instance's
# listen port, not the app's real port -- it sits in between (plain
# http -> http, no TLS/certs involved since Cloudflare already terminated
# HTTPS at the edge), optionally showing a browser UI with full
# request/response bodies (--inspect, via mitmweb) and/or enforcing HTTP
# Basic Auth before forwarding (--auth, via mitm_basic_auth.py). mitm.json
# tracks, per subdomain, the real port + this process's ports/pid/params so
# cft-list/cft-rm/cft can find and tear it down again.
_cft_mitm_file() { echo "$CFT_DIR/mitm.json"; }

_cft_mitm_init() {
  [ -f "$(_cft_mitm_file)" ] || echo '{}' > "$(_cft_mitm_file)"
}

_cft_mitm_entry() {
  local sub="$1"
  _cft_mitm_init
  jq -r --arg s "$sub" '.[$s] // empty' "$(_cft_mitm_file)"
}

_cft_stop_mitm() {
  local sub="$1"
  local entry pid
  entry=$(_cft_mitm_entry "$sub")
  [ -z "$entry" ] && return 0
  pid=$(echo "$entry" | jq -r '.pid')
  kill "$pid" 2>/dev/null
  jq --arg s "$sub" 'del(.[$s])' "$(_cft_mitm_file)" > "$(_cft_mitm_file).tmp" \
    && mv "$(_cft_mitm_file).tmp" "$(_cft_mitm_file)"
}

# Sets _CFT_MITM_ROUTE_PORT (the port to put in routes.json) and
# _CFT_MITM_WEB_URL (printed to the user, empty if not --inspect) on
# success. inspect is 0/1, auth is "" or "user:pass".
_cft_start_proxy() {
  local sub="$1" port="$2" inspect="$3" auth="$4"

  if [ "$inspect" -ne 1 ] && [ -z "$auth" ]; then
    _cft_stop_mitm "$sub"
    _CFT_MITM_ROUTE_PORT=$port
    _CFT_MITM_WEB_URL=""
    return 0
  fi

  local bin=mitmdump
  [ "$inspect" -eq 1 ] && bin=mitmweb
  command -v "$bin" >/dev/null 2>&1 || { echo "missing dependency: $bin (brew install mitmproxy)" >&2; return 1; }

  local authuser="" authpass=""
  if [ -n "$auth" ]; then
    authuser="${auth%%:*}"
    authpass="${auth#*:}"
    if [ "$authuser" = "$auth" ] || [ -z "$authpass" ]; then
      echo "usage: --auth user:pass" >&2
      return 1
    fi
  fi

  local entry existing_pid existing_port existing_inspect existing_auth
  entry=$(_cft_mitm_entry "$sub")
  if [ -n "$entry" ]; then
    existing_pid=$(echo "$entry" | jq -r '.pid')
    existing_port=$(echo "$entry" | jq -r '.port')
    existing_inspect=$(echo "$entry" | jq -r '.inspect')
    existing_auth=$(echo "$entry" | jq -r '.auth')
    if [ "$existing_port" = "$port" ] && [ "$existing_inspect" = "$inspect" ] \
       && [ "$existing_auth" = "$auth" ] && kill -0 "$existing_pid" 2>/dev/null; then
      _CFT_MITM_ROUTE_PORT=$(echo "$entry" | jq -r '.proxy_port')
      _CFT_MITM_WEB_URL=""
      [ "$inspect" -eq 1 ] && _CFT_MITM_WEB_URL="http://localhost:$(echo "$entry" | jq -r '.web_port') (password: $(echo "$entry" | jq -r '.password'))"
      return 0
    fi
    _cft_stop_mitm "$sub"
  fi

  local proxy_port=$((port + 10000))
  local web_port=0
  local password=""
  local -a cmd=("$bin" --mode "reverse:http://localhost:${port}" --listen-port "$proxy_port")

  if [ "$inspect" -eq 1 ]; then
    web_port=$((port + 10500))
    password=$(openssl rand -hex 8 2>/dev/null || echo "cft-$RANDOM")
    cmd+=(--web-port "$web_port" --set web_open_browser=false --set "web_password=${password}")
  fi
  [ -n "$auth" ] && cmd+=(-s "$CFT_DIR/mitm_basic_auth.py")

  CFT_BASIC_AUTH_USER="$authuser" CFT_BASIC_AUTH_PASS="$authpass" \
    nohup "${cmd[@]}" > "$CFT_DIR/mitm-${sub}.log" 2>&1 &
  local pid=$!
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "$bin failed to start, see $CFT_DIR/mitm-${sub}.log" >&2
    return 1
  fi

  jq --arg s "$sub" --argjson port "$port" --argjson proxy_port "$proxy_port" \
     --argjson web_port "$web_port" --arg password "$password" --argjson pid "$pid" \
     --argjson inspect "$inspect" --arg auth "$auth" \
     '.[$s] = {port: $port, proxy_port: $proxy_port, web_port: $web_port, password: $password, pid: $pid, inspect: $inspect, auth: $auth}' \
     "$(_cft_mitm_file)" > "$(_cft_mitm_file).tmp" && mv "$(_cft_mitm_file).tmp" "$(_cft_mitm_file)"

  _CFT_MITM_ROUTE_PORT=$proxy_port
  _CFT_MITM_WEB_URL=""
  [ "$inspect" -eq 1 ] && _CFT_MITM_WEB_URL="http://localhost:${web_port} (password: ${password})"
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
cft <port> [subdomain] [--inspect] [--auth user:pass]
                         Expose localhost:<port> at https://<subdomain>.<domain>
                         (default subdomain: dev). Writes routes.json, runs
                         terraform apply, starts the cloudflared daemon if needed.
                         --inspect puts a local mitmweb reverse proxy in
                         between so you can see every request/response (incl.
                         body) in a browser UI -- like ngrok's inspector.
                         --auth user:pass requires that HTTP Basic Auth on
                         every request before it reaches your app -- combine
                         both to inspect AND password-protect at once.
cft-list                 Show all currently configured subdomain -> port routes
                         (with tags for any that are --inspect'd / --auth'd).
cft-rm <subdomain>       Remove a route (and its proxy, if any) and apply.
cft-stop                 Kill the background cloudflared daemon and any
                         running inspect/auth proxies.
cft-help                 Show this message.
EOF
}

cft() {
  _cft_check_deps || return 1
  local port="$1"
  if [ -z "$port" ]; then
    echo "usage: cft <port> [subdomain] [--inspect] [--auth user:pass]   -- (run 'cft-help' for details)" >&2
    return 1
  fi
  shift

  local sub="dev"
  local inspect=0
  local auth=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --inspect) inspect=1; shift ;;
      --auth) auth="$2"; shift 2 ;;
      --auth=*) auth="${1#--auth=}"; shift ;;
      *) sub="$1"; shift ;;
    esac
  done

  if _cft_is_reserved "$sub"; then
    echo "refusing: '$sub' is reserved for the other (selfhosted-server) tunnel on this zone" >&2
    return 1
  fi

  _cft_start_proxy "$sub" "$port" "$inspect" "$auth" || return 1
  local route_port=$_CFT_MITM_ROUTE_PORT

  jq --arg sub "$sub" --argjson port "$route_port" '.routes[$sub] = $port' \
    "$CFT_DIR/routes.json" > "$CFT_DIR/routes.json.tmp" \
    && mv "$CFT_DIR/routes.json.tmp" "$CFT_DIR/routes.json"

  _cft_apply || return 1
  _cft_ensure_daemon || return 1

  local domain
  domain=$(cd "$CFT_DIR" && terraform output -raw domain 2>/dev/null)
  echo "https://${sub}.${domain} -> localhost:${port}"
  [ -n "$_CFT_MITM_WEB_URL" ] && echo "inspector: $_CFT_MITM_WEB_URL"
  [ -n "$auth" ] && echo "basic auth enabled (user: ${auth%%:*})"
}

cft-list() {
  _cft_check_deps || return 1
  _cft_mitm_init
  local sub route_port entry real_port web_port inspect auth tags
  jq -r '.routes | keys[]' "$CFT_DIR/routes.json" | while IFS= read -r sub; do
    route_port=$(jq -r --arg s "$sub" '.routes[$s]' "$CFT_DIR/routes.json")
    entry=$(_cft_mitm_entry "$sub")
    if [ -n "$entry" ]; then
      real_port=$(echo "$entry" | jq -r '.port')
      inspect=$(echo "$entry" | jq -r '.inspect')
      auth=$(echo "$entry" | jq -r '.auth')
      tags=""
      if [ "$inspect" = "1" ]; then
        web_port=$(echo "$entry" | jq -r '.web_port')
        tags="$tags [inspecting @ http://localhost:$web_port]"
      fi
      [ -n "$auth" ] && tags="$tags [auth: ${auth%%:*}]"
      echo "$sub -> localhost:$real_port $tags"
    else
      echo "$sub -> localhost:$route_port"
    fi
  done
}

cft-rm() {
  _cft_check_deps || return 1
  local sub="$1"
  if [ -z "$sub" ]; then
    echo "usage: cft-rm <subdomain>   -- remove that route and apply the change" >&2
    return 1
  fi

  _cft_stop_mitm "$sub"

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

  _cft_mitm_init
  local sub
  jq -r 'keys[]' "$(_cft_mitm_file)" | while IFS= read -r sub; do
    _cft_stop_mitm "$sub"
    echo "inspector for '$sub' stopped"
  done
}

echo "cft tunnel helpers loaded (cft, cft-list, cft-rm, cft-stop) — run 'cft-help' for details"
