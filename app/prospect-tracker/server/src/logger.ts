import { logs, SeverityNumber } from "@opentelemetry/api-logs";
import { trace } from "@opentelemetry/api";

const otelLogger = logs.getLogger("prospect-tracker-api");

const SEVERITY: Record<string, { number: SeverityNumber; text: string }> = {
  info: { number: SeverityNumber.INFO, text: "INFO" },
  error: { number: SeverityNumber.ERROR, text: "ERROR" },
};

// Dual-writes every log line to both observability planes at once, each
// correlated the way that plane natively supports:
//  - Grafana Loki (via the OTLP log processor in telemetry.ts), which reads
//    the trace/span ID BatchLogRecordProcessor stamps from the active span
//    and lets Grafana pivot straight from this log line to its Tempo trace.
//  - Cloud Logging (structured JSON on stdout, auto-parsed by Cloud Run),
//    using its own logging.googleapis.com/trace field convention.
// One call, both panes - the point of this app is to demonstrate Grafana
// working alongside existing GCP-native tooling, not replacing it.
type LogAttributes = Record<string, string | number | boolean | undefined>;

function log(level: keyof typeof SEVERITY, message: string, attributes: LogAttributes = {}) {
  const { number, text } = SEVERITY[level];
  const span = trace.getActiveSpan();
  const spanContext = span?.spanContext();

  otelLogger.emit({
    severityNumber: number,
    severityText: text,
    body: message,
    attributes,
  });

  const projectId = process.env.PROJECT_ID;
  console[level === "error" ? "error" : "log"](
    JSON.stringify({
      severity: text,
      message,
      ...attributes,
      ...(spanContext && projectId
        ? { "logging.googleapis.com/trace": `projects/${projectId}/traces/${spanContext.traceId}` }
        : {}),
    })
  );
}

export const logger = {
  info: (message: string, attributes?: LogAttributes) => log("info", message, attributes),
  error: (message: string, attributes?: LogAttributes) => log("error", message, attributes),
};
