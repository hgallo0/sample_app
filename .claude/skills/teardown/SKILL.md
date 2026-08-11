---
name: teardown
description: Reset the app layer (Cloud Run image, Apigee proxy routing, local build artifacts) back to a clean rehearsal baseline without touching the slow-to-provision infra (LB, cert, Apigee org, Cloud SQL/Redis instances, or the frontend) or any data in Postgres/Redis, which are left alone on the user's standing instruction. Use between rehearsal cycles, not after the real interview.
---

Reset everything fast-to-rebuild back to baseline so the next rehearsal cycle starts clean. This is the counterpart to `/build-push` and `/safe-pr` — it never touches the slow infra those two also leave alone (LB, managed cert, Apigee org, the Cloud SQL/Redis instances themselves stay running throughout all rehearsal cycles).

**The frontend is permanent substrate, not app-layer state this resets.** As of the "promote frontend to permanent substrate" change, `infra/main.tf`'s committed state already includes the frontend bucket + `url_map` baseline (frontend serves `/`, `/api/*` goes direct to `game-api-backend`) - reverting to committed state does *not* remove it. If you see the root path still serving the frontend (200) after this skill runs, that's correct, not a sign teardown failed. What committed state does *not* include, and what this skill does put back to a blank/live-build-only state: the Cloud Run images (back to the `hello` placeholder) and the Apigee PSC NEG/backend service/envgroup hostname (torn down entirely, since those aren't Tofu-declared outside of a live `apigee-proxy` session).

## 1. Revert uncommitted infra edits
Rehearsal cycles aren't committed per the user's workflow — any live-session edits to `infra/main.tf` (e.g. swapping the Cloud Run `image` field to a rehearsal build, or the `apigee-proxy` agent's PSC NEG/backend/envgroup additions) need to be reverted to the last committed state before re-applying:
```
git status infra/
git diff infra/main.tf
```
If `main.tf` has uncommitted changes, confirm with the user before discarding (`git checkout -- infra/main.tf`) — don't assume every uncommitted diff is a throwaway rehearsal edit; check what it actually is first.

## 2. Reconcile Cloud Run + Apigee routing back to baseline
```
tofu apply
```
With `main.tf` back to its committed state, this drives the Cloud Run services back to the placeholder image and (if a live Apigee session added them) destroys the PSC NEG/backend service, reverting the `url_map` and envgroup hostname to their live-build-only baseline. Show the plan before applying, same as `/safe-pr` does — don't apply blind.

**Known ordering gotcha**: if the plan includes both destroying `google_compute_backend_service.apigee`/`apigee_psc_neg` *and* updating `google_compute_url_map.game_api`, a single `tofu apply` can fail with `resourceInUseByAnotherResource` - the destroys can race ahead of the `url_map` update that stops referencing them. If that happens, apply the `url_map` update alone first (`tofu apply -target=google_compute_url_map.game_api`), then re-run the full apply - this has come up more than once, it's not a one-off fluke.

## 3. Data stores - leave alone
Neither Postgres nor Redis get touched by this skill, on the user's explicit standing instruction (asked and confirmed more than once) - don't truncate tables, don't `FLUSHDB`, don't offer to. Stale/rehearsal game data in either store is fine to leave. If disk/quota ever becomes a real problem, that's a separate, explicitly-requested action, not a default teardown step.

## 4. Local build artifact cleanup
Remove locally-built Docker images from this rehearsal cycle (check `docker images` for anything matching what `/build-push` just built, then `docker rmi`) so disk doesn't fill up across repeated cycles. Don't touch Artifact Registry-hosted images unless the user asks — pushed images are cheap to leave and useful for debugging a bad rehearsal after the fact.

## 5. Rehearsal git tags (ask first)
If `/build-push` pushed `vX.Y.Z` tags to `origin` during this rehearsal cycle, they'll pollute real release history. This step is **not automatic** — ask the user whether to delete the tag(s) (`git tag -d`, `git push origin :refs/tags/vX.Y.Z`) before doing it, since it rewrites shared remote history.

## 6. Report
Confirm: Cloud Run is back on the placeholder image, any live-built Apigee routing (PSC NEG/backend/envgroup hostname) is torn down, the frontend is still live at `/` (unchanged - that's expected, not a leftover), local rehearsal images are cleaned up, and Postgres/Redis were deliberately left untouched (not an omission). State clearly if any step was skipped for another reason (e.g. user declined tag cleanup) so the next cycle starts from a known state, not an assumed one.
