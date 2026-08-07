---
name: safe-pr
description: Commit, push, and open a PR for the current branch, gated on a clean tofu plan, a cleartext-secret scan, and an intact .gitignore. Use when infra or app changes in this repo are ready to ship, not for ad-hoc commits.
---

Ship the current branch's changes as a reviewed PR. This skill is a safety gate, not a shortcut — every check below must pass before anything is staged, committed, or pushed. Stop and report on the first failure; never silently fix a finding and continue.

## 1. Branch check
Run `git branch --show-current`. If it's `main`, stop immediately and tell the user to create a feature branch first — never commit directly to `main` from this skill.

## 2. Terraform/OpenTofu sanity (if `infra/` has changes)
- `tofu fmt -check` in `infra/` — fail if formatting is off (offer to run `tofu fmt` and re-check, don't apply silently without saying so)
- `tofu validate` in `infra/` — fail on any error
- `tofu plan` in `infra/` — always show the full plan output to the user. This skill never runs `tofu apply`. If the plan shows unexpected destroys/recreates (e.g. a resource rename that isn't a `moved`/`state mv`), flag it explicitly and stop rather than proceeding.

## 3. Cleartext secret scan
Grep the diff (`git diff main...HEAD` and untracked files about to be added) for:
- Literal `password = "..."` / `secret = "..."` assignments in `.tf` files where the value isn't a reference (`var.`, `random_*`, `data.`, resource attribute) — a bare string literal is the finding
- Any `google_secret_manager_secret_version` resource with an inline `secret_data` — per `CLAUDE.md`, secret values must never be Tofu-managed, only added via `gcloud secrets versions add`
- Private key headers (`-----BEGIN PRIVATE KEY-----`, `-----BEGIN RSA PRIVATE KEY-----`)
- GCP service account JSON key shape (`"type": "service_account"` + `"private_key"`)
- Generic high-entropy `AKIA[0-9A-Z]{16}` (AWS key id) as a catch-all in case unrelated cloud creds ended up in the repo

Any hit stops the skill. Report the file:line and what matched — don't guess at a fix.

## 4. `.gitignore` check
Confirm `infra/.gitignore` still contains `.terraform/`, `*.tfstate`, `*.tfstate.*`. If the diff removes or weakens any of these lines, stop and flag it — don't restore it silently, since removing it might have been intentional and needs the user's confirmation either way.

## 5. Ship
Only if steps 1-4 all pass:
- Stage the relevant files (never `git add -A`/`.` blindly — review `git status` first)
- Draft a commit message from the actual diff (why, not what) and commit
- Push the current branch with `-u` if it has no upstream yet
- `gh pr create` with a summary drafted from the commits in this branch vs. `main`, plus a test plan checklist

Report back the PR URL when done.
