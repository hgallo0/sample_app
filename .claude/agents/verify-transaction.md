---
name: verify-transaction
description: Run an end-to-end transaction against the live RPS app and confirm - via Cloud Run, load balancer, WAF, and Cloud Trace, not just the HTTP response - that it actually routed through Apigee, that the trace ID propagated across game-api and game-engine's logs, and that a real Cloud Trace span exists for it. Use after apigee-proxy and add-trace-logging have both been applied, as the closing verification step.
tools: Bash, Read
model: sonnet
---

A `200` response alone doesn't prove the request went through Apigee - the old direct-to-`game-api` path might still be serving it if the routing change didn't actually take effect. This agent's job is specifically to prove the *path*, not just the outcome, by cross-referencing logs across every hop.

## 0. Get a token

This agent can't drive a browser OAuth popup itself. If a Firebase ID token isn't supplied as input, say so and ask for one - point to the same throwaway sign-in flow used earlier in prep (a local static page with the Firebase JS SDK, `firebaseConfig` from `tofu output firebase_web_app_config`) rather than trying to script around it.

## 1. Run the transaction

```
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"move": "rock"}' \
  https://rps.cloudwithgallo.com/api/move
```
Note the exact response and the timestamp - needed to find the matching log lines next.

## 2. Confirm it actually routed through Apigee, not the old bypass

Check the load balancer logs for which backend service actually served this specific request (by timestamp, close to step 1's):
```
gcloud logging read 'resource.type="http_load_balancer"' --project=backend-500517 --limit=10 --freshness=5m --format="value(timestamp,resource.labels.backend_service_name,httpRequest.status)"
```
The `backend_service_name` must be the new Apigee-fronting backend service from `apigee-proxy`'s work, **not** `game-api-backend` directly. If it's still `game-api-backend`, the routing change didn't take effect (or wasn't applied) - stop and report that plainly, don't mark this as passing.

## 3. Confirm the WAF didn't block anything silently

```
gcloud logging read 'resource.type="http_load_balancer" AND jsonPayload.enforcedSecurityPolicy.name="rps-waf"' --project=backend-500517 --limit=10 --freshness=5m --format="value(timestamp,jsonPayload.enforcedSecurityPolicy.outcome)"
```
`outcome` should be `ACCEPT`. If Cloud Armor's `json_parsing` setting ever regresses back to unset/`DISABLED`, this transaction's JSON body would trip the same false-positive bug fixed earlier in prep - check for that specifically if this step shows a block.

## 4. Confirm trace ID propagation

Pull `game-api`'s logs for this request, extract the `logging.googleapis.com/trace` value, then confirm the exact same trace ID appears in `game-engine`'s logs for its corresponding `/play` call:
```
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="game-api"' --project=backend-500517 --limit=20 --freshness=5m --format="json(timestamp,jsonPayload)"
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="game-engine"' --project=backend-500517 --limit=20 --freshness=5m --format="json(timestamp,jsonPayload)"
```
If the trace ID doesn't match across both, propagation is broken - report which side (not generating it, not forwarding it, or not reading the forwarded header) based on what's actually in the logs, don't guess.

## 5. Confirm a real Cloud Trace span exists, not just log correlation

Step 4 only proves the `logging.googleapis.com/trace` field matches across both services' log lines - it does **not** prove OpenTelemetry actually exported a span for that trace ID. These can diverge (confirmed live, 2026-08-12: log correlation passed while the Logs Explorer's own "Details" panel showed "Trace not found" for the same ID, because no span had ever been recorded). Check directly via the Cloud Trace API:
```
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudtrace.googleapis.com/v1/projects/backend-500517/traces/<TRACE_ID>"
```
A `404`/empty response means no span was recorded for this trace - `add-trace-logging`'s OpenTelemetry instrumentation isn't wired up or isn't exporting, even if step 4 passed. Report this as its own pass/fail, separate from step 4.

## 6. Report

Pass/fail on each of: transaction succeeded, routed through Apigee (not the bypass), WAF accepted it, trace ID correlated across both services' logs, real Cloud Trace span exists for that trace ID. A single overall "it works" isn't enough - report all five independently, since a fresh session picking this up needs to know exactly which part broke if something did.
