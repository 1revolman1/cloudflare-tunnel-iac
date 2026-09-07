terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {}

# routes.json is the only file cft.sh touches: { "routes": { "subdomain": port, ... } }
locals {
  routes = try(jsondecode(file("${path.module}/routes.json")).routes, {})

  # Auto-detected from live DNS: any record in the zone that doesn't point at
  # our own tunnel belongs to something else (e.g. the selfhosted-server
  # tunnel) and must never be touched here. var.reserved_subdomains is an
  # extra manual list on top of this, for names to pre-reserve before a
  # record for them even exists.
  foreign_subdomains = distinct([
    for r in data.cloudflare_dns_records.existing.result :
    trimsuffix(r.name, ".${var.domain}")
    if r.content != "${var.tunnel_id}.cfargotunnel.com" && r.name != var.domain
  ])
  reserved_subdomains       = distinct(concat(local.foreign_subdomains, var.reserved_subdomains))
  routes_using_reserved_key = [for k in keys(local.routes) : k if contains(local.reserved_subdomains, k)]
}

data "cloudflare_dns_records" "existing" {
  zone_id = var.zone_id
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = local.routes

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${var.tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1

  lifecycle {
    precondition {
      condition     = !contains(local.reserved_subdomains, each.key)
      error_message = "'${each.key}' is reserved for the other tunnel on this zone and must not be managed here."
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = concat(
      [for k, v in local.routes : {
        hostname = "${k}.${var.domain}"
        service  = "http://localhost:${v}"
      }],
      # Catch-all must stay last.
      [{
        hostname = null
        service  = "http_status:404"
      }]
    )
  }

  lifecycle {
    precondition {
      condition     = length(local.routes_using_reserved_key) == 0
      error_message = "routes.json uses a reserved subdomain: ${join(", ", local.routes_using_reserved_key)}. These belong to the other tunnel on this zone and must not be managed here."
    }
  }
}
