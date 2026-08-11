output "services" {
  description = "Enabled google_project_service resources, keyed by service name"
  value       = google_project_service.this
}

output "postgres_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "postgres_instance_name" {
  value = google_sql_database_instance.postgres.name
}

output "redis_host" {
  value = google_redis_instance.leaderboard_cache.host
}

output "db_iam_user" {
  description = "Postgres IAM database username game-api connects as (service account email, .gserviceaccount.com suffix stripped per Cloud SQL IAM auth convention)"
  value       = "${data.google_project.current.number}-compute@developer"
}
