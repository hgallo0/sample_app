terraform {
  required_providers {
    # Without this, an unqualified "grafana" local name here defaults to the
    # legacy hashicorp/grafana namespace instead of inheriting root's
    # grafana/grafana provider - installs both, only one of which is
    # actually configured.
    grafana = {
      source = "grafana/grafana"
    }
  }
}

# Looks up the stack's default Prometheus/Mimir datasource by name rather
# than hardcoding its UID directly, so the dashboards keep resolving
# correctly if the datasource is ever recreated (UID would change, name
# wouldn't). Confirmed via the stack's /api/datasources: this is the
# isDefault=true Prometheus datasource for shortreindeer1185.
data "grafana_data_source" "prometheus" {
  name = "grafanacloud-shortreindeer1185-prom"
}

locals {
  prometheus_uid = data.grafana_data_source.prometheus.uid
}

resource "grafana_folder" "prospect_tracker" {
  title = var.folder_title
}

resource "grafana_dashboard" "app_health" {
  folder = grafana_folder.prospect_tracker.uid
  config_json = templatefile("${path.module}/dashboards/app-health.json.tpl", {
    prometheus_uid = local.prometheus_uid
  })
}

resource "grafana_dashboard" "business_funnel" {
  folder = grafana_folder.prospect_tracker.uid
  config_json = templatefile("${path.module}/dashboards/business-funnel.json.tpl", {
    prometheus_uid = local.prometheus_uid
  })
}

# SLO-style alert rules - demonstrates proactive detection, not just
# after-the-fact dashboards. No custom contact point wired up (would need a
# real destination address); rules route through the stack's existing
# default notification policy.
resource "grafana_rule_group" "prospect_api_slos" {
  name             = "prospect-api-slos"
  folder_uid       = grafana_folder.prospect_tracker.uid
  interval_seconds = 60

  rule {
    name      = "High error rate (5xx)"
    condition = "threshold"
    for       = "5m"

    data {
      ref_id         = "query"
      datasource_uid = local.prometheus_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "query"
        expr       = "sum(rate(http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\", http_status_code=~\"5..\"}[5m]))"
        instant    = false
        range      = true
        intervalMs = 15000
      })
    }

    data {
      ref_id         = "reduce"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "reduce"
        type       = "reduce"
        reducer    = "last"
        expression = "query"
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "threshold"
        type       = "threshold"
        expression = "reduce"
        conditions = [{
          evaluator = { type = "gt", params = [0.1] }
        }]
      })
    }

    annotations = {
      description = "prospect-api 5xx rate has exceeded 0.1 req/s for 5 minutes."
    }
  }

  rule {
    name      = "High p95 latency"
    condition = "threshold"
    for       = "5m"

    data {
      ref_id         = "query"
      datasource_uid = local.prometheus_uid
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "query"
        expr       = "histogram_quantile(0.95, sum(rate(http_server_duration_milliseconds_bucket{service_name=\"prospect-tracker-api\"}[5m])) by (le))"
        instant    = false
        range      = true
        intervalMs = 15000
      })
    }

    data {
      ref_id         = "reduce"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "reduce"
        type       = "reduce"
        reducer    = "last"
        expression = "query"
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        refId      = "threshold"
        type       = "threshold"
        expression = "reduce"
        conditions = [{
          evaluator = { type = "gt", params = [1000] }
        }]
      })
    }

    annotations = {
      description = "prospect-api p95 latency has exceeded 1000ms for 5 minutes."
    }
  }
}
