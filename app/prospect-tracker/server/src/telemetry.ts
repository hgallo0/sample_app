// Loaded via `node --import ./dist/telemetry.js` so instrumentation hooks are
// registered before express/pg are ever imported by the app itself - required
// for auto-instrumentation to work under ESM (see @opentelemetry/instrumentation
// docs on --import vs. a plain top-of-file import).
import { diag, DiagConsoleLogger, DiagLogLevel } from "@opentelemetry/api";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPLogExporter } from "@opentelemetry/exporter-logs-otlp-http";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { Resource } from "@opentelemetry/resources";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { BatchLogRecordProcessor } from "@opentelemetry/sdk-logs";
import { PeriodicExportingMetricReader } from "@opentelemetry/sdk-metrics";
import { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } from "@opentelemetry/semantic-conventions";

// Temporary: OTel is silent by default, which is exactly why the missing
// HTTP trace spans went undiagnosed via app logs alone. WARN surfaces
// exporter/instrumentation problems without being as noisy as DEBUG.
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.WARN);

// OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_EXPORTER_OTLP_HEADERS come from the
// environment (endpoint is plain, headers carry the Grafana Cloud API key
// and are sourced from Secret Manager - see infra/main.tf). Exporters below
// append /v1/traces and /v1/metrics to the shared base endpoint per the OTLP
// HTTP spec, so no per-signal endpoint config is needed.
const sdk = new NodeSDK({
  resource: new Resource({
    [ATTR_SERVICE_NAME]: "prospect-tracker-api",
    [ATTR_SERVICE_VERSION]: process.env.SERVICE_VERSION ?? "dev",
  }),
  traceExporter: new OTLPTraceExporter(),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter(),
    exportIntervalMillis: 15000,
  }),
  // BatchLogRecordProcessor stamps each log record with the trace/span ID of
  // whatever span is active when it's emitted (see logger.ts) - that's what
  // lets Grafana pivot from a Loki log line straight to its Tempo trace,
  // instead of correlating by field name the way Cloud Logging does.
  logRecordProcessors: [new BatchLogRecordProcessor(new OTLPLogExporter())],
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();

process.on("SIGTERM", () => {
  sdk.shutdown().finally(() => process.exit(0));
});
