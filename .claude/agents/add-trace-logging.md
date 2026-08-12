---
name: add-trace-logging
description: Add request-scoped trace-ID structured logging AND real OpenTelemetry spans to a named service (game-api or game-engine) so a single transaction can be followed end-to-end in both Cloud Logging and the Cloud Trace waterfall view. Use once per service, before the next /build-push for that service - this agent edits app code, it doesn't build or deploy.
tools: Bash, Read, Edit, Grep
model: sonnet
---

Adds a trace ID that's generated (or read, if already present) once per incoming request, included in every log line for that request, and propagated to any downstream service call - so `game-api`'s handling of a move and `game-engine`'s resolution of it show up correlated in Cloud Logging, not as two unrelated log streams. Also instruments both services with OpenTelemetry so the same transaction produces a real queryable trace with spans/durations, not just correlated log lines.

## Which service

both (`game-api` or `game-engine`)  they need different implementations (Python/FastAPI vs Go stdlib).

## Use Cloud Logging's native trace field, not a generic custom one

Cloud Logging has a special structured-log field, `logging.googleapis.com/trace`, formatted as `projects/<project-id>/traces/<trace-id>`. Logs carrying this field get correlated and shown together in the Cloud Logging UI natively - use this exact field name, not an ad-hoc `trace_id` custom field, so the correlation is a first-class UI feature instead of something that needs a manual query every time.

Cloud Run/Cloud Logging auto-parses stdout as structured logs when each line is a single JSON object - no logging agent/library config needed beyond emitting JSON.

## Also add real OpenTelemetry spans - log-field correlation alone isn't enough

Confirmed live (2026-08-12 rehearsal): the `logging.googleapis.com/trace` field above only groups log lines in the Logs Explorer results list. It does **not** create an actual Trace span - clicking into a log entry's "Details" panel to see duration/waterfall data fails with "Trace not found: `<trace-id>`", because no span was ever recorded against that ID. That's expected without this section, not a bug to route around - it means the original ask ("follow a transaction end-to-end") was only half-satisfied by log correlation. Instrument both services with OpenTelemetry, exported to Cloud Trace, so the same trace ID also has real spans:

- **game-api (Python):** `opentelemetry-sdk`, `opentelemetry-exporter-gcp-trace`, `opentelemetry-instrumentation-fastapi` (auto-creates a server span per incoming request), `opentelemetry-instrumentation-httpx` (auto-creates a client span around the call to game-engine and propagates span context on the outbound request automatically - once this is in place, the hand-rolled `X-Trace-Id` header below becomes a fallback/log-correlation aid rather than the only propagation path).
- **game-engine (Go):** `go.opentelemetry.io/otel`, `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` (wraps the handlers to create a server span from the incoming propagated context automatically), and `github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/trace` to export to Cloud Trace.
- Both exporters need the `cloudtrace.googleapis.com` API enabled and `roles/cloudtrace.agent` on the runtime service account - if either is missing, that's a Tofu change (`google_project_service` in the `services` list, an IAM binding alongside the existing Cloud SQL/Redis ones in `main.tf`), not something to grant via `gcloud` - flag it rather than silently broadening a role.
- Derive the `logging.googleapis.com/trace` field's trace ID from the OTel span's own trace ID (already hex-formatted, same shape) instead of a separately-generated one, so the Logs Explorer correlation and the Trace waterfall view are always looking at the same trace, not two different IDs for the same transaction.
- This is additive to, not a replacement for, the header-priority guidance below - OTel's own context propagation (W3C `traceparent`, added automatically by the instrumentation libraries above) sidesteps the `X-Cloud-Trace-Context`-vs-`X-Trace-Id` conflict entirely once it's the thing actually carrying span context between services. Keep `X-Trace-Id` too, since it's still what drives the Cloud Logging field on each line.

## game-api (Python/FastAPI)

- Add ASGI middleware in `main.py` (or a new `middleware.py`) that: reads `X-Trace-Id` from the incoming request header if present (set by the GLB/Apigee upstream - check if either already injects one, e.g. Apigee's `messageid` or a custom header from the proxy bundle from `apigee-proxy` agent's work), otherwise generates one (`uuid4()`).
- Store it somewhere request-scoped that all log calls in that request can reach - a `contextvars.ContextVar`, not a global, since Cloud Run serves concurrent requests.
- Switch logging to emit structured JSON to stdout (Python's `logging` module with a JSON formatter, or plain `print(json.dumps(...))` if simplicity wins) - each line at minimum: `{"severity": ..., "message": ..., "logging.googleapis.com/trace": f"projects/{PROJECT_ID}/traces/{trace_id}"}`. `PROJECT_ID` is already an env var.
- When calling `game-engine` in `game.py`'s `_call_game_engine`, forward the trace ID as a header (e.g. `X-Trace-Id`) alongside the existing `Authorization` bearer token - this is the propagation link.

## game-engine (Go)

- Wrap `handlePlay`/`handleHealthz` (or add a shared middleware func) that reads the `X-Trace-Id` header game-api sends, or generates one via `crypto/rand`/`google/uuid` if absent (so it's still useful when hit directly, e.g. in local testing).
- Replace the existing `log.Printf` calls with structured JSON lines to stdout carrying the same `logging.googleapis.com/trace` field format as game-api, so both services' logs correlate under the identical trace ID for one transaction.
- **If also checking `X-Cloud-Trace-Context` as a fallback header, `X-Trace-Id` must be checked first, always — not the other way round.** Confirmed live (2026-08-12 rehearsal, cost a full extra fix/rebuild/redeploy/re-verify cycle): game-api calls game-engine's public `*.run.app` URL, which passes through Google Front End. GFE stamps its own fresh `X-Cloud-Trace-Context` on that hop regardless of what the caller sent — checking that header first silently discards game-api's real propagated trace ID and breaks cross-service correlation every time, not just occasionally. This is structural to the topology (game-engine has no ingress path that isn't fronted by GFE), so it will recur on every rehearsal unless `X-Trace-Id` wins the priority order.

## Verify before finishing

Don't just write the code - run the service locally (or check logs after the next deploy) and confirm actual log lines carry the field in the right format. A field name typo (this field name is exact, not fuzzy-matched by Cloud Logging) silently produces uncorrelated logs that look fine individually, which defeats the entire point.

## Report

Confirm which service was changed, show a sample log line, confirm the OpenTelemetry exporter is wired up (and whether `cloudtrace.googleapis.com`/IAM needed a Tofu change to enable it), and note whether propagation end-to-end - game-api's trace ID appearing in game-engine's logs for the same request, *and* a real span showing up in Cloud Trace for that ID - still needs a live test to confirm. That's `verify-transaction`'s job, not this agent's; it should check both the Logs Explorer correlation and the Trace waterfall view, not just the former.