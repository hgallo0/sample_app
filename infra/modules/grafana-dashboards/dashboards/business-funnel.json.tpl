{
  "title": "Prospect Tracker - Business Funnel",
  "uid": "prospect-tracker-business-funnel",
  "schemaVersion": 39,
  "timezone": "browser",
  "time": { "from": "now-24h", "to": "now" },
  "refresh": "1m",
  "panels": [
    {
      "id": 1,
      "title": "Prospects by stage (current pipeline)",
      "type": "bargauge",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "prospects_by_stage",
          "legendFormat": "{{stage}}",
          "instant": true
        }
      ]
    },
    {
      "id": 2,
      "title": "New prospects created",
      "type": "timeseries",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 0 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum(rate(prospects_created_total[1h])) * 3600",
          "legendFormat": "created/hr"
        }
      ]
    },
    {
      "id": 3,
      "title": "Stage transitions",
      "type": "timeseries",
      "gridPos": { "h": 9, "w": 12, "x": 0, "y": 9 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum by (to) (rate(prospect_stage_transitions_total[1h])) * 3600",
          "legendFormat": "-> {{to}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Proposal-stage conversion (client / proposal_sent, 24h)",
      "type": "stat",
      "gridPos": { "h": 9, "w": 12, "x": 12, "y": 9 },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum(increase(prospect_stage_transitions_total{to=\"client\"}[24h])) / sum(increase(prospect_stage_transitions_total{to=\"proposal_sent\"}[24h]))",
          "legendFormat": "conversion"
        }
      ]
    },
    {
      "id": 5,
      "title": "Pipeline value at risk (total, active prospects)",
      "type": "stat",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 18 },
      "fieldConfig": { "defaults": { "unit": "currencyUSD" } },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum(pipeline_value_at_risk_dollars)",
          "legendFormat": "value at risk",
          "instant": true
        }
      ]
    },
    {
      "id": 6,
      "title": "Projected revenue by stage",
      "type": "bargauge",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 18 },
      "fieldConfig": { "defaults": { "unit": "currencyUSD" } },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "sum by (stage) (projected_revenue_dollars)",
          "legendFormat": "{{stage}}",
          "instant": true
        }
      ]
    },
    {
      "id": 7,
      "title": "Pipeline value by advisor",
      "type": "bargauge",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 18 },
      "fieldConfig": { "defaults": { "unit": "currencyUSD" } },
      "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
      "targets": [
        {
          "datasource": { "type": "prometheus", "uid": "${prometheus_uid}" },
          "expr": "advisor_pipeline_value_dollars",
          "legendFormat": "{{advisor}}",
          "instant": true
        }
      ]
    }
  ]
}
