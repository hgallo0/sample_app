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
| Cloud Router | `rps-router` (`us-central1`) |
| Cloud NAT | `rps-nat`, `AUTO_ONLY` IPs, all subnets — required because `game-api` uses `ALL_TRAFFIC` VPC egress (see below), which routes its calls to public Google APIs through the VPC too, and the VPC has no internet path without this |

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

**Admin read access to `game_api` schema is permanent, standing infra — do not revoke, don't re-derive from scratch:** the app tables live in a `game_api` schema (not `public`), owned by game-api's own IAM role since it's the one that runs `Base.metadata.create_all()`. Cloud SQL's built-in `postgres` user is only a `cloudsqlsuperuser`, not a true Postgres superuser, so it has no visibility into another role's tables by default — this was fixed once, manually, via Cloud SQL Studio (not Tofu-managed, no resource type covers arbitrary `GRANT`s):
```sql
GRANT "<db_iam_user>" TO postgres;
SET ROLE "<db_iam_user>";
GRANT USAGE ON SCHEMA game_api TO postgres;
GRANT SELECT ON ALL TABLES IN SCHEMA game_api TO postgres;
RESET ROLE;
```
`postgres` can now log into Cloud SQL Studio and read `game_api.*` directly. This survives Cloud Run redeploys/image swaps (it's a database-level grant, not tied to any revision) — it would only be lost if the Cloud SQL instance itself were destroyed and recreated.

## Load balancer / edge

| Resource | Value |
|---|---|
| Public IP | `34.160.17.87` (`game-api-lb-ip`, global) |
| Domain | `rps.cloudwithgallo.com` |
| Managed SSL cert | `game-api-cert` — status `ACTIVE` |
| Ingress path | forwarding rule (`game-api-https-rule`, :443) → target HTTPS proxy (`game-api-https-proxy`) → URL map (`game-api-lb`) → backend service (`game-api-backend`) → serverless NEG (`game-api-neg`) → Cloud Run (`game-api`) |
| WAF | Cloud Armor policy `rps-waf` — blocks XSS (`xss-stable`) + SQLi (`sqli-stable`) preconfigured rules, rate limit 100 req/60s per source IP (429 on exceed). `advanced_options_config.json_parsing = "STANDARD"` — without this, Cloud Armor inspects request bodies as opaque strings and any JSON object/array's `{}`/`[]` structure false-positives as SQLi, blocking every JSON POST outright. Backend service access logging (`log_config.enable = true`) is on — was off entirely, don't disable it, it's the only way to diagnose WAF false positives. |
| Cloud Run ingress | `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` — `*.run.app` URL is not directly reachable; `allUsers` invoker binding is paired with this restriction (network-layer gate, not IAM) |
| Cloud Run service (current) | `game-api`, real image `game-api:v0.3.0` (**deployed and verified working**, not a placeholder), min=0/max=1, runs as the default compute service account (`923334354359-compute@developer.gserviceaccount.com`) |
| `game-api` env vars | `PROJECT_ID`, `REGION`, `DB_IAM_USER`, `REDIS_HOST`, `GAME_ENGINE_URL` — all wired |
| `game-api` VPC access | Direct VPC egress, `ALL_TRAFFIC` (not `PRIVATE_RANGES_ONLY`) — needed so calls to `game-engine`'s `*.run.app` URL route through the VPC and get recognized as internal Cloud-Run-to-Cloud-Run traffic by `game-engine`'s `INGRESS_TRAFFIC_INTERNAL_ONLY`; `PRIVATE_RANGES_ONLY` sends calls to public hostnames out the normal internet path instead, which gets silently rejected as external (404, no app-side logs). Requires the Cloud NAT above. |
| `game-api` startup probe | `tcp_socket` port 8080, `failure_threshold = 3` (not the Cloud Run default of 1) — Direct VPC egress cold-start connection establishment can take "a minute or more" per Google's docs; the default single-attempt probe isn't enough headroom. |

## game-engine (Go, internal only)

`game-api` (Python) and `game-engine` (Go) are two separate Cloud Run services, not one monolith — a deliberate polyglot split, kept on Cloud Run rather than GKE since GKE would need real provisioning time and would force reworking the LB's serverless-NEG backend, for no functional gain over two independently deployable Cloud Run services.

| Field | Value |
|---|---|
| Service | `game-engine`, Cloud Run, `us-central1` |
| Ingress | `INGRESS_TRAFFIC_INTERNAL_ONLY` — no LB, no public internet path at all |
| Invoker | restricted to `923334354359-compute@developer.gserviceaccount.com` (the same default compute SA `game-api` runs as) — not `allUsers` |
| URL | `tofu output game_engine_url` (internal-only, only resolvable/callable from other Cloud Run/serverless resources in this project) |
| Current image | real image `game-engine:v0.1.0` (**deployed and verified working**, not a placeholder), min=0/max=1 |
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

## Authentication (Google SSO via Firebase Auth / Identity Platform)

**Done and verified end-to-end** — signing in with a real Gmail account and calling `game-api` with the resulting token works.

| Field | Value |
|---|---|
| APIs enabled | `identitytoolkit.googleapis.com`, `cloudresourcemanager.googleapis.com` |
| Identity Platform config | authorized domains: `localhost`, `rps.cloudwithgallo.com`, `backend-500517.firebaseapp.com`, `backend-500517.web.app`; sign-up quota 100/hr |
| Firebase Web App | registered (`google_firebase_web_app`, needs the `google-beta` provider) — `tofu output firebase_web_app_config` for the JS SDK config (apiKey/authDomain/projectId/appId; none of these are secrets, safe to embed client-side) |
| Google sign-in provider | enabled via the Firebase Console (Authentication → Sign-in method → Google) — the **one** manual step in this whole setup, unavoidable: the underlying Terraform resource (`google_identity_platform_default_supported_idp_config`) needs a plaintext OAuth `client_secret` with no state-avoidance mechanism, which would violate the no-secrets-in-state rule (see "Secrets policy" below) |
| `game-api` verification | `firebase_admin.auth.verify_id_token()` in `auth.py` — verifies the bearer token's signature against Google's public certs, no extra config needed |

## Apigee

| Field | Value |
|---|---|
| Org | `backend-500517` — state `ACTIVE`, billing `EVALUATION`, runtime `CLOUD` |
| Instance | `eval-instance` (`us-central1`) |
| Environment | `eval` |
| Envgroup | `eval-group` |
| Envgroup hostname | **`eval.example.com` — placeholder, does not match `rps.cloudwithgallo.com`.** Needs updating before the Apigee proxy can actually front `game-api` over the real domain — Apigee uses this for host-based routing internally to pick which environment's proxies to invoke, so it must match what the GLB forwards. Flagged as a known gap, not yet fixed (this is reset back to the placeholder by `/teardown` between rehearsal cycles, so it reads "not yet fixed" here even after a rehearsal has fixed it live). |

### `gcloud apigee` CLI gotchas (verified against the gcloud version installed here)

The `apigee` command group is much narrower than it looks, and guessing subcommands by analogy with other `gcloud` groups burns real time hitting `Invalid choice` errors mid-task. Verified via `gcloud apigee --help` / `gcloud apigee <group> --help`:

- **No `instances` group at all** — neither `gcloud apigee instances describe` nor `gcloud beta apigee instances ...` exist in this gcloud version. To read instance details (e.g. the PSC service attachment for `eval-instance`, needed to build a PSC NEG backend), call the Management API directly: `GET https://apigee.googleapis.com/v1/organizations/backend-500517/instances/eval-instance` with `gcloud auth print-access-token` as the bearer token.
- **`gcloud apigee organizations` only supports `list`**, not `describe` — use `gcloud apigee organizations list` and filter, or hit the Management API directly for single-org detail.
- **Deploying/undeploying a proxy bundle**: `gcloud apigee apis create`/`apis import` for a *new* bundle don't exist in this version either — import via the Management API (`POST .../apis?action=import&name=<api-name>`, multipart zip body), then the deploy/undeploy/list verbs below do work as real `gcloud` subcommands:
  - `gcloud apigee apis deploy --organization=backend-500517 --environment=eval --api=<name> <revision>`
  - `gcloud apigee apis undeploy --organization=backend-500517 --environment=eval --api=<name>`
  - `gcloud apigee deployments list --organization=backend-500517 --environment=eval` — lists what's actually live in an environment right now; check this before deploying a new proxy to the same base path, a stale prior-rehearsal deployment here causes `CONFLICTING_DEPLOYMENT` (see `/teardown` step 3, added after this cost real time mid-rehearsal).

### Proxy bundle routing (spec'd, not yet built)

The GLB sits **in front of** Apigee (confirmed against Google's documented Apigee X + external LB pattern) — Client → GLB → Apigee → `game-api`, matching the existing WAF/LB perimeter design.

`game-api`'s ingress is `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` — narrower than `game-engine`'s `INTERNAL_ONLY`, it only accepts traffic arriving via *this specific* GLB's serverless NEG. Apigee's runtime, even though PSA-peered into the VPC, isn't literally the LB, so it can't call `game-api` directly without hitting the same class of ingress rejection documented above for `game-engine` (silent 404, no app-side logs). Decided: **hairpin through the GLB** rather than loosening `game-api`'s ingress.

1. Add a **PSC (Private Service Connect) NEG** backend service pointing at the Apigee instance, add a `url_map` rule routing the public path (e.g. `/api/*`) to it — the new front door for API traffic.
2. Add a **second, internal-only `url_map` path rule** (e.g. `/_internal/api/*`) routing straight to `game-api`'s existing backend service/NEG, bypassing Apigee — this is what the Apigee proxy's target endpoint calls, avoiding a loop back into itself.
3. Fix the envgroup hostname (above) to `rps.cloudwithgallo.com`.

**Policies:** pass-through only, no redundant JWT re-validation — `game-api` already fully verifies the Firebase token. Forward the `Authorization` header unchanged; add Apigee's own quota/spike-arrest policy (distinct from Cloud Armor's per-IP rate limit) plus default analytics. Keep the proxy XML simple.

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

## What's done vs. still deferred to the live build

**Done and verified, not placeholders:** both Cloud Run services run their real images (`game-api:v0.3.0`, `game-engine:v0.1.0`); Google SSO works end-to-end (real Gmail sign-in → Firebase token → `game-api` verification → Postgres user creation); full gameplay works end-to-end (`POST /api/move` → real rock-paper-scissors logic via `game-engine` → recorded in Postgres → leaderboard in Redis). Don't re-write or re-deploy any of this from scratch — it's real, working code already in `app/`.

**Still deferred to the live session:**
- Frontend (React + Firebase Google Sign-In UI) — backend/auth is ready for it, nothing built client-side yet
- Apigee proxy bundle wiring Apigee → `game-api` — see the routing spec above, this is execution not discovery
- Structured logging + real OpenTelemetry spans (trace ID per transaction, correlated across `game-api`/`game-engine` and queryable in the Cloud Trace waterfall) — not started at all yet. Note: the prerequisite for the OTel exporters to actually work, `cloudtrace.googleapis.com` enabled + `roles/cloudtrace.agent` on the shared runtime compute SA, is already permanent committed infra (`main.tf`'s `services` list + `google_project_iam_member.compute_sa_cloudtrace_agent`) — don't re-discover or re-provision this, just confirm it's present.
