---
name: teardown
description: Reset the app layer (Cloud Run image, DB data, cache) back to a clean rehearsal baseline without touching the slow-to-provision infra (LB, cert, Apigee org, Cloud SQL/Redis instances themselves). Use between rehearsal cycles, not after the real interview.
---

Reset everything fast-to-rebuild back to baseline so the next rehearsal cycle starts clean. This is the counterpart to `/build-push` and `/safe-pr` — it never touches the slow infra those two also leave alone (LB, managed cert, Apigee org, the Cloud SQL/Redis instances themselves stay running throughout all rehearsal cycles).

## 1. Revert uncommitted infra edits
Rehearsal cycles aren't committed per the user's workflow — any live-session edits to `infra/main.tf` (e.g. swapping the Cloud Run `image` field to a rehearsal build) need to be reverted to the last committed state before re-applying:
```
git status infra/
git diff infra/main.tf
```
If `main.tf` has uncommitted changes, confirm with the user before discarding (`git checkout -- infra/main.tf`) — don't assume every uncommitted diff is a throwaway rehearsal edit; check what it actually is first.

## 2. Reconcile Cloud Run back to the placeholder
```
tofu apply
```
With `main.tf` back to its committed state, this drives the Cloud Run service back to the placeholder image (`us-docker.pkg.dev/cloudrun/container/hello`). Show the plan before applying, same as `/safe-pr` does — don't apply blind.

## 3. Reset data
- Postgres: truncate the app database's tables (not drop the database/instance) so leaderboard/history data doesn't leak between rehearsal runs. Connect via IAM auth (see `INFRA_CONTEXT.md` for the connection details) as `game_api_iam` - never use the `postgres` admin credentials for this. The `postgres-root-password` secret exists solely for one-off schema/permission admin work and must never be rotated, deleted, or touched by this flow.
- Redis: `FLUSHDB` on the leaderboard cache, not a full instance restart.

## 4. Local build artifact cleanup
Remove locally-built Docker images from this rehearsal cycle (check `docker images` for anything matching what `/build-push` just built, then `docker rmi`) so disk doesn't fill up across repeated cycles. Don't touch Artifact Registry-hosted images unless the user asks — pushed images are cheap to leave and useful for debugging a bad rehearsal after the fact.

## 5. Rehearsal git tags (ask first)
If `/build-push` pushed `vX.Y.Z` tags to `origin` during this rehearsal cycle, they'll pollute real release history. This step is **not automatic** — ask the user whether to delete the tag(s) (`git tag -d`, `git push origin :refs/tags/vX.Y.Z`) before doing it, since it rewrites shared remote history.

## 6. Report
Confirm: Cloud Run is back on the placeholder image, Postgres tables are empty, Redis is flushed, local rehearsal images are cleaned up. State clearly if any step was skipped (e.g. user declined tag cleanup) so the next cycle starts from a known state, not an assumed one.
