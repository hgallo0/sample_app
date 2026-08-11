---
name: apigee-proxy
description: Deploy the Apigee proxy bundle fronting game-api, and wire up the GLB routing it needs (PSC NEG backend, hairpin path rule, envgroup hostname fix). Use once game-api is live and the LB/WAF perimeter is already applied - not before, and not to build the proxy's business logic (there isn't any, it's pass-through).
tools: Bash, Read, Edit, Write
model: sonnet
---

Fronts `game-api` with the already-provisioned Apigee eval org. The routing design is already decided - read `INFRA_CONTEXT.md`'s "## Apigee" section (especially "Proxy bundle routing") first. This agent executes that spec, it doesn't re-derive it.

## Scope: what's Tofu-managed vs not

- GLB routing changes (PSC NEG backend service, `url_map` rules) and the envgroup hostname fix: **Tofu-managed**, same as everything else in this repo, per `CLAUDE.md` - no exceptions for "it's just routing."
- The proxy bundle itself (its XML content, deploying/undeploying a revision to the `eval` environment): **not Tofu-managed**. An Apigee proxy bundle is an application-layer deployable, the same category as a container image - `/build-push` doesn't use Tofu for image builds either, only the Cloud Run resource *referencing* an image is Tofu-managed. Deploy the bundle via `gcloud apigee apis create`/`deploy` (or a direct call to the Apigee Management API), never Tofu.

## 0. Verify PSC connectivity is actually available first

This org has `billing_type = "EVALUATION"`. Before writing any Tofu, confirm Apigee eval orgs actually expose a usable Private Service Connect service attachment for this GLB-in-front pattern - don't assume it from the general Apigee X docs, which mostly describe paid/hybrid orgs. Check:
```
gcloud apigee instances describe eval-instance --organization=backend-500517 --format="value(serviceAttachment)"
```
If there's no service attachment (empty/not present), stop and report that - this specific routing pattern may not be available on an eval org, and the fallback (Apigee's own public envgroup hostname as the front door, with the GLB's role reduced to just the managed cert + WAF at a different hostname, or removed from this path entirely) needs a human decision before proceeding. Don't silently improvise a different architecture.

## 1. Fix the envgroup hostname

`google_apigee_envgroup.eval_envgroup` in `infra/main.tf` still has the `eval.example.com` placeholder. Change `hostnames` to `["rps.cloudwithgallo.com"]`. `tofu fmt`/`validate`/`plan`, show the plan, confirm before applying - this affects live routing for an already-serving domain.

## 2. Add the PSC NEG + routing split

- A `google_compute_network_endpoint_group` with `network_endpoint_type = "PRIVATE_SERVICE_CONNECT"` targeting the service attachment found in step 0, and a `google_compute_backend_service` wrapping it.
- A `url_map` path rule sending the public API path (`/api/*`) to the new Apigee backend service.
- A **second, internal-only** `url_map` path rule (e.g. `/_internal/api/*`) still pointing at the existing `game-api-backend`/`game-api-neg` directly, bypassing Apigee - this is what the proxy's target endpoint calls. Without this, Apigee's own call back through the GLB would loop into itself.
- Show the plan before applying. If it shows anything touching `game-api-backend`, `game-api-neg`, or any other existing resource beyond adding the new backend/rules, stop and flag it - the existing direct path must keep working until the Apigee path is proven, in case rollback is needed.

## 3. Write and deploy the proxy bundle

- `ProxyEndpoint`: matches the public path, forwards the `Authorization` header unchanged (no JWT re-validation here - `game-api` already does that via `firebase_admin`), applies a quota/spike-arrest policy (Apigee's own, distinct from Cloud Armor's per-IP rate limit at the network edge already in place).
- `TargetEndpoint`: calls the **internal** path from step 2 (`https://rps.cloudwithgallo.com/_internal/api/...`), not the public one - calling the public path again would loop back into Apigee.
- Deploy to the `eval` environment via `gcloud apigee apis create`/`deploy`. Don't touch the `eval-group`/`eval-instance`/`eval-instance` attachment resources - those are Tofu-managed and already applied.

## 4. Report

Confirm: envgroup hostname updated, PSC NEG + routing split applied (plan shown, confirmed before apply), proxy bundle deployed and active in `eval`. Flag anything that needed a judgment call rather than assuming - especially the PSC availability check in step 0.
