# Infra context (for the live-build agent)

Reference facts about infra that's already provisioned, so the live-build
session doesn't need to re-derive them via `gcloud`/`tofu output`. Source of
truth is always `infra/main.tf` + `tofu output` — if anything here looks
stale, trust those over this file.

## Project

Single GCP project, everything below lives in it (no cross-project split):

| Field | Value |
|---|---|
| Project ID | `backend-500517` |
| Project number | `923334354359` |
| Region | `us-central1` |

## Networking

| Field | Value |
|---|---|
| VPC | `default` |
| `default` subnet (us-central1) | `10.128.0.0/20` |
| PSA connection | `google_service_networking_connection.psa_connection` — shared by Apigee, Cloud SQL, Memorystore |
| `apigee-psa-range` (reserved, /16) | `10.120.0.0/16` |
| `data-psa-range` (reserved, /20) | `10.16.80.0/20` |

Note: GCP allocates PSA-connected service IPs from whichever reserved range
has room, not strictly by the range's name — e.g. Redis actually landed in
`apigee-psa-range` below, not `data-psa-range`. Don't assume the name predicts
the assigned IP's range.

## Data stores

| Resource | Value |
|---|---|
| Cloud SQL instance | `rps-postgres` (Postgres 16, `db-f1-micro`, edition `ENTERPRISE`, zonal, no HA/backups) |
| Postgres private IP | `10.16.80.3` |
| Postgres database | `rps` |
| Postgres user | `rps_app` |
| Postgres password | **not in Terraform state.** Held in Secret Manager, secret ID `rps-db-password` (`tofu output db_password_secret_id`). Fetch at runtime with `gcloud secrets versions access latest --secret=rps-db-password --project=backend-500517`, or via the Secret Manager client library from `game-api`'s runtime service account (already granted `roles/secretmanager.secretAccessor` on this secret). |
| Redis instance | `rps-leaderboard-cache` (`BASIC`, 1GB, `PRIVATE_SERVICE_ACCESS`, no AUTH — network-isolated only) |
| Redis host | `10.120.115.11` (port 6379, default) |

## Load balancer / edge

| Resource | Value |
|---|---|
| Public IP | `34.160.17.87` (`game-api-lb-ip`, global) |
| Domain | `rps.cloudwithgallo.com` |
| Managed SSL cert | `game-api-cert` — status `ACTIVE` |
| Ingress path | forwarding rule (`game-api-https-rule`, :443) → target HTTPS proxy (`game-api-https-proxy`) → URL map (`game-api-lb`) → backend service (`game-api-backend`) → serverless NEG (`game-api-neg`) → Cloud Run (`game-api`) |
| WAF | Cloud Armor policy `rps-waf` — blocks XSS (`xss-stable`) + SQLi (`sqli-stable`) preconfigured rules, rate limit 100 req/60s per source IP (429 on exceed) |
| Cloud Run ingress | `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` — `*.run.app` URL is not directly reachable; `allUsers` invoker binding is paired with this restriction (network-layer gate, not IAM) |
| Cloud Run service (current) | `game-api`, placeholder image `us-docker.pkg.dev/cloudrun/container/hello`, min=0/max=1, runs as the default compute service account (`923334354359-compute@developer.gserviceaccount.com`) — **swap the image for the real build during the live session, same service name, LB stays untouched** |

## DNS

`cloudwithgallo.com` is registered at GoDaddy. Only the `rps` subdomain is
delegated to Cloud DNS (root domain + other records stay at GoDaddy,
untouched):

| Record | Value |
|---|---|
| Cloud DNS zone | `rps-zone`, `dns_name = rps.cloudwithgallo.com.` |
| NS delegation (at GoDaddy, name=`rps`) | `ns-cloud-e1.googledomains.com.`, `ns-cloud-e2.googledomains.com.`, `ns-cloud-e3.googledomains.com.`, `ns-cloud-e4.googledomains.com.` |
| A record (inside `rps-zone`) | `rps.cloudwithgallo.com.` → `34.160.17.87`, TTL 300 |

## Apigee

| Field | Value |
|---|---|
| Org | `backend-500517` — state `ACTIVE`, billing `EVALUATION`, runtime `CLOUD` |
| Instance | `eval-instance` (`us-central1`) |
| Environment | `eval` |
| Envgroup | `eval-group` |
| Envgroup hostname | **`eval.example.com` — placeholder, does not match `rps.cloudwithgallo.com`.** Needs updating (or a second hostname added) before the Apigee proxy can actually front `game-api` over the real domain. Flagged as a known gap, not yet fixed. |

## Secrets policy

Per `CLAUDE.md`: no secret values live in Terraform/OpenTofu state, ever.
- `google_sql_user.rps_app` has no `password` in config and
  `lifecycle { ignore_changes = [password] }` — the value is set manually
  via `gcloud sql users set-password`.
- The same value is also stored in Secret Manager (`rps-db-password`) via a
  `google_secret_manager_secret` container + IAM binding managed in Tofu —
  but the secret *version* (the actual value) was added out-of-band via
  `gcloud secrets versions add`, never through a
  `google_secret_manager_secret_version` resource, so it never touches state.
- If the live build needs the DB password, resolve it through Secret
  Manager (see table above) — don't ask Henry, and don't look in
  `terraform.tfstate` or `tofu output`.

## What's still a placeholder / deferred to the live build

Per `PLAN.md`'s prep-scope rule — infra above is real and applied; app-layer
work is intentionally left for the live session:
- FastAPI backend (`db.py`/`models.py`/`auth.py`/`cache.py`/`game.py`)
- Dockerfile
- Frontend (React + Firebase Google Sign-In)
- Apigee proxy bundle wiring Apigee → `game-api` (incl. fixing the envgroup hostname above)
- Swapping the placeholder Cloud Run image for the real build
