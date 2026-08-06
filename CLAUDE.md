# savvy

Mock build for the Savvy Senior Engineer AI/technical exercise interview round.

## Infra conventions (OpenTofu)

- Under `infra/`, split configuration by concern rather than one monolithic file:
  - `main.tf` — resources
  - `vars.tf` — variable declarations
  - `output.tf` — outputs
- Reusable/repeated infra goes in `infra/modules/<module-name>/`, each module following the same `main.tf` / `vars.tf` / `output.tf` split internally.
- Use OpenTofu (`tofu`), not Terraform CLI.
