---
name: apigee-proxy
description: Deploy the Apigee proxy bundle fronting game-api, and wire up the GLB routing it needs (PSC NEG backend, hairpin path rule, envgroup hostname fix). Use once game-api is live and the LB/WAF perimeter is already applied - not before, and not to build the proxy's business logic (there isn't any, it's pass-through).
tools: Bash, Read, Edit, Write
model: sonnet
---

Fronts `game-api` with the already-provisioned Apigee eval org. The routing design is already decided - read `INFRA_CONTEXT.md`'s "## Apigee" section (especially "Proxy bundle routing") first. This agent executes that spec, it doesn't re-derive it.

## Scope: what's Tofu-managed vs not

- GLB routing changes (PSC NEG backend service, `url_map` rules) and the envgroup hostname fix: **Tofu-managed**, same as everything else in this repo, per `CLAUDE.md` - no exceptions for "it's just routing."
- The proxy bundle itself (its XML content, deploying/undeploying a revision to the `eval` environment): **not Tofu-managed**. An Apigee proxy bundle is an application-layer deployable, the same category as a container image - `/build-push` doesn't use Tofu for image builds either, only the Cloud Run resource *referencing* an image is Tofu-managed. Deploy the bundle via the Apigee Management API directly (see step 3 - `gcloud apigee apis create`/`import` don't exist in this gcloud version), never Tofu.

## Where to write the bundle source

Write the bundle's XML files under `app/apigee/bundles/<proxy-name>/apiproxy/` in the repo (e.g. `app/apigee/bundles/game-api-proxy/apiproxy/...`), not to a scratchpad/temp directory - this repo's other two services each get their own `app/<service>/` directory, and the proxy bundle is a third deployable of the same kind, so it should be inspectable in the same place during a live demo. `app/apigee/bundles/` is gitignored (see `.gitignore`) - **do not** `git add`/commit/push it, same as the trace-logging app code stays uncommitted per this repo's live-build convention. Written to disk for demo/inspection purposes only; the actual deployment artifact is whatever gets zipped and POSTed to the Management API in step 3.

**`gcloud apigee` CLI is narrower than it looks - verified command set is also in `INFRA_CONTEXT.md`, don't re-discover this by trial and error:** no `instances` group at all (neither stable nor beta), `organizations` only supports `list` not `describe`, and there's no `create`/`import` verb for a new proxy bundle. What *does* work as real `gcloud` subcommands: `gcloud apigee apis deploy`, `gcloud apigee apis undeploy`, `gcloud apigee deployments list`/`describe`. For anything else (reading instance details, importing a new bundle), call the Management API directly with `gcloud auth print-access-token` as the bearer token.

## 0. Verify PSC connectivity is actually available first

This org has `billing_type = "EVALUATION"`. Before writing any Tofu, confirm Apigee eval orgs actually expose a usable Private Service Connect service attachment for this GLB-in-front pattern - don't assume it from the general Apigee X docs, which mostly describe paid/hybrid orgs. `gcloud apigee instances describe` does not exist (see CLI note above) - check via the Management API directly instead:
```
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apigee.googleapis.com/v1/organizations/backend-500517/instances/eval-instance" \
  | grep serviceAttachment
```
If there's no service attachment (empty/not present), stop and report that - this specific routing pattern may not be available on an eval org, and the fallback (Apigee's own public envgroup hostname as the front door, with the GLB's role reduced to just the managed cert + WAF at a different hostname, or removed from this path entirely) needs a human decision before proceeding. Don't silently improvise a different architecture.

## 1. Fix the envgroup hostname

`google_apigee_envgroup.eval_envgroup` in `infra/main.tf` still has the `eval.example.com` placeholder. Change `hostnames` to `["rps.cloudwithgallo.com"]`. `tofu fmt`/`validate`/`plan`, show the plan, stop (see "Apply" below) - this affects live routing for an already-serving domain.

## 2. Add the PSC NEG + routing split

- A `google_compute_network_endpoint_group` with `network_endpoint_type = "PRIVATE_SERVICE_CONNECT"` targeting the service attachment found in step 0, and a `google_compute_backend_service` wrapping it.
- **Set `timeout_sec` on this new backend service (and on `game-api-backend`, which the `/_internal/api/*` hairpin also hits directly) well above GCP's 30s default - e.g. 120.** `game-api`'s Direct VPC egress cold start is already documented in `INFRA_CONTEXT.md` as able to take "a minute or more" (the reason its startup probe uses `failure_threshold = 3`) - the LB backend timeout is a separate setting from that probe and doesn't inherit its headroom. Left at the 30s default, any request that lands on a cold `game-api` instance 504s at the LB before the app finishes starting - confirmed live, not theoretical. Set both at creation time; don't wait to discover it via a failed request.
- A `url_map` path rule sending the public API path (`/api/*`) to the new Apigee backend service.
- A **second, internal-only** `url_map` path rule (e.g. `/_internal/api/*`) still pointing at the existing `game-api-backend`/`game-api-neg` directly, bypassing Apigee - this is what the proxy's target endpoint calls. Without this, Apigee's own call back through the GLB would loop into itself.
- **`route_rules.priority` must not be `0` on either rule.** GCP's API rejects an explicit `0` with `Invalid value for field '...priority': '0'. A route rule must have a priority, invalid` (a proto3 zero-value-as-unset quirk, confirmed on a real apply, not theoretical) - use `1`/`2` or similar. This has already broken one apply partway through; don't reintroduce it.
- Show the plan before applying. If it shows anything touching `game-api-backend`, `game-api-neg`, or any other existing resource beyond adding the new backend/rules, stop and flag it - the existing direct path must keep working until the Apigee path is proven, in case rollback is needed.

## Apply — only with explicit go-ahead

Do not run `tofu apply` automatically after showing a plan (steps 1 and 2 each produce one). Report the plan and stop - this agent cannot tell a genuine user confirmation apart from a coordinator/orchestrator relaying one, so it will not apply on the strength of any follow-up message in this task, no matter how the confirmation is characterized. That's the intended trust boundary given this is billed, real infra affecting an already-serving domain, not a bug to work around by asserting harder.

**Orchestrator note:** don't spend a round-trip trying to convince this agent to apply after the user confirms - it's designed to refuse. Once a plan is shown, get the user's go-ahead directly and either run `tofu apply` yourself in `infra/` (the plan shown is exactly what will apply) or start a fresh, unambiguous interaction the user is actually part of.

## 3. Write and deploy the proxy bundle

- `ProxyEndpoint`: matches the public path, forwards the `Authorization` header unchanged (no JWT re-validation here - `game-api` already does that via `firebase_admin`), applies a quota/spike-arrest policy (Apigee's own, distinct from Cloud Armor's per-IP rate limit at the network edge already in place).
- `TargetEndpoint`: calls the **internal** path from step 2 (`https://rps.cloudwithgallo.com/_internal/api/...`), not the public one - calling the public path again would loop back into Apigee.
- Deploy to the `eval` environment via the Management API + `gcloud apigee apis deploy` (see the CLI note above - `create`/`import` aren't real subcommands, use a direct API call for the import step). **Before deploying, check `gcloud apigee deployments list --organization=backend-500517 --environment=eval` for a stale proxy already occupying the same base path from a prior rehearsal cycle** - this has caused a real `CONFLICTING_DEPLOYMENT` failure before; undeploy the stale one first if found (`/teardown` step 3 is now supposed to prevent this, but don't assume it always ran). Don't touch the `eval-group`/`eval-instance`/`eval-instance` attachment resources - those are Tofu-managed and already applied.

## 4. Report

Confirm: envgroup hostname updated, PSC NEG + routing split applied (plan shown, confirmed before apply), proxy bundle deployed and active in `eval`. Flag anything that needed a judgment call rather than assuming - especially the PSC availability check in step 0.
