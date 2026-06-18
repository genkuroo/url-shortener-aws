# Build plan — url-shortener-aws

Phase-by-phase. The app is small on purpose; the point is to learn the cloud
plumbing in the right order. Each phase has a concrete "done when" you can see.

The five skills this whole project exists to teach:
**Terraform · containers · VPC networking · CI/CD · observability.**

---

## Progress log

- **2026-06-16** — Project chosen & scaffolded. Phase 1 (networking) applied &
  verified (VPC + 4 subnets across 2 AZs).
- **2026-06-17** — Phase 2 (container) done: FastAPI app + Dockerfile, built with
  Colima/Docker, pushed to ECR. Phase 3 (Fargate + ALB) done: app served live on
  a public ALB URL end-to-end. Then `terraform destroy`'d back to $0.
  - **Gotcha learned:** image built on Apple Silicon is **arm64**, but Fargate
    defaults to **x86_64** → container crashed with `exec format error`. Fixed by
    setting the task definition `runtime_platform` to **ARM64/Graviton** (also
    ~20% cheaper). Keep image + runtime architecture aligned.
- **2026-06-18** — Phase 4 (RDS + Secrets Manager) **applied & verified** on live
  AWS. Added `rds.tf` (Postgres in private subnets via a db subnet group),
  `secrets.tf` (Terraform-generated password → RDS + stored as a JSON secret), db
  security group locked to the task SG, a separate IAM **task role** scoped to
  read only that one secret, and the `task_role_arn` + `DB_SECRET_ARN` env on the
  task def. App (`app/main.py`) rewritten: reads the secret with boto3 at startup,
  creates `links`/`clicks` tables, all endpoints now SQL. New
  `scripts/seed_demo.py` seeds via the HTTP API. Image `v1→v2` (now needs
  psycopg2 + boto3). Verified: created a link, restarted the ECS task, and the
  link + click counts survived — real persistence. 31 resources applied.
- **2026-06-18** — Phase 5 (CI/CD) **written & validated** (not yet applied).
  `infra/cicd.tf`: IAM OIDC provider for GitHub + a `github-actions` role whose
  trust policy is locked to `repo:genkuroo/url-shortener-aws:ref:refs/heads/main`,
  with least-privilege ECR-push + ECS-redeploy permissions. Added the `tls`
  provider (thumbprint fetched dynamically). `.github/workflows/deploy.yml`:
  keyless OIDC auth, native ARM64 runner, build → push `:v2`+`:<sha>` →
  `force-new-deployment` (no task-def revision, so it never fights Terraform).
  `terraform validate` + YAML both pass.
- **Next session:** go live with Phase 5 — apply, set the `AWS_ROLE_ARN` repo
  variable, push the workflow, and prove an `app/**` push to `main` auto-deploys.
  Then **Phase 6 (observability)**.

---

## Phase 1 — Networking  ✅
Stand up the private network everything else lives in.

- VPC (`10.0.0.0/16`)
- 2 **public** subnets (for the ALB + Fargate tasks), across 2 AZs
- 2 **private** subnets (for RDS), across 2 AZs
- Internet gateway + public route table (no NAT gateway — see CLAUDE.md)
- Private route table with no internet route

**Done when:** `terraform apply` succeeds and `terraform output` prints the VPC
and subnet IDs. Verify in the console that the subnets sit in two AZs.

**New concepts:** VPC, subnets, route tables, internet gateway, Terraform
`for_each`, outputs.

---

## Phase 2 — Container  ✅
Package the app so it runs identically anywhere.

- FastAPI app in `app/` with the four endpoints (`/healthz` first)
- `Dockerfile` (slim Python base, non-root user)
- Build locally, run the container, hit `http://localhost:8000/healthz`
- ECR repository (in Terraform), push the image

**Done when:** the image is in ECR and the container serves `/healthz` locally.

**New concepts:** Docker images, Dockerfile, ECR, container registries.

---

## Phase 3 — Fargate + ALB  ✅
Run the container in AWS, reachable from the internet.

- ECS cluster + Fargate task definition + service (in the public subnets)
- Application Load Balancer + target group + listener
- Security groups: ALB open on 80; tasks accept traffic only from the ALB SG
- App talks to no database yet — `/healthz` and an in-memory shorten work
- **Task `runtime_platform = ARM64`** to match the Apple-Silicon-built image

**Done when:** the ALB DNS name serves the app and you can shorten a link
(stored in memory for now). Health checks are green.

**New concepts:** ECS, Fargate, task definitions, ALB, target groups,
listeners, security-group chaining.

---

## Phase 4 — RDS + Secrets Manager  ✅
Give it a real database.

- RDS Postgres `db.t4g.micro` in the private subnets
- DB security group: accepts 5432 only from the Fargate task SG
- DB credentials in Secrets Manager; the task reads them at runtime via IAM
- App migrations create `links` + `clicks` tables; persistence replaces memory
- Seed a few demo links (`scripts/seed_demo.py`)

**Done when:** a shortened link survives a task restart, and `/stats` shows real
click counts from Postgres.

**New concepts:** RDS, private-subnet data tier, Secrets Manager, IAM task
roles, SQL schema/migrations.

---

## Phase 5 — CI/CD (GitHub Actions + OIDC)  🟡 (written & validated, not yet applied)
Make deploys push-button and keyless.

- GitHub repo + Actions workflow: build image → push to ECR → update ECS service
- AWS IAM OIDC identity provider + role GitHub assumes (no stored AWS keys)
- Workflow runs on push to `main`

**Done when:** a `git push` to `main` deploys a code change automatically, with
no AWS credentials stored in GitHub secrets.

**New concepts:** CI/CD pipelines, GitHub Actions, OIDC federation, keyless auth.

---

## Phase 6 — Observability
Be able to tell when it's healthy.

- CloudWatch log group for the Fargate tasks; structured app logs
- ECS Container Insights enabled
- A CloudWatch dashboard (request count, latency, 5xx, CPU/memory)
- An alarm (e.g., 5xx rate or unhealthy host count) → SNS email

**Done when:** the dashboard shows live traffic when you click links, and the
alarm fires (test it) to your email.

**New concepts:** CloudWatch logs/metrics/dashboards/alarms, SNS, Container
Insights.

---

## Later / optional upgrades
- **Remote Terraform state**: S3 bucket + DynamoDB lock table, migrate state off
  local. (Bootstrapped with its own tiny Terraform config to avoid chicken-egg.)
- **HTTPS**: ACM certificate + a domain on the ALB (443 listener).
- **Autoscaling**: ECS service autoscaling on CPU.
- **Custom CloudWatch metric**: emit a metric per click for a real dashboard line.
