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

  # SLI #4 - telemetry freshness. Doesn't fit the ratio/burn-rate SLO model
  # below (staleness isn't a success/total counter), so it's a plain
  # threshold alert instead - the standard SRE pattern for pipeline
  # freshness SLIs. Reuses prospects_by_stage (already exported every 15s)
  # as a heartbeat rather than adding new instrumentation: if its timestamp
  # stops advancing, the OTel export pipeline to Grafana Cloud is stuck and
  # every dashboard here is no longer real-time.
  rule {
    name      = "Telemetry pipeline stale"
    condition = "threshold"
    for       = "2m"

    data {
      ref_id         = "query"
      datasource_uid = local.prometheus_uid
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        refId   = "query"
        expr    = "time() - timestamp(sum(prospects_by_stage))"
        instant = true
        range   = false
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        refId      = "threshold"
        type       = "threshold"
        expression = "query"
        conditions = [{
          evaluator = { type = "gt", params = [60] }
        }]
      })
    }

    annotations = {
      description = "prospects_by_stage hasn't updated in over 60s - the OTel export pipeline to Grafana Cloud may be stuck, so dashboards are no longer real-time."
    }
  }
}

# SLI #1 - availability. % of /api/* requests that don't return a 5xx,
# measured at prospect-api ingress (post-WAF) via the auto-instrumented HTTP
# server duration metric, split by status code.
resource "grafana_slo" "availability" {
  name        = "prospect-api-availability"
  description = "SLI #1: % of /api/* requests returning non-5xx, measured at prospect-api ingress."
  folder_uid  = grafana_folder.prospect_tracker.uid

  query {
    type = "ratio"
    ratio {
      success_metric = "http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\", http_status_code!~\"5..\"}"
      total_metric   = "http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\"}"
    }
  }

  objectives {
    value  = 0.995
    window = "28d"
  }

  destination_datasource {
    uid = local.prometheus_uid
  }

  alerting {
    fastburn {
      annotation {
        key   = "description"
        value = "prospect-api availability error budget burning fast - investigate immediately."
      }
    }
    slowburn {
      annotation {
        key   = "description"
        value = "prospect-api availability error budget burning slowly - review before it depletes."
      }
    }
  }

  label {
    key   = "sli"
    value = "availability"
  }
}

# SLI #2 - latency, expressed as a threshold ratio ("% of requests under
# 250ms") rather than a raw p95 query - burn-rate math needs a success/total
# counter pair, and this is the standard way to turn a percentile target
# into one (Google SRE Workbook ch.5). 250ms is the nearest OTel default
# histogram bucket boundary to the 300ms target from the SLI writeup.
#
# Scoped to all /api/* traffic, not just /api/prospects: confirmed live
# against the real exported series (this instrumentation-http version,
# 0.54.2, never populates http.route on the metric despite
# instrumentation-express setting rpcMetadata.route - only http_method,
# http_status_code, http_flavor, http_scheme, net_host_name/port actually
# exist as labels). Route-level scoping would need a deeper instrumentation
# fix; this still measures the real SLI, just across the whole API surface.
resource "grafana_slo" "latency" {
  name        = "prospect-api-latency"
  description = "SLI #2: % of prospect-api requests completing under 250ms."
  folder_uid  = grafana_folder.prospect_tracker.uid

  query {
    type = "ratio"
    ratio {
      success_metric = "http_server_duration_milliseconds_bucket{service_name=\"prospect-tracker-api\", le=\"250\"}"
      total_metric   = "http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\"}"
    }
  }

  objectives {
    value  = 0.95
    window = "28d"
  }

  destination_datasource {
    uid = local.prometheus_uid
  }

  alerting {
    fastburn {
      annotation {
        key   = "description"
        value = "prospect-api latency error budget burning fast - /api/prospects is materially slower than target."
      }
    }
    slowburn {
      annotation {
        key   = "description"
        value = "prospect-api latency error budget burning slowly."
      }
    }
  }

  label {
    key   = "sli"
    value = "latency"
  }
}

# SLI #3 - write correctness. % of prospect stage-transition writes
# (PUT /api/prospects/:id) that commit without a 5xx. This is the SLI that
# would have caught the real incident hit earlier in this build: a missing
# table-level GRANT caused every write to fail with Postgres 42501
# (permission denied for table advisors) while /api/health stayed green -
# a pure uptime SLI would have missed it entirely.
#
# Filtered on http_method="PUT" alone, not a route match: confirmed live
# that http.route never reaches the exported metric (see the latency SLO's
# comment above) and the real label is http_method, not http_request_method.
# PUT is functionally equivalent to route-scoping here anyway - it's the
# only HTTP method this API uses for stage-transition writes.
resource "grafana_slo" "write_correctness" {
  name        = "prospect-api-write-correctness"
  description = "SLI #3: % of PUT requests (stage-transition writes) that commit without a 5xx."
  folder_uid  = grafana_folder.prospect_tracker.uid

  query {
    type = "ratio"
    ratio {
      success_metric = "http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\", http_method=\"PUT\", http_status_code!~\"5..\"}"
      total_metric   = "http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\", http_method=\"PUT\"}"
    }
  }

  objectives {
    value  = 0.999
    window = "28d"
  }

  destination_datasource {
    uid = local.prometheus_uid
  }

  alerting {
    fastburn {
      annotation {
        key   = "description"
        value = "prospect-api write-correctness error budget burning fast - stage-transition writes are failing (DB permission/constraint errors)."
      }
    }
    slowburn {
      annotation {
        key   = "description"
        value = "prospect-api write-correctness error budget burning slowly."
      }
    }
  }

  label {
    key   = "sli"
    value = "write-correctness"
  }
}
