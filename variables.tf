variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "zone_id" {
  description = "Cloudflare zone ID for the domain"
  type        = string
}

variable "tunnel_id" {
  description = "UUID of the existing cloudflared tunnel"
  type        = string
}

variable "domain" {
  description = "Base domain, e.g. example.com"
  type        = string
}

variable "reserved_subdomains" {
  description = "Extra subdomains to reserve on top of what's auto-detected from existing DNS records in the zone (main.tf's foreign_subdomains) -- use this to pre-reserve a name before a record for it exists."
  type        = list(string)
  default     = []
}
