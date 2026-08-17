{
  "title": "Prospect Tracker - App Health",
  "uid": "prospect-tracker-app-health",
  "schemaVersion": 39,
  "timezone": "browser",
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "panels": [
    {
      "id": 1,
      "title": "Request rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum(rate(http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\"}[5m]))",
          "legendFormat": "requests/s"
        }
      ]
    },
    {
      "id": 2,
      "title": "Latency (p50 / p95)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "histogram_quantile(0.5, sum(rate(http_server_duration_milliseconds_bucket{service_name=\"prospect-tracker-api\"}[5m])) by (le))",
          "legendFormat": "p50"
        },
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "histogram_quantile(0.95, sum(rate(http_server_duration_milliseconds_bucket{service_name=\"prospect-tracker-api\"}[5m])) by (le))",
          "legendFormat": "p95"
        }
      ]
    },
    {
      "id": 3,
      "title": "Error rate (5xx)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum(rate(http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\", http_status_code=~\"5..\"}[5m]))",
          "legendFormat": "5xx/s"
        }
      ]
    },
    {
      "id": 4,
      "title": "Requests by status code",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum by (http_status_code) (rate(http_server_duration_milliseconds_count{service_name=\"prospect-tracker-api\"}[5m]))",
          "legendFormat": "{{http_status_code}}"
        }
      ]
    }
  ]
}
