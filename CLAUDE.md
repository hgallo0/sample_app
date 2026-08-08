# savvy

Mock build for the Savvy Senior Engineer AI/technical exercise interview round.

## Infra conventions (OpenTofu)

- Under `infra/`, split configuration by concern rather than one monolithic file:
  - `main.tf` — resources
  - `vars.tf` — variable declarations
  - `output.tf` — outputs
- Reusable/repeated infra goes in `infra/modules/<module-name>/`, each module following the same `main.tf` / `vars.tf` / `output.tf` split internally.
- Use OpenTofu (`tofu`), not Terraform CLI.
- Do not create GCP resources imperatively with `gcloud` (or the console). Everything provisioned - including things that feel "fast enough to just create ad-hoc," like an Artifact Registry repo - must be defined in OpenTofu and created via `tofu apply`. `gcloud` is only for read-only checks (`describe`/`list`/`get-iam-policy`) and for the specific out-of-band secret-value operations called out below, never for creating/modifying infrastructure.

## Security conventions

- Every backend service (Cloud Run, GKE, etc.) must restrict its access path explicitly and describe that restriction in a comment at the point it's enforced - e.g. "load balancer only" via `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`, not an open `allUsers` invoker with no network-layer restriction. A public invoker binding is only acceptable paired with an explicit, named restriction on what network path can reach the service - never on its own.
- Passwords/secrets must never be stored in Terraform/OpenTofu state - anyone with read access to the state file can see them in plaintext. Don't generate secrets with resources like `random_password` and feed them into a `password` field. Instead, omit the field (or set it out-of-band via `gcloud`/console) and add `lifecycle { ignore_changes = [password] }` so OpenTofu never attempts to manage or overwrite it.
- For secrets a live service needs to read at runtime (e.g. a DB password), manage only the Secret Manager container (`google_secret_manager_secret`) and its IAM access binding in Terraform - never a `google_secret_manager_secret_version` with the value inline, since that argument is stored in state the same as any other. Add the actual secret value out-of-band via `gcloud secrets versions add`.
- Never allow public access to any database, under any circumstance - no public IP (`ipv4_enabled = true`), not even temporarily/reversibly for admin convenience (e.g. running a one-off `GRANT`). If a database needs an admin operation that requires a direct connection, do it from inside the VPC (a Cloud SQL Studio session in the console, a temporary Compute Engine VM/Cloud Shell with VPC access, or equivalent) - never by opening the database to the public internet, even briefly and even behind SSL/IP-allowlisting.
