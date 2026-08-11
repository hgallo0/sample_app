output "id" {
  description = "Security policy ID - attach to a backend service's security_policy attribute"
  value       = google_compute_security_policy.waf.id
}
