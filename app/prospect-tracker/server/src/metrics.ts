import { metrics } from "@opentelemetry/api";
import { pool } from "./db/pool.js";
import { PROSPECT_STAGES } from "./stages.js";

const meter = metrics.getMeter("prospect-tracker-api");

export const prospectsCreatedTotal = meter.createCounter("prospects_created_total", {
  description: "Prospects created, by initial stage.",
});

export const stageTransitionsTotal = meter.createCounter("prospect_stage_transitions_total", {
  description: "Prospect stage changes, labeled by from/to stage.",
});

// Purpose-built rather than trying to tag the auto-instrumented HTTP
// metric: this instrumentation version drops custom span attributes when
// deriving http_server_duration_milliseconds's own label set, so a
// dedicated counter is the reliable way to distinguish synthetic checks
// (Cloud Scheduler) from real requests, rather than a fragile label.
export const syntheticCheckTotal = meter.createCounter("synthetic_check_total", {
  description: "Outside-in synthetic health checks (Cloud Scheduler), by result.",
});

// Observable gauge: queried on each metrics export rather than incremented
// inline, so it always reflects the live count per stage - this is what
// powers the funnel dashboard's "current pipeline" view.
meter.createObservableGauge("prospects_by_stage", {
  description: "Current number of prospects in each pipeline stage.",
}).addCallback(async (result) => {
  const { rows } = await pool.query<{ stage: string; count: string }>(
    `SELECT stage, count(*) FROM prospects GROUP BY stage`
  );
  const counts = new Map(rows.map((row) => [row.stage, Number(row.count)]));
  for (const stage of PROSPECT_STAGES) {
    result.observe(counts.get(stage) ?? 0, { stage });
  }
});

// Dollar-denominated business metrics - counts alone don't answer "how much
// is riding on this pipeline," which is the number a financial-services
// stakeholder actually asks first.

meter.createObservableGauge("pipeline_value_at_risk_dollars", {
  description: "Sum of estimated_value for prospects still active in the pipeline (excludes client/lost).",
}).addCallback(async (result) => {
  const { rows } = await pool.query<{ stage: string; total: string | null }>(
    `SELECT stage, sum(estimated_value) AS total
     FROM prospects
     WHERE stage NOT IN ('client', 'lost')
     GROUP BY stage`
  );
  for (const row of rows) {
    result.observe(Number(row.total ?? 0), { stage: row.stage });
  }
});

meter.createObservableGauge("projected_revenue_dollars", {
  description: "Sum of estimated_value * service_fee for prospects with both fields set, by stage.",
}).addCallback(async (result) => {
  const { rows } = await pool.query<{ stage: string; total: string | null }>(
    `SELECT stage, sum(estimated_value * service_fee) AS total
     FROM prospects
     WHERE estimated_value IS NOT NULL AND service_fee IS NOT NULL
     GROUP BY stage`
  );
  for (const row of rows) {
    result.observe(Number(row.total ?? 0), { stage: row.stage });
  }
});

meter.createObservableGauge("advisor_pipeline_value_dollars", {
  description: "Sum of estimated_value for each advisor's active (non-client/lost) prospects.",
}).addCallback(async (result) => {
  const { rows } = await pool.query<{ advisor: string; total: string | null }>(
    `SELECT a.name AS advisor, sum(p.estimated_value) AS total
     FROM prospects p
     JOIN advisors a ON a.id = p.advisor_id
     WHERE p.stage NOT IN ('client', 'lost')
     GROUP BY a.name`
  );
  for (const row of rows) {
    result.observe(Number(row.total ?? 0), { advisor: row.advisor });
  }
});
