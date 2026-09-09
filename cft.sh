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
# already exists, in one API call. Sets:
#   _CFT_DNS_RESERVED=1   record exists and points elsewhere (e.g. the
#                         selfhosted-server tunnel) -- caller must refuse.
#   _CFT_DNS_RECORD_ID    non-empty if a record exists and already points at
#                         OUR tunnel -- it can be imported instead of
#                         recreated (see _cft_adopt_existing_dns).
#   _CFT_DNS_ZONE_ID      zone_id, cached for the importer to reuse.
# Best-effort only -- can't see pre-emptive reservations that don't have a
# DNS record yet, or run before the first `terraform apply` (no outputs to
# read yet). The real hard stop for reserved names is main.tf's
# lifecycle.precondition, which always runs before any API call that could
# touch a record.
_cft_check_existing_dns() {
  local sub="$1"
  _CFT_DNS_RESERVED=0
  _CFT_DNS_RECORD_ID=""
  _CFT_DNS_ZONE_ID=$(cd "$CFT_DIR" && terraform output -raw zone_id 2>/dev/null)
  local domain tunnel_id
  domain=$(cd "$CFT_DIR" && terraform output -raw domain 2>/dev/null)
  tunnel_id=$(cd "$CFT_DIR" && terraform output -raw tunnel_id 2>/dev/null)
  [ -z "$_CFT_DNS_ZONE_ID" ] || [ -z "$domain" ] || [ -z "$tunnel_id" ] && return 0

  local content id
  IFS=$'\t' read -r content id < <(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${_CFT_DNS_ZONE_ID}/dns_records?name=${sub}.${domain}" \
    | jq -r '[(.result[0].content // ""), (.result[0].id // "")] | @tsv')

  [ -z "$id" ] && return 0
  if [ "$content" = "${tunnel_id}.cfargotunnel.com" ]; then
    _CFT_DNS_RECORD_ID="$id"
  else
    _CFT_DNS_RESERVED=1
  fi
}

# If _cft_check_existing_dns found a record already pointing at our tunnel,
# adopt it into terraform state instead of letting `apply` try (and fail)
# to create a duplicate. No-op if it's already tracked or none was found.
_cft_adopt_existing_dns() {
  local sub="$1"
  [ -z "$_CFT_DNS_RECORD_ID" ] && return 0
  local addr="cloudflare_dns_record.tunnel[\"$sub\"]"
  (cd "$CFT_DIR" && terraform state list 2>/dev/null | grep -qF "$addr") && return 0
  echo "found existing DNS record for '$sub' pointing at this tunnel -- adopting it" >&2
  (cd "$CFT_DIR" && terraform import "$addr" "${_CFT_DNS_ZONE_ID}/${_CFT_DNS_RECORD_ID}" >/dev/null 2>&1)
}

_cft_apply() {
  (cd "$CFT_DIR" && terraform apply -auto-approve -input=false)
}

# Apply a jq filter to a JSON file in place: read -> filter -> atomic replace.
# Extra args (e.g. --arg/--argjson) are passed straight through to jq.
_cft_json_update() {
  local file="$1" filter="$2"
  shift 2
  jq "$@" "$filter" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
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
# cft-list/cft-rm/cft can find and tear it down again. Entries written before
# --auth existed have no .inspect/.auth keys -- _cft_mitm_entry normalizes
# those to 0/"" so every reader sees old entries as "no proxy" consistently.
_cft_mitm_init() {
  [ -f "$CFT_DIR/mitm.json" ] || echo '{}' > "$CFT_DIR/mitm.json"
}

# Returns the entry with .pid/.inspect/.auth/.web_port/.password normalized
# to ""/0/""/0/"" when absent, so no caller needs its own fallback for
# entries written before --auth existed (or a hypothetical corrupt entry).
_cft_mitm_entry() {
  local sub="$1"
  _cft_mitm_init
  jq -r --arg s "$sub" \
    '.[$s] // empty | (.pid //= "" | .inspect //= 0 | .auth //= "" | .web_port //= 0 | .password //= "")' \
    "$CFT_DIR/mitm.json"
}

# The one place that knows how to kill a tracked proxy's process, given a
# pid a caller already has on hand (avoids re-reading mitm.json just to
# look the pid up again).
_cft_kill_pid() {
  local pid="$1"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
}

# Kills and removes one mitm.json entry. Pass a known pid (e.g. one a
# caller already extracted via _cft_mitm_entry) to skip re-reading the file.
_cft_stop_mitm() {
  local sub="$1" pid="${2:-}"
  if [ -z "$pid" ]; then
    local entry
    entry=$(_cft_mitm_entry "$sub")
    [ -z "$entry" ] && return 0
    pid=$(jq -r '.pid' <<<"$entry")
  fi
  _cft_kill_pid "$pid"
  _cft_json_update "$CFT_DIR/mitm.json" 'del(.[$s])' --arg s "$sub"
}

# Builds the bare inspector URL/password string (the caller adds the
# "inspector: " label), empty when not inspecting.
_cft_web_url() {
  local inspect="$1" web_port="$2" password="$3"
  [ "$inspect" = "1" ] && echo "http://localhost:${web_port} (password: ${password})"
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
    if [ "$authuser" = "$auth" ] || [ -z "$authuser" ] || [ -z "$authpass" ]; then
      echo "usage: --auth user:pass" >&2
      return 1
    fi
  fi

  local entry
  entry=$(_cft_mitm_entry "$sub")
  if [ -n "$entry" ]; then
    local existing_pid existing_port existing_inspect existing_auth existing_proxy_port existing_web_port existing_password
    IFS=$'\t' read -r existing_pid existing_port existing_inspect existing_auth existing_proxy_port existing_web_port existing_password \
      < <(jq -r '[.pid, .port, .inspect, .auth, .proxy_port, .web_port, .password] | @tsv' <<<"$entry")
    if [ "$existing_port" = "$port" ] && [ "$existing_inspect" = "$inspect" ] \
       && [ "$existing_auth" = "$auth" ] && kill -0 "$existing_pid" 2>/dev/null; then
      _CFT_MITM_ROUTE_PORT=$existing_proxy_port
      _CFT_MITM_WEB_URL=$(_cft_web_url "$inspect" "$existing_web_port" "$existing_password")
      return 0
    fi
    _cft_stop_mitm "$sub" "$existing_pid"
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

  _cft_json_update "$CFT_DIR/mitm.json" \
    '.[$s] = {port: $port, proxy_port: $proxy_port, web_port: $web_port, password: $password, pid: $pid, inspect: $inspect, auth: $auth}' \
    --arg s "$sub" --argjson port "$port" --argjson proxy_port "$proxy_port" \
    --argjson web_port "$web_port" --arg password "$password" --argjson pid "$pid" \
    --argjson inspect "$inspect" --arg auth "$auth"

  _CFT_MITM_ROUTE_PORT=$proxy_port
  _CFT_MITM_WEB_URL=$(_cft_web_url "$inspect" "$web_port" "$password")
}

# Detects the tunnel daemon dying unexpectedly (crash, or the machine got
# rebooted) as opposed to a deliberate `cft-stop` (which removes the pidfile
# itself) -- only in that unexpected case does it tear down the now-dead
# routes' DNS records, so they don't linger pointing at a tunnel nobody is
# running. A deliberately-stopped daemon leaves routes.json untouched, same
# as before, so `cft-stop` then `cft <port> <sub>` still just resumes it.
# Cheap (one local `kill -0`, no network) whenever the daemon is fine or was
# never started -- the network-touching teardown only runs in the rare case
# it's actually needed.
_cft_reconcile_stale_daemon() {
  local pidfile="$CFT_DIR/.cloudflared.pid"
  [ -f "$pidfile" ] || return 0
  kill -0 "$(cat "$pidfile")" 2>/dev/null && return 0

  local n
  n=$(jq -r '.routes | length' "$CFT_DIR/routes.json" 2>/dev/null)
  if [ -z "$n" ] || [ "$n" = "0" ]; then
    rm -f "$pidfile"
    return 0
  fi

  echo "cft: tunnel daemon died unexpectedly (crash or reboot) -- tearing down $n stale route(s)" >&2
  echo '{"routes": {}}' > "$CFT_DIR/routes.json"
  _cft_apply >/dev/null 2>&1
  echo '{}' > "$CFT_DIR/mitm.json" 2>/dev/null
  rm -f "$pidfile"
  echo "cft: done -- run 'cft <port> [subdomain]' to bring routes back up" >&2
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
  _cft_reconcile_stale_daemon
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

  _cft_check_existing_dns "$sub"
  if [ "$_CFT_DNS_RESERVED" -eq 1 ]; then
    echo "refusing: '$sub' is reserved for the other (selfhosted-server) tunnel on this zone" >&2
    return 1
  fi

  _cft_start_proxy "$sub" "$port" "$inspect" "$auth" || return 1
  local route_port=$_CFT_MITM_ROUTE_PORT

  _cft_json_update "$CFT_DIR/routes.json" '.routes[$sub] = $port' \
    --arg sub "$sub" --argjson port "$route_port"

  _cft_adopt_existing_dns "$sub"
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
  local sub route_port entry real_port web_port inspect auth tags
  while IFS=$'\t' read -r sub route_port; do
    entry=$(_cft_mitm_entry "$sub")
    if [ -n "$entry" ]; then
      IFS=$'\t' read -r real_port web_port inspect auth \
        < <(jq -r '[.port, .web_port, .inspect, .auth] | @tsv' <<<"$entry")
      tags=""
      [ "$inspect" = "1" ] && tags="$tags [inspecting @ http://localhost:$web_port]"
      [ -n "$auth" ] && tags="$tags [auth: ${auth%%:*}]"
      echo "$sub -> localhost:$real_port $tags"
    else
      echo "$sub -> localhost:$route_port"
    fi
  done < <(jq -r '.routes | to_entries[] | [.key, .value] | @tsv' "$CFT_DIR/routes.json")
}

cft-rm() {
  _cft_check_deps || return 1
  local sub="$1"
  if [ -z "$sub" ]; then
    echo "usage: cft-rm <subdomain>   -- remove that route and apply the change" >&2
    return 1
  fi

  _cft_stop_mitm "$sub"
  _cft_json_update "$CFT_DIR/routes.json" 'del(.routes[$sub])' --arg sub "$sub"
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

  # Stops everything tracked, so just kill every pid and clear the file in
  # one pass instead of a read-modify-write per entry.
  _cft_mitm_init
  local sub pid
  while IFS=$'\t' read -r sub pid; do
    _cft_kill_pid "$pid"
    echo "proxy for '$sub' stopped"
  done < <(jq -r 'to_entries[] | [.key, (.value.pid // "")] | @tsv' "$CFT_DIR/mitm.json")
  echo '{}' > "$CFT_DIR/mitm.json"
}

[ -n "$CFT_DIR" ] && _cft_reconcile_stale_daemon
echo "cft tunnel helpers loaded (cft, cft-list, cft-rm, cft-stop) — run 'cft-help' for details"
