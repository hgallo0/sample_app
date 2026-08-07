# savvy

Mock build for the Savvy Senior Engineer AI/technical exercise interview round.

## Infra conventions (OpenTofu)

- Under `infra/`, split configuration by concern rather than one monolithic file:
  - `main.tf` — resources
  - `vars.tf` — variable declarations
  - `output.tf` — outputs
- Reusable/repeated infra goes in `infra/modules/<module-name>/`, each module following the same `main.tf` / `vars.tf` / `output.tf` split internally.
- Use OpenTofu (`tofu`), not Terraform CLI.

## Security conventions

- Every backend service (Cloud Run, GKE, etc.) must restrict its access path explicitly and describe that restriction in a comment at the point it's enforced - e.g. "load balancer only" via `ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"`, not an open `allUsers` invoker with no network-layer restriction. A public invoker binding is only acceptable paired with an explicit, named restriction on what network path can reach the service - never on its own.
