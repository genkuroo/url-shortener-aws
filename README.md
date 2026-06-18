# url-shortener-aws

A containerized URL shortener deployed on AWS with Terraform — built to learn
the cloud-engineering plumbing that serverless projects hide: **Terraform,
containers, VPC networking, CI/CD, and observability**.

The app is small on purpose. The infrastructure is the point.

## What it does

`POST` a long URL, get a short code back. Visiting the short URL redirects to the
original and logs the click. FastAPI (Python) in a container, backed by Postgres.

## Architecture

```
Internet → ALB → ECS Fargate (FastAPI container) → RDS Postgres (private)
```

See `CLAUDE.md` for the full diagram and the deliberate cost choices
(free-tier / tear-down: no NAT gateway, db.t4g.micro, destroy when idle).

## Layout

| Path | What's there |
|------|--------------|
| `infra/` | Terraform — all AWS resources (the source of truth) |
| `app/`   | FastAPI app + Dockerfile |
| `scripts/` | Helper scripts (e.g. `seed_demo.py` to seed demo links) |
| `docs/PLAN.md` | The phase-by-phase build plan |
| `CLAUDE.md` | Project guidance + phase status |

## Working with the infrastructure

```bash
cd infra
terraform init      # one-time: download the AWS provider
terraform plan      # preview what will be created/changed
terraform apply     # create the resources (prompts for confirmation)
terraform output    # reprint VPC / subnet IDs etc.
terraform destroy   # tear everything down (do this when done for the day)
```

Requires the AWS CLI configured with credentials (`aws configure`) and Terraform
installed.

## Status

Phases 1–4 built and verified on live AWS (networking, container, Fargate + ALB,
RDS + Secrets Manager). Next up: Phase 5 (CI/CD). See `docs/PLAN.md`.
