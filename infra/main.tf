terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

# google_firebase_web_app is beta-only as of provider 6.x.
provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
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

resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "identitytoolkit" {
  project            = var.project_id
  service            = "identitytoolkit.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
}

data "google_compute_network" "default" {
  project = var.project_id
  name    = "default"
}

data "google_compute_subnetwork" "default" {
  project = var.project_id
  region  = var.region
  name    = "default"
}

# game-api's vpc_access egress is ALL_TRAFFIC (not just private ranges) so
# its calls to game-engine's *.run.app URL route through the VPC and get
# recognized as internal Cloud-Run-to-Cloud-Run traffic by game-engine's
# INGRESS_TRAFFIC_INTERNAL_ONLY - otherwise those calls go out over the
# normal internet path and get rejected as external. But routing ALL
# traffic through the VPC means calls to public Google APIs (Cloud SQL IAM
# token fetch, Firebase cert verification) need a way out to the internet
# too, since VPC instances without external IPs have none by default -
# without this NAT, game-api fails to even start (Cloud SQL IAM auth runs
# at import time and hangs trying to reach oauth2.googleapis.com).
resource "google_compute_router" "default" {
  project = var.project_id
  name    = "rps-router"
  region  = var.region
  network = data.google_compute_network.default.name
}

resource "google_compute_router_nat" "default" {
  project                            = var.project_id
  name                               = "rps-nat"
  router                             = google_compute_router.default.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
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
  org_id = google_apigee_organization.org.id
  name   = "eval-group"
  # Placeholder on purpose - fixing this to the real domain is part of the
  # live-build deliverable (see .claude/agents/apigee-proxy.md step 1).
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

# Container only, no version - the postgres built-in admin user's password
# is set out-of-band via `gcloud sql users set-password` and the value is
# added here manually via `gcloud secrets versions add`, never through Tofu.
resource "google_secret_manager_secret" "postgres_root_password" {
  project   = var.project_id
  secret_id = "postgres-root-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
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

  # A service-level `scaling` block (distinct from template.scaling below,
  # which stays managed) shows up as drift under provider ~> 6.0 - state has
  # it (manual_instance_count=0, min_instance_count=0, i.e. already the
  # provider's own defaults, not a real live setting anyone configured), but
  # this config never declared it, so every plan wants to remove it. Ignored
  # here rather than applied blind: this resource is out of scope for the
  # Apigee routing change, and it's pulled into that change's plan only
  # because the new url_map route_rule references this service's existing
  # backend (via game-api-backend / game-api-neg) - removing this attribute
  # is very likely a no-op against the live service (values already match
  # defaults), but "very likely" isn't the bar for touching an
  # already-serving Cloud Run service as a side effect of an unrelated
  # change, so it's excluded rather than silently folded in.
  # Rehearsal env, not production - services get torn down/recreated
  # between sessions, so protection would just block that.
  deletion_protection = false
  # Load balancer only - blocks direct internet access to the *.run.app
  # URL, only traffic arriving via the Serverless NEG/load balancer below
  # is accepted. Paired with the public invoker binding below by design.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    # Ties the deployed revision to the image tag - also forces a fresh
    # revision on redeploy even when the image string itself is unchanged
    # (e.g. retrying after an external fix, not a new build).
    labels = {
      app-version = "v0-3-0"
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    # Direct VPC egress - game-api needs a network path to Cloud SQL/Redis's
    # private IPs (PSA-peered), which Cloud Run has no route to by default.
    # ALL_TRAFFIC, not PRIVATE_RANGES_ONLY: game-engine's *.run.app URL
    # resolves to a public IP, so PRIVATE_RANGES_ONLY would send that call
    # out over the normal internet path instead of the VPC - and
    # game-engine's INGRESS_TRAFFIC_INTERNAL_ONLY then silently 404s it,
    # since it no longer looks like same-project Cloud Run traffic. Calls to
    # Google's own public APIs (Firebase cert verification) still work fine
    # over ALL_TRAFFIC - it routes through the VPC's default internet route,
    # it doesn't block internet egress.
    vpc_access {
      network_interfaces {
        network    = data.google_compute_network.default.name
        subnetwork = data.google_compute_subnetwork.default.name
      }
      egress = "ALL_TRAFFIC"
    }
    containers {
      # Placeholder on purpose - the build+push+deploy cycle itself is in
      # scope to demonstrate live, per PLAN.md's Prep-scope rule. Env
      # vars/VPC egress/startup probe stay as-is: that's infra wiring, not
      # the live-build deliverable.
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "DB_IAM_USER"
        value = "${data.google_project.current.number}-compute@developer"
      }
      env {
        name  = "REDIS_HOST"
        value = google_redis_instance.leaderboard_cache.host
      }
      env {
        name  = "GAME_ENGINE_URL"
        value = google_cloud_run_v2_service.game_engine.uri
      }
      # Cloud Run's default startup probe (period_seconds=240,
      # failure_threshold=1) gives only one 240s window with no retries.
      # Google's own Direct VPC egress docs warn cold-start connection
      # establishment can take "a minute or more" and recommend a startup
      # probe with retries - this gives up to ~3x the window (three 240s
      # attempts) before giving up, since ALL_TRAFFIC egress routes even
      # the Cloud SQL Admin API call through the VPC/NAT path now.
      startup_probe {
        tcp_socket {
          port = 8080
        }
        period_seconds    = 240
        timeout_seconds   = 10
        failure_threshold = 3
      }
    }
  }

  lifecycle {
    ignore_changes = [scaling]
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
  # Rehearsal env, not production - services get torn down/recreated
  # between sessions, so protection would just block that.
  deletion_protection = false
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
      # Same placeholder reasoning as game-api's above.
      image = "us-docker.pkg.dev/cloudrun/container/hello"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
    }
  }

  # Same service-level `scaling` drift and same reasoning as
  # google_cloud_run_v2_service.placeholder above - not something this
  # change should touch, so ignored rather than applied.
  lifecycle {
    ignore_changes = [scaling]
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

# The PSC NEG + Apigee backend service (GLB-side half of the "GLB sits in
# front of Apigee" hairpin) are deliberately NOT declared here - they're the
# live-build deliverable, added fresh each rehearsal/interview by the
# `apigee-proxy` agent, per PLAN.md's Prep-scope rule and the spec in
# INFRA_CONTEXT.md's "Proxy bundle routing". See that agent's own comments
# (`.claude/agents/apigee-proxy.md`) and the resource names it uses
# (`google_compute_region_network_endpoint_group.apigee_psc_neg`,
# `google_compute_backend_service.apigee`) for the exact shape to expect.

resource "google_compute_security_policy" "waf" {
  project = var.project_id
  name    = "rps-waf"

  # Without this, Cloud Armor inspects request bodies as opaque strings, so
  # any JSON object/array's {}/[] structure trips the SQLi/XSS preconfigured
  # rules as a false positive - every JSON POST body gets blocked outright.
  # STANDARD parses Content-Type: application/json bodies properly and
  # inspects field values individually instead, preserving real protection.
  advanced_options_config {
    json_parsing = "STANDARD"
    log_level    = "VERBOSE"
  }

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

  # Was off entirely - the WAF false-positive on JSON bodies (see the
  # security policy above) was undiagnosable without this.
  log_config {
    enable = true
  }

  backend {
    group = google_compute_region_network_endpoint_group.game_api_neg.id
  }
}

# Static frontend (app/frontend/index.html) - served via a backend bucket
# fronted by the same GLB/domain/cert as the API, so /api and the page share
# an origin and avoid CORS entirely. Bucket name is suffixed with a random
# hex ID: GCS bucket names are globally unique (not scoped to this project),
# and a prior /teardown cycle soft-deleted a bucket named
# "${var.project_id}-frontend" with a 7-day retention window, so that exact
# name isn't reusable right now - the suffix guarantees a collision-free
# name on every rehearsal cycle.
resource "random_id" "frontend_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "frontend" {
  project                     = var.project_id
  name                        = "${var.project_id}-frontend-${random_id.frontend_suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  website {
    main_page_suffix = "index.html"
  }
}

# Public read of this bucket's objects only - scoped to roles/storage.objectViewer
# on this single static-assets bucket, nothing project-wide. This is the
# standard way to serve a backend-bucket-fronted static site on a GLB; the
# CLAUDE.md "never allow public database access" rule is about databases
# specifically, not public static assets.
resource "google_storage_bucket_iam_member" "frontend_public_read" {
  bucket = google_storage_bucket.frontend.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_object" "frontend_index" {
  name         = "index.html"
  bucket       = google_storage_bucket.frontend.name
  source       = "${path.module}/../app/frontend/index.html"
  content_type = "text/html"
}

resource "google_compute_backend_bucket" "frontend" {
  project     = var.project_id
  name        = "frontend-backend"
  bucket_name = google_storage_bucket.frontend.name
  enable_cdn  = false
}

resource "google_compute_url_map" "game_api" {
  project = var.project_id
  name    = "game-api-lb"

  # Permanent baseline (prebuilt substrate, not live-build scope): frontend
  # serves "/" and everything else, /api/* goes straight to game-api-backend.
  # A prior rehearsal proved pointing default_service at the frontend bucket
  # WITHOUT an explicit /api/ route_rule sends /api/* to GCS too (NoSuchKey
  # 404) - a real regression - so this route_rule is required, not optional,
  # for the frontend to be safe to leave wired in permanently.
  #
  # The live Apigee build session's job is to turn this into the hairpin
  # split: change this route_rule's `service` from game_api_backend to the
  # new apigee backend (PSC NEG-backed), and add a second, higher-priority-
  # number route_rule for /_internal/api/* -> game_api_backend with a
  # path_prefix_rewrite to /api/ (Apigee's proxy target calls back through
  # that path, bypassing itself). See INFRA_CONTEXT.md "Proxy bundle
  # routing" for the full spec - deliberately not built here, that's the
  # live-build deliverable.
  default_service = google_compute_backend_bucket.frontend.id

  host_rule {
    hosts        = [var.lb_domain]
    path_matcher = "api-routing"
  }

  path_matcher {
    name            = "api-routing"
    default_service = google_compute_backend_bucket.frontend.id

    route_rules {
      priority = 1
      service  = google_compute_backend_service.game_api.id
      match_rules {
        prefix_match = "/api/"
      }
    }
  }
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

# Identity Platform (the underlying service behind Firebase Auth) - config
# only, no secrets. Enabling Google as a sign-in provider still requires one
# manual step in the Firebase Console (Authentication > Sign-in method >
# Google > Enable): the underlying Terraform resource for that,
# google_identity_platform_default_supported_idp_config, takes a plaintext
# client_secret with no state-avoidance mechanism, which CLAUDE.md's
# secrets-never-in-state rule rules out. The console flow creates the OAuth
# client and registers it as the IdP in one step, so the secret never
# touches Tofu, state, or this repo at all.
resource "google_identity_platform_config" "auth" {
  project = var.project_id

  authorized_domains = [
    "localhost",
    var.lb_domain,
    "${var.project_id}.firebaseapp.com",
    "${var.project_id}.web.app",
  ]

  # Sign-up abuse guard, same spirit as the WAF's per-IP rate limit below.
  quota {
    sign_up_quota_config {
      quota          = 100
      quota_duration = "3600s"
      start_time     = "2026-08-09T00:00:00Z"
    }
  }

  # Explicit, matching live state - without this, every plan showed drift
  # wanting to null it out (provider ~> 6.0 always returns this block, even
  # at its own default value, so an absent declaration reads as "remove it").
  multi_tenant {
    allow_tenants = false
  }

  depends_on = [google_project_service.identitytoolkit]
}

# Registers a Firebase "Web App" purely to get an apiKey/authDomain pair for
# the JS SDK - this is metadata, not a secret (Firebase web API keys are
# meant to be public/client-embedded, unlike an OAuth client_secret).
resource "google_firebase_web_app" "rps" {
  provider = google-beta
  project  = var.project_id

  display_name    = "RPS game (web)"
  deletion_policy = "DELETE"

  depends_on = [google_identity_platform_config.auth]
}

data "google_firebase_web_app_config" "rps" {
  provider   = google-beta
  web_app_id = google_firebase_web_app.rps.app_id
}
