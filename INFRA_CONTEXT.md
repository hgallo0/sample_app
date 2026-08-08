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
| Postgres auth | **IAM DB auth, no password at all.** `cloudsql.iam_authentication` is on; the runtime service account (`tofu output db_iam_user`) is registered as a `CLOUD_IAM_SERVICE_ACCOUNT` SQL user with `roles/cloudsql.instanceUser` + `roles/cloudsql.client`. Connect via the Cloud SQL Python Connector (`enable_iam_auth=True`) or equivalent — never a static credential. |
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

## game-engine (Go, internal only)

`game-api` (Python) and `game-engine` (Go) are two separate Cloud Run services, not one monolith — a deliberate polyglot split, kept on Cloud Run rather than GKE since GKE would need real provisioning time and would force reworking the LB's serverless-NEG backend, for no functional gain over two independently deployable Cloud Run services.

| Field | Value |
|---|---|
| Service | `game-engine`, Cloud Run, `us-central1` |
| Ingress | `INGRESS_TRAFFIC_INTERNAL_ONLY` — no LB, no public internet path at all |
| Invoker | restricted to `923334354359-compute@developer.gserviceaccount.com` (the same default compute SA `game-api` runs as) — not `allUsers` |
| URL | `tofu output game_engine_url` (internal-only, only resolvable/callable from other Cloud Run/serverless resources in this project) |
| Current image | placeholder `us-docker.pkg.dev/cloudrun/container/hello`, min=0/max=1 — swap for the real Go build during the live session |
| Who calls it | only `game-api` — attach an ID token for the same default compute SA when calling (authenticated Cloud Run-to-Cloud Run invocation, since invoker isn't public) |

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
The DB layer goes further than "don't store the password carefully" —
there is no password at all. IAM DB auth means the runtime service account
authenticates as itself with a short-lived token; there's nothing to fetch,
rotate, or leak. If any future secret is genuinely needed, follow the same
pattern already established for the (now-removed) DB password: manage only
the Secret Manager container + IAM binding in Tofu, add the actual value
out-of-band via `gcloud secrets versions add`, never a
`google_secret_manager_secret_version` resource with the value inline.

## What's still a placeholder / deferred to the live build

Infra above is real and applied; app-layer work is intentionally left for
the live session:
- `game-api` (Python/FastAPI): `db.py`/`models.py`/`auth.py`/`cache.py`, plus the client call into `game-engine` for move resolution
- `game-engine` (Go): the actual RPS move-comparison logic, served internally to `game-api` only
- Dockerfiles for both services
- Frontend (React + Firebase Google Sign-In)
- Apigee proxy bundle wiring Apigee → `game-api` (incl. fixing the envgroup hostname above)
- Swapping both placeholder Cloud Run images for the real builds
