variable "project_id" {
  description = "GCP project ID to enable services on"
  type        = string
}

variable "services" {
  description = "GCP API service names to enable (e.g. \"redis.googleapis.com\")"
  type        = list(string)
}

variable "region" {
  description = "Default region for the Postgres instance and Redis instance"
  type        = string
}

variable "psa_apigee_range_name" {
  description = "Name for the VPC_PEERING address range reserved for Apigee's runtime plane"
  type        = string
}

variable "psa_apigee_range_prefix_length" {
  description = "Prefix length (CIDR size) of the Apigee PSA range"
  type        = number
  default     = 16
}

variable "psa_data_range_name" {
  description = "Name for the VPC_PEERING address range reserved for Cloud SQL/Redis private services access"
  type        = string
}

variable "psa_data_range_prefix_length" {
  description = "Prefix length (CIDR size) of the data-services PSA range"
  type        = number
  default     = 20
}

variable "postgres_instance_name" {
  description = "Cloud SQL instance name"
  type        = string
}

variable "postgres_database_name" {
  description = "Database name created on the Cloud SQL instance"
  type        = string
}

variable "postgres_database_version" {
  description = "Cloud SQL database engine/version"
  type        = string
  default     = "POSTGRES_16"
}

variable "postgres_edition" {
  description = "Cloud SQL edition"
  type        = string
  default     = "ENTERPRISE"
}

variable "postgres_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-f1-micro"
}

variable "postgres_availability_type" {
  description = "Cloud SQL availability type (e.g. ZONAL, REGIONAL)"
  type        = string
  default     = "ZONAL"
}

variable "postgres_root_password_secret_id" {
  description = "Secret Manager secret ID for the Postgres root password container (value is set out-of-band, never through Tofu)"
  type        = string
}

variable "redis_instance_name" {
  description = "Memorystore Redis instance name"
  type        = string
}

variable "redis_tier" {
  description = "Memorystore Redis service tier"
  type        = string
  default     = "BASIC"
}

variable "redis_memory_size_gb" {
  description = "Memorystore Redis instance size in GB"
  type        = number
  default     = 1
}
