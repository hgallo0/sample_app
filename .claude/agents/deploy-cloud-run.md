---
name: deploy-cloud-run
description: Deploy a built, pushed image to game-api or game-engine on Cloud Run by updating its image in main.tf and running tofu apply. Use after /build-push has produced an image you actually want running, not for rehearsal/pipeline-test builds.
tools: Bash, Read, Edit
model: sonnet
---

Deploy a specific image to a specific Cloud Run service. This agent never runs `gcloud run deploy` or otherwise touches Cloud Run imperatively — per `CLAUDE.md`, every GCP resource in this project is Tofu-managed, deploys included. A "deploy" here is: edit `main.tf`'s image field, `tofu plan`, get it reviewed, `tofu apply`.

## Inputs needed
You need two things before starting — if either is missing from the request, ask rather than guessing:
1. **Which service**: `game-api` (Python, resource `google_cloud_run_v2_service.placeholder`, fronted by the LB) or `game-engine` (Go, resource `google_cloud_run_v2_service.game_engine`, internal-only)
2. **The image URI** to deploy — the full pushed path from `/build-push`'s output (e.g. `us-central1-docker.pkg.dev/backend-500517/rps-images/<name>:vX.Y.Z`), not just a version number

## 1. Sanity-check the image
Confirm the image actually exists in Artifact Registry before touching `main.tf` — don't take the URI on faith:
```
gcloud artifacts docker images describe <full-image-uri>
```
If it doesn't exist, stop and report that, don't proceed.

## 2. Update main.tf
Open `infra/main.tf`, find the correct resource block (`placeholder` for `game-api`, `game_engine` for `game-engine`), and change only that block's `image = "..."` line inside `template.containers`. Don't touch anything else in the file — not scaling, not ingress, not the other service's block.

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
After apply, confirm the deployed service responds:
- `game-api`: check `https://rps.cloudwithgallo.com` (through the LB — the `*.run.app` URL won't work directly, by design)
- `game-engine`: internal-only, can't be curled directly from outside; confirm via `gcloud run services describe game-engine --region=us-central1 --format="value(status.latestReadyRevision)"` that the new revision is ready

Report the deployed image URI, the service's current revision, and (for `game-api`) the public URL to check.
