---
name: build-push
description: Build a container image with a semantic version tag and push it to Artifact Registry. Use when app code (backend/frontend) is ready to become a new deployable image, not for local-only test builds.
---

Build and publish a versioned image. Project/region facts come from `INFRA_CONTEXT.md` at the repo root — read it rather than assuming values, since it's the source of truth for what's actually provisioned.

## 0. Source
App code lives under `app/`. If there's more than one buildable subfolder (each with its own Dockerfile), ask which one to build rather than guessing or building all of them. This skill doesn't clone anything external, it just builds whatever's in the target subfolder at invocation time.

## 1. Determine the next version
- **Tag scheme is decided (2026-08-11), don't re-ask:** tags are per-service prefixed, `<service>-vX.Y.Z` (e.g. `game-api-v0.3.1`, `game-engine-v0.1.1`) — the repo's older flat `vX.Y.Z` tags predate this and aren't per-service, leave them alone. Find the latest matching tag for whatever's being built: `git tag --list '<service>-v*' --sort=-v:refname | head -1`. If none exists for that service yet, start at `<service>-v0.1.0`.
- Default bump is **patch** (`vX.Y.Z` → `vX.Y.(Z+1)`). Only bump minor/major if the user explicitly says so in the request that invoked this skill.

## 2. Ensure the Artifact Registry repo exists
The repo is defined in `main.tf`, same as every other GCP resource in this project — never create it with `gcloud`. If `tofu output artifact_registry_repo` fails or the repo doesn't actually exist yet, that means `main.tf` hasn't been applied: run `tofu plan`/`tofu apply` (show the plan first, same as `/safe-pr` does) rather than reaching for `gcloud artifacts repositories create`.

## 3. Build
Always build for `linux/amd64` explicitly — Cloud Run runs amd64, and building on Apple Silicon without this flag produces an arm64 image that fails at deploy time. This is a standing rule, not optional. Build context is the target subfolder from step 0. The image tag itself stays plain semver (`vX.Y.Z`, no service prefix — the prefix only applies to the git tag in step 5, since the image name/path already disambiguates the service):
```
docker build --platform linux/amd64 \
  -t <region>-docker.pkg.dev/<project_id>/<repo-name>/<image-name>:vX.Y.Z \
  <path-to-target-subfolder>
```

## 4. Push
```
docker push <region>-docker.pkg.dev/<project_id>/<repo-name>/<image-name>:vX.Y.Z
```

## 5. Tag the release
```
git tag <service>-vX.Y.Z
git push origin <service>-vX.Y.Z
```
**Skip this step (don't tag/push, just say why) if the source that went into this image isn't actually committed** — e.g. live-build rehearsal code deliberately left uncommitted per `PLAN.md`'s prep-scope rule. A tag on `HEAD` that doesn't match the image's real source is misleading, and pushing it puts a public tag on shared history for code that isn't there. Tag normally once the corresponding commit lands.

## 6. Report
Print the full pushed image URI (needed to update the Cloud Run service's `image` field) and the git tag created (or, if skipped per the rule above, say so explicitly). Don't update `main.tf`'s Cloud Run image yourself unless the user asks — this skill's job ends at "image exists and is tagged," not deploying it.
