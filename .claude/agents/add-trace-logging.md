---
name: add-trace-logging
description: Add request-scoped trace-ID structured logging to a named service (game-api or game-engine) so a single transaction can be followed end-to-end in Cloud Logging. Use once per service, before the next /build-push for that service - this agent edits app code, it doesn't build or deploy.
tools: Bash, Read, Edit, Grep
model: sonnet
---

Adds a trace ID that's generated (or read, if already present) once per incoming request, included in every log line for that request, and propagated to any downstream service call - so `game-api`'s handling of a move and `game-engine`'s resolution of it show up correlated in Cloud Logging, not as two unrelated log streams.

## Which service

both (`game-api` or `game-engine`)  they need different implementations (Python/FastAPI vs Go stdlib).

## Use Cloud Logging's native trace field, not a generic custom one

Cloud Logging has a special structured-log field, `logging.googleapis.com/trace`, formatted as `projects/<project-id>/traces/<trace-id>`. Logs carrying this field get correlated and shown together in the Cloud Logging UI natively - use this exact field name, not an ad-hoc `trace_id` custom field, so the correlation is a first-class UI feature instead of something that needs a manual query every time.

Cloud Run/Cloud Logging auto-parses stdout as structured logs when each line is a single JSON object - no logging agent/library config needed beyond emitting JSON.

## game-api (Python/FastAPI)

- Add ASGI middleware in `main.py` (or a new `middleware.py`) that: reads `X-Trace-Id` from the incoming request header if present (set by the GLB/Apigee upstream - check if either already injects one, e.g. Apigee's `messageid` or a custom header from the proxy bundle from `apigee-proxy` agent's work), otherwise generates one (`uuid4()`).
- Store it somewhere request-scoped that all log calls in that request can reach - a `contextvars.ContextVar`, not a global, since Cloud Run serves concurrent requests.
- Switch logging to emit structured JSON to stdout (Python's `logging` module with a JSON formatter, or plain `print(json.dumps(...))` if simplicity wins) - each line at minimum: `{"severity": ..., "message": ..., "logging.googleapis.com/trace": f"projects/{PROJECT_ID}/traces/{trace_id}"}`. `PROJECT_ID` is already an env var.
- When calling `game-engine` in `game.py`'s `_call_game_engine`, forward the trace ID as a header (e.g. `X-Trace-Id`) alongside the existing `Authorization` bearer token - this is the propagation link.

## game-engine (Go)

- Wrap `handlePlay`/`handleHealthz` (or add a shared middleware func) that reads the `X-Trace-Id` header game-api sends, or generates one via `crypto/rand`/`google/uuid` if absent (so it's still useful when hit directly, e.g. in local testing).
- Replace the existing `log.Printf` calls with structured JSON lines to stdout carrying the same `logging.googleapis.com/trace` field format as game-api, so both services' logs correlate under the identical trace ID for one transaction.

## Verify before finishing

Don't just write the code - run the service locally (or check logs after the next deploy) and confirm actual log lines carry the field in the right format. A field name typo (this field name is exact, not fuzzy-matched by Cloud Logging) silently produces uncorrelated logs that look fine individually, which defeats the entire point.

## Report

Confirm which service was changed, show a sample log line, and note whether propagation end-to-end (game-api's trace ID appearing in game-engine's logs for the same request) still needs a live test to confirm - that's `verify-transaction`'s job, not this agent's.