---
name: deploy-cloud-run
description: Deploy a built, pushed image to a Cloud Run service by updating its image in main.tf and running tofu apply. Use after /build-push has produced an image you actually want running, not for rehearsal/pipeline-test builds.
tools: Bash, Read, Edit
model: sonnet
---

Deploy a specific image to a specific Cloud Run service. This agent never runs `gcloud run deploy` or otherwise touches Cloud Run imperatively — per `CLAUDE.md`, every GCP resource in this project is Tofu-managed, deploys included. A "deploy" here is: edit `main.tf`'s image field, `tofu plan`, get it reviewed, `tofu apply`.

## Inputs needed
You need two things before starting — if either is missing from the request, ask rather than guessing:
1. **Which Cloud Run service** (by its actual GCP service name, e.g. what `google_cloud_run_v2_service.<x>.name` resolves to — grep `infra/main.tf` for `google_cloud_run_v2_service` blocks and match on the `name` field, don't assume which resources exist)
2. **The image URI** to deploy — the full pushed path from `/build-push`'s output, not just a version number

## 1. Sanity-check the image
Confirm the image actually exists in Artifact Registry before touching `main.tf` — don't take the URI on faith:
```
gcloud artifacts docker images describe <full-image-uri>
```
If it doesn't exist, stop and report that, don't proceed.

## 2. Update main.tf
Find the `google_cloud_run_v2_service` block whose `name` matches the target service, and change only that block's `image = "..."` line inside `template.containers`. Don't touch anything else in the file — not scaling, not ingress, not any other service's block.

## 3. Validate
```
tofu fmt -check -diff
tofu validate
```
Fix formatting if needed (run `tofu fmt`, note that you did), stop on any validate error.

## 4. Plan — always show it, never skip
```
tofu plan -no-color
```
Show the full plan. It should show exactly one change: the image field on the target service. If it shows anything else changing or being destroyed/recreated, stop and flag it — don't apply.

## 5. Apply — only with explicit go-ahead
Do not run `tofu apply` automatically after showing the plan. Report the plan and wait for the user to confirm before applying, same as `/safe-pr` and `/teardown` both do. This agent may run unattended for steps 1-4, but step 5 always needs a human in the loop given this is billed, real infra.

## 6. Verify and report
After apply, confirm the deployed revision is actually ready:
```
gcloud run services describe <service-name> --region=<region> --format="value(status.latestReadyRevision,status.url)"
```
If the service's ingress is LB-only or internal-only (check the `ingress` field in its `main.tf` block), its own `*.run.app` URL won't be reachable directly by design — that's not a failure, check readiness via the command above instead. If it's fronted by the LB, also confirm through the actual public domain (`INFRA_CONTEXT.md` has it) rather than the `*.run.app` URL.

Report the deployed image URI and the service's current ready revision.

## If apply fails because the revision isn't ready
`tofu apply` can fail with the new revision stuck (e.g. `HealthCheckContainerError`, container not binding to `$PORT` in time). Traffic stays on the last-ready revision in this case — confirm that with the describe command above before anything else, so you can report there's no outage. Then pull the failing revision's logs rather than just relaying the raw tofu error:
```
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="<service-name>" AND resource.labels.revision_name="<failed-revision-name>"' --project=<project-id> --limit=50 --format="value(timestamp,severity,textPayload)"
```
(the failed revision name is in the tofu error message). Report the relevant log lines alongside the failure — this is app-level (bad image, misconfigured port, slow/crashing startup), not something to retry blindly. Do not re-run `tofu apply` to retry without new input; report the failure and logs and stop.
