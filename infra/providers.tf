terraform {
  backend "gcs" {
    bucket = "backend-500517-tfstate"
    prefix = "state"
  }

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
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
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

# Auth token comes from the GRAFANA_AUTH env var at apply time - never
# hardcoded here, never in state as a resource attribute (it's provider
# config, not a resource field), same secrets-out-of-Tofu spirit as
# everything else in this repo.
provider "grafana" {
  url = "https://shortreindeer1185.grafana.net"
}
