module "base_infra" {
  source     = "./modules/base-infra"
  project_id = var.project_id
  region     = var.region
  services = [
    "apigee.googleapis.com",
    "servicenetworking.googleapis.com",
    "redis.googleapis.com",
    "dns.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "identitytoolkit.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudscheduler.googleapis.com",
  ]

  psa_apigee_range_name = "apigee-psa-range"
  psa_data_range_name   = "data-psa-range"

  postgres_instance_name           = "rps-postgres"
  postgres_database_name           = "rps"
  postgres_root_password_secret_id = "postgres-root-password"

  redis_instance_name = "rps-leaderboard-cache"
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

resource "google_apigee_organization" "org" {
  project_id         = var.project_id
  analytics_region   = var.apigee_analytics_region
  billing_type       = "EVALUATION"
  runtime_type       = "CLOUD"
  authorized_network = data.google_compute_network.default.id
  description        = "Savvy interview mock build - Apigee eval org"

  # PSA ranges + service networking connection now live in the base-infra
  # module alongside Postgres/Redis, which also need them - see
  # modules/base-infra/main.tf.
  depends_on = [module.base_infra]
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


# Holds both game-api and game-engine images. Created via Tofu even though
# it's fast/live-session-friendly infra - GCP resources are never created
# imperatively with gcloud in this repo, see CLAUDE.md.
resource "google_artifact_registry_repository" "rps_images" {
  project       = var.project_id
  location      = var.region
  repository_id = "rps-images"
  format        = "DOCKER"
  description   = "RPS game images (game-api, game-engine)"

  depends_on = [module.base_infra]
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
        value = module.base_infra.redis_host
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

# Lets both services' OTel exporters (game-api and game-engine both run as
# this same default compute SA) write spans to Cloud Trace - without it the
# CloudTraceSpanExporter/otlp exporter fails silently on every export.
resource "google_project_iam_member" "compute_sa_cloudtrace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
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

# Without json_parsing = STANDARD, Cloud Armor inspects request bodies as
# opaque strings, so any JSON object/array's {}/[] structure trips the
# SQLi/XSS preconfigured rules as a false positive - every JSON POST body
# gets blocked outright. STANDARD parses Content-Type: application/json
# bodies properly and inspects field values individually instead, preserving
# real protection.
module "security" {
  source     = "./modules/security"
  project_id = var.project_id
  name       = "rps-waf"

  rules = [
    {
      action                   = "deny(403)"
      priority                 = 1000
      description              = "Block XSS"
      preconfigured_expression = "xss-stable"
    },
    {
      action                   = "deny(403)"
      priority                 = 1001
      description              = "Block SQL injection"
      preconfigured_expression = "sqli-stable"
    },
    {
      action        = "throttle"
      priority      = 2000
      description   = "Rate limit per source IP"
      src_ip_ranges = ["*"]
      rate_limit_options = {
        conform_action = "allow"
        exceed_action  = "deny(429)"
        enforce_on_key = "IP"
        rate_limit_threshold = {
          count        = 100
          interval_sec = 60
        }
      }
    },
    {
      action        = "allow"
      priority      = 2147483647
      description   = "Default allow"
      src_ip_ranges = ["*"]
    },
  ]
}

# --- prospect-tracker (financial-advisor CRM demo app) ---------------------
# Shares this project's existing Postgres instance, VPC/NAT, WAF policy, and
# LB/cert/domain with the RPS app - see the "Share existing rps-postgres
# instance" / "Path-based on rps.cloudwithgallo.com" decisions in the plan
# this was built from. Same IAM-auth pattern as game-api: no passwords.

resource "google_sql_database" "prospects" {
  project    = var.project_id
  name       = "prospects"
  instance   = module.base_infra.postgres_instance_name
  depends_on = [module.base_infra]
}
# NOTE (manual, non-Tofu step): Postgres privileges are per-database, so the
# shared compute SA's existing IAM DB user (created once for game-api/`rps`
# in modules/base-infra/main.tf) still needs a one-time
# `GRANT ALL ON SCHEMA public TO "<db_iam_user>"` on THIS `prospects`
# database via Cloud SQL Studio before prospect-api can read/write - same
# manual step INFRA_CONTEXT.md documents for game_api's schema, not
# something a Tofu resource type covers.

resource "google_secret_manager_secret" "grafana_otlp_headers" {
  project   = var.project_id
  secret_id = "grafana-otlp-headers"
  replication {
    auto {}
  }
  depends_on = [module.base_infra]
}

resource "google_secret_manager_secret_iam_member" "grafana_otlp_headers_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.grafana_otlp_headers.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_cloud_run_v2_service" "prospect_api" {
  project  = var.project_id
  name     = "prospect-api"
  location = var.region
  # Rehearsal env, not production - see the same note on game-api above.
  deletion_protection = false
  # Load balancer only, same restriction/reasoning as game-api below.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    labels = {
      app-version = "v0-1-4"
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    # Same ALL_TRAFFIC reasoning as game-api: needs the VPC path to
    # Postgres's private IP, and ALL_TRAFFIC (not PRIVATE_RANGES_ONLY) still
    # leaves a route to the public internet via rps-nat for the Cloud SQL
    # connector's IAM token fetch and the Grafana Cloud OTLP export.
    vpc_access {
      network_interfaces {
        network    = data.google_compute_network.default.name
        subnetwork = data.google_compute_subnetwork.default.name
      }
      egress = "ALL_TRAFFIC"
    }
    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/rps-images/prospect-api:v0.1.4"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "REGION"
        value = var.region
      }
      env {
        name  = "INSTANCE_NAME"
        value = module.base_infra.postgres_instance_name
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.prospects.name
      }
      env {
        name  = "DB_IAM_USER"
        value = "${data.google_project.current.number}-compute@developer"
      }
      env {
        name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
        value = "https://otlp-gateway-prod-us-east-3.grafana.net/otlp"
      }
      env {
        name = "OTEL_EXPORTER_OTLP_HEADERS"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.grafana_otlp_headers.secret_id
            version = "latest"
          }
        }
      }
      # Same generous startup window as game-api - Cloud SQL IAM auth and the
      # OTel OTLP exporter both make outbound calls through the same
      # ALL_TRAFFIC/NAT path at startup.
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

resource "google_cloud_run_v2_service_iam_member" "prospect_api_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.prospect_api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Static client (Vite build served by nginx) - no VPC egress needed, it makes
# no outbound calls of its own.
resource "google_cloud_run_v2_service" "prospect_web" {
  project             = var.project_id
  name                = "prospect-web"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    labels = {
      app-version = "v0-1-1"
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    containers {
      image = "us-central1-docker.pkg.dev/${var.project_id}/rps-images/prospect-web:v0.1.1"
    }
  }

  lifecycle {
    ignore_changes = [scaling]
  }
}

resource "google_cloud_run_v2_service_iam_member" "prospect_web_public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.prospect_web.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_region_network_endpoint_group" "prospect_api_neg" {
  project               = var.project_id
  name                  = "prospect-api-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.prospect_api.name
  }
}

resource "google_compute_region_network_endpoint_group" "prospect_web_neg" {
  project               = var.project_id
  name                  = "prospect-web-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.prospect_web.name
  }
}

# Same WAF policy as game-api - one Cloud Armor policy covers every backend
# on this GLB, not a separate policy per app.
resource "google_compute_backend_service" "prospect_api" {
  project               = var.project_id
  name                  = "prospect-api-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = module.security.id

  log_config {
    enable = true
  }

  backend {
    group = google_compute_region_network_endpoint_group.prospect_api_neg.id
  }
}

resource "google_compute_backend_service" "prospect_web" {
  project               = var.project_id
  name                  = "prospect-web-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = module.security.id

  log_config {
    enable = true
  }

  backend {
    group = google_compute_region_network_endpoint_group.prospect_web_neg.id
  }
}
module "grafana_dashboards" {
  source = "./modules/grafana-dashboards"
}
# --- end prospect-tracker ----------------------------------------------------

resource "google_compute_backend_service" "game_api" {
  project               = var.project_id
  name                  = "game-api-backend"
  protocol              = "HTTPS"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = module.security.id

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

resource "google_storage_bucket" "tfstate" {
  project                     = var.project_id
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = true
  }
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

  # prospect-tracker gets its own clean domain rather than living under a
  # path prefix here - same GLB/IP/cert (extra SAN below), separate host_rule
  # so it can use natural root/api paths with no rewrite needed.
  host_rule {
    hosts        = [var.wealth_domain]
    path_matcher = "wealth-routing"
  }

  path_matcher {
    name            = "wealth-routing"
    default_service = google_compute_backend_service.prospect_web.id

    route_rules {
      priority = 1
      service  = google_compute_backend_service.prospect_api.id
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

# Separate cert resource rather than adding wealth_domain to the one above -
# `domains` forces full replacement of a managed cert on change, which would
# destroy the already-active, already-serving rps.cloudwithgallo.com cert and
# leave both domains without valid HTTPS until the new multi-domain cert
# re-validates (which can't complete until wealth's DNS delegation is live).
# An independent cert here means rps.cloudwithgallo.com is never touched,
# regardless of how long wealth.cloudwithgallo.com's validation takes.
resource "google_compute_managed_ssl_certificate" "wealth" {
  project = var.project_id
  name    = "wealth-cert"
  managed {
    domains = [var.wealth_domain]
  }
}

resource "google_compute_target_https_proxy" "game_api" {
  project = var.project_id
  name    = "game-api-https-proxy"
  url_map = google_compute_url_map.game_api.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.game_api.id,
    google_compute_managed_ssl_certificate.wealth.id,
  ]
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

  depends_on = [module.base_infra]
}

resource "google_dns_record_set" "rps_a" {
  project      = var.project_id
  name         = google_dns_managed_zone.rps.dns_name
  managed_zone = google_dns_managed_zone.rps.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address]
}

# Second delegated subdomain zone, same pattern as rps-zone above - GoDaddy
# needs a fresh NS delegation for wealth.cloudwithgallo.com specifically,
# separate from rps.cloudwithgallo.com's existing one.
resource "google_dns_managed_zone" "wealth" {
  project     = var.project_id
  name        = "wealth-zone"
  dns_name    = "${var.wealth_domain}."
  description = "Delegated subdomain zone for the prospect-tracker load balancer hostname"

  depends_on = [module.base_infra]
}

resource "google_dns_record_set" "wealth_a" {
  project      = var.project_id
  name         = google_dns_managed_zone.wealth.dns_name
  managed_zone = google_dns_managed_zone.wealth.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb_ip.address]
}

# Synthetic check - hits the live app through the real LB/WAF path every
# minute, the same route a real advisor's browser takes (not a direct
# Cloud Run bypass). Chosen over Grafana Cloud Synthetic Monitoring because
# SM's installation flow needs a credential type (a legacy "MetricsPublisher"
# API key) this account doesn't cleanly expose - this delivers the same
# outside-in check using infra already fully under Tofu control.
#
# Also doubles as keep-warm traffic: prospect-api scales to zero
# (min_instance_count=0) between bursts, which was leaving real gaps in its
# metrics rather than just low values - exactly what was blocking the ML
# traffic-forecast job's "at least 100 datapoints" training requirement.
resource "google_cloud_scheduler_job" "prospect_api_synthetic_check" {
  project     = var.project_id
  region      = var.region
  name        = "prospect-api-synthetic-check"
  description = "Synthetic health check - GET /api/health through the real LB/WAF path, once a minute"
  schedule    = "* * * * *"
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "GET"
    uri         = "https://${var.wealth_domain}/api/health"
    headers = {
      # Lets the app count this as a distinct synthetic_check_total metric,
      # separate from real advisor traffic hitting the same /api/health route.
      "X-Synthetic-Check" = "true"
    }
  }

  retry_config {
    retry_count = 1
  }

  depends_on = [module.base_infra]
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

  depends_on = [module.base_infra]
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
