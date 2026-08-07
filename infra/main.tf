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

resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
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
  }

  depends_on = [google_service_networking_connection.psa_connection]
}

resource "google_sql_database" "rps" {
  name     = "rps"
  instance = google_sql_database_instance.postgres.name
}

# Password is set out-of-band (gcloud/console), never through Terraform -
# best practice per CLAUDE.md: passwords should never live in state, since
# anyone with state read access can see them in plaintext.
resource "google_sql_user" "rps_app" {
  name     = "rps_app"
  instance = google_sql_database_instance.postgres.name

  lifecycle {
    ignore_changes = [password]
  }
}

# Container only - no google_secret_manager_secret_version here. The actual
# password value is added out-of-band (gcloud) so it never enters Tofu state,
# same reasoning as the sql_user password above. game-api's runtime service
# account reads it directly from Secret Manager instead of it being handed
# to/asked from Henry.
resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "rps-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_iam_member" "db_password_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
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
