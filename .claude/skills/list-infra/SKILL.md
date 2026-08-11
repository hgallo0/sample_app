---
name: list-infra
description: List everything actually deployed in GCP for this project right now, as a table with a plain-English description of each resource. Read-only - use to get a live snapshot (e.g. after a reset/teardown, or before a rehearsal), never to make changes.
---

Read-only inventory of live GCP state, per `CLAUDE.md`'s allowance for `gcloud describe`/`list`/`get-iam-policy`. Never create, modify, or delete anything here - if a check needs write access, it doesn't belong in this skill.

## 0. Resolve project
```
PROJECT=$(gcloud config get-value project 2>/dev/null)
```
Use `$PROJECT` in every command below rather than hardcoding an id, so this still works if the project ever changes.

## 1. Query live resources, grouped by category

Run these read-only `list`/`describe` calls. Don't stop on an empty result (an empty category is a legitimate answer, e.g. no frontend bucket after a teardown) - only stop and report if a command errors for a reason other than "nothing exists yet."

**Networking**
```
gcloud compute networks list --project=$PROJECT
gcloud compute networks subnets list --project=$PROJECT --filter="region:*"
gcloud compute routers list --project=$PROJECT
gcloud compute routers nats list --router=rps-router --region=us-central1 --project=$PROJECT
gcloud compute addresses list --global --project=$PROJECT
```

**Data stores**
```
gcloud sql instances list --project=$PROJECT
gcloud redis instances list --region=us-central1 --project=$PROJECT
```

**Load balancer / edge**
```
gcloud compute backend-services list --project=$PROJECT
gcloud compute backend-buckets list --project=$PROJECT
gcloud compute url-maps list --project=$PROJECT
gcloud compute ssl-certificates list --project=$PROJECT
gcloud compute target-https-proxies list --project=$PROJECT
gcloud compute forwarding-rules list --global --project=$PROJECT
gcloud compute security-policies list --project=$PROJECT
gcloud compute network-endpoint-groups list --project=$PROJECT
```

**Compute / serverless**
```
gcloud run services list --platform=managed --region=us-central1 --project=$PROJECT
```
For each service, also grab the deployed image (`--format="value(spec.template.spec.containers[0].image)"`) - "running" without which image is half the answer, especially in this repo where the same service name cycles between a blank placeholder and the real app across rehearsal resets.

**Apigee**
```
gcloud apigee organizations describe $PROJECT 2>&1
gcloud apigee instances list --organization=$PROJECT
gcloud apigee environments list --organization=$PROJECT
gcloud apigee envgroups list --organization=$PROJECT
gcloud apigee deployments list --organization=$PROJECT --environment=eval
```
The last one matters most - an Apigee org/instance/env can all be `ACTIVE` while zero API proxies are actually deployed (this has happened before in this repo's history). Don't report Apigee as "running" without checking this specifically.

**DNS**
```
gcloud dns managed-zones list --project=$PROJECT
```

**Storage / Artifact Registry / Secrets**
```
gcloud storage buckets list --project=$PROJECT
gcloud artifacts repositories list --project=$PROJECT
gcloud secrets list --project=$PROJECT
```

**Identity Platform / Auth**: no reliable `gcloud list` surface for this in most installs (`gcloud identity-platform` isn't always available as a command group). If it errors, fall back to `cd infra && tofu state show google_identity_platform_config.auth` instead of treating it as missing - it's still real, just not gcloud-inspectable.

## 2. Get descriptions from `INFRA_CONTEXT.md`, not from gcloud output

`gcloud` tells you a resource *exists* and its *status* - it doesn't tell you *why*. Read `INFRA_CONTEXT.md` and match each live resource name against its entry there for the one-line description. This also doubles as a drift check:
- A resource live in GCP but absent from `INFRA_CONTEXT.md` → flag it as undocumented, don't silently describe it yourself from guesswork.
- An `INFRA_CONTEXT.md` entry with no matching live resource → flag it as possibly torn down (expected right after `/teardown`'s placeholder-image reset, worth noting explicitly rather than as an error).

## 3. Report

One table per category (Networking, Data stores, Load balancer/edge, Compute, Apigee, DNS, Storage/Registry/Secrets), columns: **Resource | Name | Status | Description**. Keep descriptions to one line, pulled from `INFRA_CONTEXT.md`. End with a short "drift" callout only if step 2 found any mismatches - omit that section entirely if there's nothing to flag, don't force a null result into the report.
