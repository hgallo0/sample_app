terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "apigee" {
  project            = var.project_id
  service            = "apigee.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "service_networking" {
  project            = var.project_id
  service            = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "redis" {
  project            = var.project_id
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns" {
  project            = var.project_id
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
}

data "google_compute_network" "default" {
  project = var.project_id
  name    = "default"
}

# Private Services Access: reserves an internal IP range and hands it to
# Google's service producer network so managed services (Apigee's runtime
# plane here) get a private address inside our VPC.
resource "google_compute_global_address" "apigee_psa_range" {
  project       = var.project_id
  name          = "apigee-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.default.id

  depends_on = [google_project_service.service_networking]
}

resource "google_compute_global_address" "data_psa_range" {
  project       = var.project_id
  name          = "data-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = data.google_compute_network.default.id

  depends_on = [google_project_service.service_networking]
}

resource "google_service_networking_connection" "psa_connection" {
  network = data.google_compute_network.default.id
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.apigee_psa_range.name,
    google_compute_global_address.data_psa_range.name,
  ]
}

resource "google_apigee_organization" "org" {
  project_id         = var.project_id
  analytics_region   = var.apigee_analytics_region
  billing_type       = "EVALUATION"
  runtime_type       = "CLOUD"
  authorized_network = data.google_compute_network.default.id
  description        = "Savvy interview mock build - Apigee eval org"

  depends_on = [google_service_networking_connection.psa_connection]
}

resource "google_apigee_instance" "eval_instance" {
  org_id   = google_apigee_organization.org.id
  name     = "eval-instance"
  location = var.region
}

resource "google_apigee_environment" "eval_env" {
  org_id      = google_apigee_organization.org.id
  name        = "eval"
  description = "Evaluation environment for the RPS game API proxy"
}

resource "google_apigee_instance_attachment" "eval_attachment" {
  instance_id = google_apigee_instance.eval_instance.id
  environment = google_apigee_environment.eval_env.name
}

resource "google_apigee_envgroup" "eval_envgroup" {
  org_id    = google_apigee_organization.org.id
  name      = "eval-group"
  hostnames = ["eval.example.com"]
}

resource "google_apigee_envgroup_attachment" "eval_envgroup_attachment" {
  envgroup_id = google_apigee_envgroup.eval_envgroup.id
  environment = google_apigee_environment.eval_env.name
}

# Smallest/cheapest tier, no HA, no backups - this is interview-prep infra,
# not production. Tear down after the interview; it bills hourly whether
# idle or not.
resource "google_sql_database_instance" "postgres" {
  project             = var.project_id
  name                = "rps-postgres"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false

  settings {
    edition           = "ENTERPRISE"
    tier              = "db-f1-micro"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.default.id
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

  depends_on = [google_service_networking_connection.psa_connection]
}

resource "google_sql_database" "rps" {
  name     = "rps"
  instance = google_sql_database_instance.postgres.name
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
  name               = "rps-leaderboard-cache"
  region             = var.region
  tier               = "BASIC"
  memory_size_gb     = 1
  authorized_network = data.google_compute_network.default.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  depends_on = [
    google_service_networking_connection.psa_connection,
    google_project_service.redis,
  ]
}

# Holds both game-api and game-engine images. Created via Tofu even though
# it's fast/live-session-friendly infra - GCP resources are never created
# imperatively with gcloud in this repo, see CLAUDE.md.
resource "google_artifact_registry_repository" "rps_images" {
  project       = var.project_id
  location      = var.region
  repository_id = "rps-images"
  format        = "DOCKER"
  description   = "RPS game images (game-api, game-engine)"

  depends_on = [google_project_service.artifactregistry]
}

# Placeholder backend so the LB + managed cert (the slow part) can
# provision now. Swapped for the real game-api service during the live
# build - same Cloud Run service name, new revision, LB stays untouched.
resource "google_cloud_run_v2_service" "placeholder" {
  project  = var.project_id
  name     = "game-api"
  location = var.region
  # Load balancer only - blocks direct internet access to the *.run.app
  # URL, only traffic arriving via the Serverless NEG/load balancer below
  # is accepted. Paired with the public invoker binding below by design.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "placeholder_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.placeholder.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Go RPS game-engine service - internal only, not fronted by the LB and no
# public invoker. Ingress restricted to same-project Cloud Run/internal
# traffic, invoker restricted to game-api's own runtime identity, so only
# game-api can ever call it. Placeholder image swapped for the real build
# during the live session, same as game-api.
resource "google_cloud_run_v2_service" "game_engine" {
  project  = var.project_id
  name     = "game-engine"
  location = var.region
  # Internal only - no LB, no public internet path at all. Reachable only
  # from other Cloud Run/serverless resources in this project over Google's
  # internal network. Paired with the invoker restriction below.
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "game_engine_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.game_engine.name
  role     = "roles/run.invoker"
  # game-api's own runtime identity - same default compute SA both services
  # run as. Not allUsers: this service has no public path at all.
  member = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_compute_region_network_endpoint_group" "game_api_neg" {
  project               = var.project_id
  name                  = "game-api-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.placeholder.name
  }
}

resource "google_compute_security_policy" "waf" {
  project = var.project_id
  name    = "rps-waf"

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable')"
      }
    }
    description = "Block XSS"
  }

  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "Block SQL injection"
  }

  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }
    description = "Rate limit per source IP"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}

resource "google_compute_backend_service" "game_api" {
  project               = var.project_id
  name                  = "game-api-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = google_compute_security_policy.waf.id

  backend {
    group = google_compute_region_network_endpoint_group.game_api_neg.id
  }
}

resource "google_compute_url_map" "game_api" {
  project         = var.project_id
  name            = "game-api-lb"
  default_service = google_compute_backend_service.game_api.id
}

resource "google_compute_managed_ssl_certificate" "game_api" {
  project = var.project_id
  name    = "game-api-cert"
  managed {
    domains = [var.lb_domain]
  }
}

resource "google_compute_target_https_proxy" "game_api" {
  project          = var.project_id
  name             = "game-api-https-proxy"
  url_map          = google_compute_url_map.game_api.id
  ssl_certificates = [google_compute_managed_ssl_certificate.game_api.id]
}

resource "google_compute_global_address" "lb_ip" {
  project = var.project_id
  name    = "game-api-lb-ip"
}

resource "google_compute_global_forwarding_rule" "game_api_https" {
  project               = var.project_id
  name                  = "game-api-https-rule"
  target                = google_compute_target_https_proxy.game_api.id
  port_range            = "443"
  ip_address            = google_compute_global_address.lb_ip.id
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# Delegated subdomain zone, not the whole registered domain - GoDaddy stays
# authoritative for cloudwithgallo.com, only rps.cloudwithgallo.com's NS
# records point here. Keeps the rest of the domain (email, other subdomains)
# untouched.
resource "google_dns_managed_zone" "rps" {
  project     = var.project_id
  name        = "rps-zone"
  dns_name    = "${var.lb_domain}."
  description = "Delegated subdomain zone for the RPS game API load balancer"

  depends_on = [google_project_service.dns]
}

resource "google_dns_record_set" "rps_a" {
  project      = var.project_id
  name         = google_dns_managed_zone.rps.dns_name
  managed_zone = google_dns_managed_zone.rps.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address]
}
