output "apigee_org_name" {
  value = google_apigee_organization.org.name
}

output "apigee_instance_id" {
  value = google_apigee_instance.eval_instance.id
}

output "apigee_envgroup_hostnames" {
  value = google_apigee_envgroup.eval_envgroup.hostnames
}

output "postgres_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "redis_host" {
  value = google_redis_instance.leaderboard_cache.host
}

output "lb_ip_address" {
  value = google_compute_global_address.lb_ip.address
}

output "lb_domain" {
  value = var.lb_domain
}

output "rps_zone_name_servers" {
  description = "Add these as an NS record for 'rps' at the GoDaddy registrar to delegate the subdomain"
  value       = google_dns_managed_zone.rps.name_servers
}

output "db_password_secret_id" {
  description = "Secret Manager secret ID holding the Postgres password - resolve via Secret Manager, not Tofu state/outputs"
  value       = google_secret_manager_secret.db_password.secret_id
}
