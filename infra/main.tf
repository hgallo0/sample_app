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

resource "google_service_networking_connection" "apigee_psa_connection" {
  network                 = data.google_compute_network.default.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.apigee_psa_range.name]
}

resource "google_apigee_organization" "org" {
  project_id         = var.project_id
  analytics_region   = var.apigee_analytics_region
  billing_type       = "EVALUATION"
  runtime_type       = "CLOUD"
  authorized_network = data.google_compute_network.default.id
  description        = "Savvy interview mock build - Apigee eval org"

  depends_on = [google_service_networking_connection.apigee_psa_connection]
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
