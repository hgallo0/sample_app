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

output "db_password" {
  value     = random_password.db_password.result
  sensitive = true
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
