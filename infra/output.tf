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

output "artifact_registry_repo" {
  description = "Artifact Registry repo path for game-api/game-engine images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.rps_images.repository_id}"
}

output "game_engine_url" {
  description = "Internal-only game-engine URL - reachable from game-api's runtime identity only, not from the internet or the LB"
  value       = google_cloud_run_v2_service.game_engine.uri
}

output "db_iam_user" {
  description = "Postgres IAM database username game-api connects as (service account email, .gserviceaccount.com suffix stripped per Cloud SQL IAM auth convention)"
  value       = "${data.google_project.current.number}-compute@developer"
}
