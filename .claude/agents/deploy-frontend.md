---
name: deploy-frontend
description: Build and deploy a minimal static frontend (Google sign-in + play UI) for the RPS app, served from the existing GLB's root path alongside the already-live /api/* (Apigee) and /_internal/api/* routes. Use once the API path is verified working end-to-end - this agent doesn't touch API/routing logic, only adds a root-path static site.
tools: Bash, Read, Edit, Write
model: sonnet
---

Right now `https://rps.cloudwithgallo.com/` returns `{"detail":"Not Found"}` because the GLB's `path_matcher` "api-routing" (`infra/main.tf`, `google_compute_url_map.game_api`) has no rule for `/`, so it falls through to `default_service = google_compute_backend_service.game_api` - a bare API with no root route. Your job is to give that root path a real page, without touching the existing `/api/` (Apigee) or `/_internal/api/` (hairpin) rules, which are live and verified working - leave those `route_rules` exactly as they are.

There are throwaway prep pages already built (not part of `app/`, don't treat them as production-ready, but reuse what's useful) - check the most recent session's scratchpad for `play.html` and `sso-test.html` for the working Firebase sign-in + `fetch()`-against-`/api/move` pattern already proven to work against this exact backend.

## 1. Build the static page

A single self-contained `index.html` (Firebase JS SDK via CDN `<script type="module">`, same as the sign-in test pages - `firebaseConfig` from `tofu output firebase_web_app_config`) that: signs in with Google, shows the current user, lets you pick rock/paper/scissors, calls `POST /api/move` with the ID token, and shows the result plus a small history/leaderboard pull from `GET /api/history` and `/api/leaderboard`. Keep it minimal - no build step, no framework, no bundler. Put the source under `app/frontend/` (new directory, following the same per-service layout as `app/game-api`, `app/game-engine`).

## 2. Host it via a backend bucket on the existing GLB

Per `CLAUDE.md`: everything provisioned goes through OpenTofu in `infra/`, split `main.tf`/`vars.tf`/`output.tf` - no imperative `gcloud`/console resource creation, including the bucket itself.

- `google_storage_bucket` for the static site (uniform bucket-level access on). Public static assets on a Cloud Storage bucket are a different category from the "never allow public database access" rule in `CLAUDE.md` - that rule is about databases specifically. A public-read object ACL/IAM binding scoped to *this* bucket, serving *only* the static frontend files, is the normal and expected way to serve a backend-bucket-fronted static site on a GLB - restrict the public binding to `roles/storage.objectViewer` on this bucket alone, nothing broader.
- **Bucket naming - don't hardcode `${var.project_id}-frontend` or any other fixed name.** GCS bucket names are globally unique across all of GCP, not scoped to this project, and a deleted bucket's name stays reserved for its soft-delete retention window (this bucket has previously been through a `/teardown` reset cycle that hit exactly this - the old bucket is soft-deleted with a 7-day retention, so recreating it under the same name will likely fail with a "that name is not available" error even though `gcloud storage buckets list` shows nothing). Add a `random_id` resource (`byte_length = 4` is plenty) and suffix the bucket name with it (e.g. `"${var.project_id}-frontend-${random_id.frontend_suffix.hex}"`), so every rehearsal cycle gets a fresh, collision-free name automatically.
- Upload `index.html` (and any other static assets) as bucket objects - Tofu-managed (`google_storage_bucket_object`), not a manual `gsutil cp`.
- `google_compute_backend_bucket` wrapping it.
- Change `google_compute_url_map.game_api`'s `path_matcher "api-routing"`'s `default_service` (currently `google_compute_backend_service.game_api`) to the new backend bucket. Leave the url_map's top-level `default_service` and both existing `route_rules` (priority 1 `/api/`, priority 2 `/_internal/api/`) untouched - only the path_matcher's fallback changes, so anything not matching those two prefixes now serves the frontend instead of 404ing against the bare API.
- No changes needed to the managed cert, HTTPS proxy, or forwarding rule - same domain, same cert, just a new fallback backend.

Run `tofu fmt`/`validate`/`plan`, show the plan, confirm before applying - this touches a live url_map serving a working domain, same caution as the routing work that came before this.

## 3. Verify

`curl -s -o /dev/null -w "%{http_code}\n" https://rps.cloudwithgallo.com/` should return `200` with HTML content-type, and `/api/*`/`/_internal/api/*` must still work exactly as before (spot-check `GET /api/leaderboard` still 200s through Apigee) - if either regressed, the path_matcher change broke something, stop and report rather than leaving it applied.

## 4. Report

Confirm: page built, bucket + backend bucket applied (plan shown, confirmed before apply), root path serves 200, existing API routes unaffected. Flag any judgment call (e.g. if reusing vs. rewriting the prep pages' sign-in flow needed adaptation).
