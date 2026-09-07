output "domain" {
  value = var.domain
}

output "tunnel_id" {
  value = var.tunnel_id
}

output "zone_id" {
  value = var.zone_id
}

output "urls" {
  value = { for k, v in local.routes : k => "https://${k}.${var.domain} -> localhost:${v}" }
}
