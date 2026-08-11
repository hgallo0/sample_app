variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "name" {
  description = "Name for the Cloud Armor security policy"
  type        = string
}

variable "json_parsing" {
  description = "Cloud Armor request body parsing mode - STANDARD inspects application/json bodies field-by-field instead of as an opaque string, avoiding false-positive SQLi/XSS matches on JSON structural characters"
  type        = string
  default     = "STANDARD"
}

variable "log_level" {
  description = "Cloud Armor logging verbosity"
  type        = string
  default     = "VERBOSE"
}

variable "rules" {
  description = "Cloud Armor security policy rules, set by the caller - this module holds no baked-in rule set. Exactly one of preconfigured_expression / src_ip_ranges must be set per rule: preconfigured_expression evaluates a Google preconfigured WAF signature (e.g. \"xss-stable\", \"sqli-stable\"); src_ip_ranges matches by source IP (use [\"*\"] for a catch-all allow/throttle/deny rule)."
  type = list(object({
    action                   = string
    priority                 = number
    description              = optional(string)
    preconfigured_expression = optional(string)
    src_ip_ranges            = optional(list(string))
    rate_limit_options = optional(object({
      conform_action = string
      exceed_action  = string
      enforce_on_key = string
      rate_limit_threshold = object({
        count        = number
        interval_sec = number
      })
    }))
  }))
}
