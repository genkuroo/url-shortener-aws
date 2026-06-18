# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A containerized URL shortener, deployed on AWS the way a cloud engineer actually
deploys things. The app itself is deliberately small — the **infrastructure is
the subject**, not the business logic. Project #3 in the cloud-learning arc
(after the Cloudflare and AWS habit-trackers), chosen to close the gaps those
serverless projects left: Terraform, containers, VPC networking, CI/CD, and
observability.

Built phase-by-phase. Each phase ends with something visibly working (a live
URL, a seeded DB row, a green pipeline run), per the workspace `leave-demo-data`
convention.

## The app

A link shortener. `POST` a long URL, get back a short code; visiting the short
URL redirects and logs a click.

- `POST /api/links` — create a short link
- `GET  /{code}` — redirect to the long URL + record a click
- `GET  /api/links/{code}/stats` — click count + recent hits
- `GET  /healthz` — liveness probe for the ALB target group

Stack inside the container: **Python + FastAPI**, talking to **Postgres**.

## Architecture

```
Internet
   │
  ALB                  (public subnets, 2 AZs)
   │
ECS Fargate service    (public subnets, public IP — NO NAT gateway)
   │
  RDS Postgres         (private subnets, SG locked to the Fargate SG)

ECR ← image      Secrets Manager ← DB creds      CloudWatch ← logs / alarms
```

**Deliberate cost choices (free-tier / tear-down model):**
- **No NAT gateway.** Fargate tasks run in public subnets with a public IP.
  RDS stays in private subnets and needs no outbound internet. This avoids the
  ~$32/mo NAT cost while still teaching the public/private subnet split.
- **RDS `db.t4g.micro`** — 12-month free tier.
- Everything is one `terraform apply` / `terraform destroy`. The only cost while
  *up* is the ALB (~$0.02/hr) + Fargate-seconds. Destroy after each session.

## Infrastructure as code

All AWS resources are defined in **Terraform** under `infra/`. Terraform is the
source of truth — analogous to `template.yaml` (SAM) in the habit-tracker-aws
project, but provider-agnostic and the industry standard.

- State is **local** for now (`infra/terraform.tfstate`, gitignored). An S3 +
  DynamoDB remote backend is a documented later upgrade (see `docs/PLAN.md`).
- Never commit `*.tfvars` (may hold real values) or state files. `.gitignore`
  enforces this; `terraform.tfvars.example` is the committed template.
- Run Terraform from inside `infra/`.

## Current state (as of 2026-06-18)

**Phase 4 applied & verified, then torn down — 0 resources live, $0 cost.**
Phases 1–4 all built and confirmed working end-to-end against live AWS, then
`terraform destroy`'d (32 resources destroyed, state empty). All work captured in
code.

**Phase 4 verification (2026-06-18):** 31 resources applied. App healthy behind
the ALB; created a link, clicked it, confirmed `/stats` from Postgres; then
**forced an ECS task restart and the link + click counts survived** (proves real
persistence, not memory). Demo data seeded via `scripts/seed_demo.py`.

To rebuild from cold (after a destroy):
1. Build & push the app image as **`:v2`** — ARM64 (Apple Silicon → Graviton).
   `var.image_tag` defaults to `v2`. ECR is destroyed on teardown, so create it
   first: `terraform apply -target=aws_ecr_repository.app`, then build/login/push.
2. `cd infra && terraform apply` (RDS adds ~5–10 min; ECS `depends_on` the DB).
3. Seed demo data through the live app (laptop can't reach the private DB):
   `python scripts/seed_demo.py http://<alb-dns-name>`

Note: the ALB DNS name and resource IDs change on every apply — recorded for
reference, not as fixed values.

## Phase status

- **Phase 1 — networking:** ✅ Applied. VPC `vpc-0b15077fb0d75599e`, 2 public +
  2 private subnets across us-east-1a/1b, IGW, route tables. All free-tier.
- **Phase 2 — container:** ✅ FastAPI app (`app/`, in-memory store for now) +
  Dockerfile. Built & tested locally with Colima/Docker; image pushed to ECR
  (`url-shortener:v1` and `:latest`). Runtime: Python 3.12-slim, non-root user.
- **Phase 3 — Fargate + ALB:** ✅ ECS Fargate service (1 task, **ARM64/Graviton**,
  256 CPU / 512 MB) behind an internet-facing ALB. SGs chain internet→ALB:80→
  task:8000. Health check `/healthz`. CloudWatch log group `/ecs/url-shortener`.
  Live (while up): `http://url-shortener-alb-509002737.us-east-1.elb.amazonaws.com`.
  NOTE: image must be ARM64 to match the Graviton runtime (built on Apple Silicon).
- **Phase 4 — RDS + Secrets Manager:** ✅ Applied & verified (2026-06-18). RDS
  Postgres `db.t4g.micro` in private subnets (`rds.tf`), creds generated + stored
  in Secrets Manager (`secrets.tf`), db SG locked to the task SG
  (`security_groups.tf`), separate IAM **task role** that can read only that
  secret (`iam.tf`). App uses Postgres + reads the secret via boto3 at startup
  (`app/main.py`); tables created on startup; demo seeder at
  `scripts/seed_demo.py`. Image `:v2`. Persistence proven across a task restart.
- **Phase 5 — CI/CD:** ⬜ GitHub Actions, OIDC (no long-lived AWS keys).
- **Phase 6 — observability:** ⬜ CloudWatch logs, dashboard, alarms.

See `docs/PLAN.md` for per-phase deliverables.

## Explaining this project (recruiter-ready reference)

Everything below is what you should be able to say out loud about this project.
Plain English, no copy-pasting jargon you can't defend.

### The 30-second pitch

> "I built a URL shortener and deployed it on AWS the way a real team would.
> The app runs in a Docker container on AWS's managed container service
> (ECS Fargate), behind a load balancer, talking to a Postgres database that's
> locked away in a private network. I defined the entire cloud setup as code
> with Terraform, so it's reproducible and disposable. Code pushes deploy
> themselves through a GitHub Actions pipeline, and I monitor it with CloudWatch
> dashboards and alarms."

The app is intentionally simple. The point is the **infrastructure and the
practices**, not the business logic.

### How a request actually flows

```
A user clicks a short link
   → hits the Application Load Balancer (ALB)   [public, internet-facing]
   → which forwards it to the app container      [ECS Fargate, public subnet]
   → which queries the Postgres database         [RDS, private subnet]
   → gets the original URL back, redirects the user
```

### The concepts, decoded (be able to define each in a sentence)

- **VPC** — a private, isolated network inside AWS that holds everything else.
- **Subnet** — a slice of the VPC. **Public** = has a route to the internet;
  **private** = does not. A subnet is public/private *purely because of its
  route table*, nothing else.
- **Availability Zone (AZ)** — a physically separate data center. We use two so
  a single data-center failure doesn't take the app down.
- **Route table** — the rulebook that decides where network traffic goes. The
  one rule "internet traffic → internet gateway" is what makes a subnet public.
- **Internet gateway** — the single door between the VPC and the internet.
- **NAT gateway** — would let private resources make *outbound* internet
  connections. **We deliberately skip it** (it's ~$32/mo and our database never
  needs outbound internet), which is itself a defensible cost decision.
- **Container / Docker image** — the app packaged with everything it needs to
  run, so it behaves identically on a laptop and in the cloud.
- **ECR** — AWS's registry where the built container image is stored.
- **ECS Fargate** — runs the container without us managing any servers (the
  container-world equivalent of Lambda).
- **ALB (Application Load Balancer)** — the public entry point; spreads traffic
  to the containers and health-checks them.
- **Security group** — a per-resource firewall. We chain them so the database
  only accepts connections from the app, and the app only from the ALB.
- **RDS Postgres** — AWS-managed relational (SQL) database. Lives in the private
  subnets so it's unreachable from the internet.
- **Secrets Manager** — stores the database password; the app reads it at
  runtime instead of having it hard-coded.
- **IAM role** — an identity with scoped permissions (e.g., "this container may
  read this one secret"). Least-privilege, not a shared password.
- **Terraform / Infrastructure as Code** — the whole cloud setup is defined in
  text files, so it's version-controlled, reproducible (`apply`) and disposable
  (`destroy`). Industry-standard, provider-agnostic.
- **CI/CD pipeline (GitHub Actions)** — on every push, automatically build the
  image, push to ECR, and update the running service.
- **OIDC** — lets GitHub deploy to AWS using short-lived, auto-expiring
  credentials instead of long-lived AWS keys stored in GitHub. A security
  best practice.
- **CloudWatch** — AWS monitoring: logs, dashboards, and alarms that notify when
  something breaks.

### The design decisions you should be able to defend

1. **Two Availability Zones** → high availability; also the ALB and RDS both
   *require* two AZs.
2. **Public vs. private subnets** → the database is physically unreachable from
   the internet; only the app inside the VPC can talk to it.
3. **No NAT gateway** → conscious cost trade-off; nothing in our private subnet
   needs outbound internet, so we save ~$32/mo.
4. **Everything in Terraform** → reproducible, reviewable, disposable infra.
5. **OIDC over stored keys** → no long-lived cloud credentials sitting in GitHub.
6. **Free-tier / tear-down** → cost-aware operation; destroy when idle.

### The five skills this project demonstrates

**Terraform · containers · VPC networking · CI/CD · observability** — exactly the
gaps that pure-serverless work (Lambda) leaves, and the core of a cloud-engineer
job description.

## Conventions

- **No build step for infra changes outside Terraform.** If it's an AWS
  resource, it lives in `infra/*.tf` — never created by hand in the console.
- **Commits / PRs: no AI attribution** (workspace-wide rule).
- **Tear down when done** for the day: `cd infra && terraform destroy`.
