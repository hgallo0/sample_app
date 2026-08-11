resource "google_compute_security_policy" "waf" {
  project = var.project_id
  name    = var.name

  advanced_options_config {
    json_parsing = var.json_parsing
    log_level    = var.log_level
  }

  dynamic "rule" {
    for_each = { for r in var.rules : r.priority => r }
    content {
      action      = rule.value.action
      priority    = rule.value.priority
      description = rule.value.description

      match {
        dynamic "expr" {
          for_each = rule.value.preconfigured_expression != null ? [rule.value.preconfigured_expression] : []
          content {
            expression = "evaluatePreconfiguredExpr('${expr.value}')"
          }
        }

        versioned_expr = rule.value.src_ip_ranges != null ? "SRC_IPS_V1" : null

        dynamic "config" {
          for_each = rule.value.src_ip_ranges != null ? [rule.value.src_ip_ranges] : []
          content {
            src_ip_ranges = config.value
          }
        }
      }

      dynamic "rate_limit_options" {
        for_each = rule.value.rate_limit_options != null ? [rule.value.rate_limit_options] : []
        content {
          conform_action = rate_limit_options.value.conform_action
          exceed_action  = rate_limit_options.value.exceed_action
          enforce_on_key = rate_limit_options.value.enforce_on_key
          rate_limit_threshold {
            count        = rate_limit_options.value.rate_limit_threshold.count
            interval_sec = rate_limit_options.value.rate_limit_threshold.interval_sec
          }
        }
      }
    }
  }
}
