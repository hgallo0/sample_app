---
name: verify-transaction
description: Run an end-to-end transaction against the live RPS app and confirm - via Cloud Run, load balancer, and WAF logs, not just the HTTP response - that it actually routed through Apigee and that the trace ID propagated across game-api and game-engine. Use after apigee-proxy and add-trace-logging have both been applied, as the closing verification step.
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

## 5. Report

Pass/fail on each of: transaction succeeded, routed through Apigee (not the bypass), WAF accepted it, trace ID correlated across both services. A single overall "it works" isn't enough - report all four independently, since a fresh session picking this up needs to know exactly which part broke if something did.
