resource "google_project_service" "this" {
  for_each = toset(var.services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
}

data "google_compute_network" "default" {
  project = var.project_id
  name    = "default"
}

# Private Services Access: reserves internal IP ranges and hands them to
# Google's service producer network so managed services (Apigee's runtime
# plane, Cloud SQL, Redis) get private addresses inside our VPC.
resource "google_compute_global_address" "apigee_psa_range" {
  project       = var.project_id
  name          = var.psa_apigee_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_apigee_range_prefix_length
  network       = data.google_compute_network.default.id

  depends_on = [google_project_service.this["servicenetworking.googleapis.com"]]
}

resource "google_compute_global_address" "data_psa_range" {
  project       = var.project_id
  name          = var.psa_data_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_data_range_prefix_length
  network       = data.google_compute_network.default.id

  depends_on = [google_project_service.this["servicenetworking.googleapis.com"]]
}

resource "google_service_networking_connection" "psa_connection" {
  network = data.google_compute_network.default.id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.apigee_psa_range.name,
    google_compute_global_address.data_psa_range.name,
  ]
}

# Smallest/cheapest tier, no HA, no backups - this is interview-prep infra,
# not production. Tear down after the interview; it bills hourly whether
# idle or not.
resource "google_sql_database_instance" "postgres" {
  project             = var.project_id
  name                = var.postgres_instance_name
  region              = var.region
  database_version    = var.postgres_database_version
  deletion_protection = false

  settings {
    edition           = var.postgres_edition
    tier              = var.postgres_tier
    availability_type = var.postgres_availability_type

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_service_networking_connection.psa_connection.network
    }

    backup_configuration {
      enabled = false
    }

    # IAM DB auth, not a password - game-api's runtime service account
    # authenticates as itself (short-lived OAuth token), no static
    # credential to store, rotate, or leak, ever.
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
  }
}

resource "google_sql_database" "rps" {
  name     = var.postgres_database_name
  instance = google_sql_database_instance.postgres.name
}

# Container only, no version - the postgres built-in admin user's password
# is set out-of-band via `gcloud sql users set-password` and the value is
# added here manually via `gcloud secrets versions add`, never through Tofu.
resource "google_secret_manager_secret" "postgres_root_password" {
  project   = var.project_id
  secret_id = var.postgres_root_password_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.this["secretmanager.googleapis.com"]]
}

# IAM database user for game-api's runtime identity - no password field at
# all, nothing to leak into state. Cloud SQL requires the service account
# email with ".gserviceaccount.com" stripped here.
resource "google_sql_user" "game_api_iam" {
  name     = "${data.google_project.current.number}-compute@developer"
  instance = google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

# Required in addition to the IAM DB user above - grants the identity
# permission to authenticate to Cloud SQL via IAM at all.
resource "google_project_iam_member" "game_api_cloudsql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "game_api_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# BASIC tier (no HA replica), 1GB - cheapest option, same reasoning as above.
resource "google_redis_instance" "leaderboard_cache" {
  project            = var.project_id
  name               = var.redis_instance_name
  region             = var.region
  tier               = var.redis_tier
  memory_size_gb     = var.redis_memory_size_gb
  authorized_network = google_service_networking_connection.psa_connection.network
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  depends_on = [google_project_service.this["redis.googleapis.com"]]
}
