variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "backend-500517"
}

variable "region" {
  description = "Default region for compute/networking resources"
  type        = string
  default     = "us-central1"
}

variable "apigee_analytics_region" {
  description = "Region for Apigee analytics data storage"
  type        = string
  default     = "us-central1"
}

variable "lb_domain" {
  description = "Public hostname for the external HTTPS load balancer (managed cert is issued for this domain)"
  type        = string
  default     = "rps.cloudwithgallo.com"
}
