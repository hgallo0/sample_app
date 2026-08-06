output "apigee_org_name" {
  value = google_apigee_organization.org.name
}

output "apigee_instance_id" {
  value = google_apigee_instance.eval_instance.id
}

output "apigee_envgroup_hostnames" {
  value = google_apigee_envgroup.eval_envgroup.hostnames
}
