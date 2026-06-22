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
- **2026-06-18** — Phase 5 (CI/CD) **applied & verified** on live AWS.
  `infra/cicd.tf`: IAM OIDC provider for GitHub + a `github-actions` role whose
  trust policy is locked to `repo:genkuroo/url-shortener-aws:ref:refs/heads/main`,
  with least-privilege ECR-push + ECS-redeploy permissions. Added the `tls`
  provider (thumbprint fetched dynamically). `.github/workflows/deploy.yml`:
  keyless OIDC auth, native ARM64 runner, build → push `:v2`+`:<sha>` →
  `force-new-deployment` (no task-def revision, so it never fights Terraform).
  Verified: pushed a root-route change to `main`, the Actions run deployed it
  automatically (root `/` 404 → JSON index, confirmed live), no AWS keys stored.
  Gotcha: pushing workflow files needs `gh` token `workflow` scope. Then torn
  down to $0.
- **2026-06-19** — Phase 6 (observability) **built in code** (`terraform validate`
  clean; not yet applied to live AWS). Enabled **Container Insights** on the ECS
  cluster. Added **structured JSON access logging** to the app (`main.py`
  middleware: one line per request with method/path/status/latency → CloudWatch
  Logs Insights). New `infra/monitoring.tf`: **SNS topic + email subscription**
  (`var.alert_email`, no default so no address is committed), two **CloudWatch
  alarms** (app 5xx > 5/min; healthy host count < 1) publishing to SNS with
  `ok_actions` recovery notifications, and a **CloudWatch dashboard** (requests,
  p95/avg latency, 5xx, ECS CPU/mem, healthy-vs-unhealthy tasks). New outputs:
  `dashboard_url`, `alerts_topic_arn`. App change means the next apply needs a
  fresh `:v2` build. **Verify-when-applied** steps (incl. forcing the alarm into
  ALARM via `aws cloudwatch set-alarm-state` to test the email path) are in
  `CLAUDE.md`.
- **2026-06-21** — Phase 7 (web UI + local runner) **built & tested locally.**
  `app/main.py` now serves a lightweight inline HTML page at `/` (vanilla JS, no
  framework/build step) that calls the existing `POST /api/links` — replacing the
  Phase 5 JSON index, so a human can use the shortener in a browser. Added a
  **one-command local runner** that needs no AWS: `docker-compose.yml` and
  `scripts/run_local.sh up` both stand up the same app image + a local Postgres
  (in for RDS) on `http://127.0.0.1:8000`, loopback-only. Verified end-to-end
  locally: page serves, form creates a link, redirect works, invalid URL → 422.
  (This machine's Colima has no Compose plugin, hence the shell-script runner as
  the no-install path.)
- **2026-06-22** — Phase 6 (observability) **applied & verified on live AWS**,
  then torn down to $0. Rebuilt the `:v2` image (with the Phase 6 logging + Phase
  7 UI), applied 39 resources, seeded + generated ~100 requests of traffic.
  Confirmed: **structured JSON logs** in CloudWatch (real 201 creates + 307
  redirects, with `duration_ms`), live **dashboard** metrics (ALB RequestCount et
  al.), and the **5xx alarm** fired + recovered — alarm history shows
  "Successfully executed action … url-shortener-alerts" on both the ALARM and OK
  transitions, proving the alarm→SNS chain. ⚠️ The SNS **email** subscription
  never confirmed: AWS reported the confirmation email sent, but it never reached
  Gmail (inbox/Promotions/Spam) even after two resends — likely a Gmail block on
  `sns.amazonaws.com`. So the final SNS→inbox delivery wasn't observed; everything
  up to the SNS publish was. This **closes the five-skill arc:
  Terraform · containers · VPC · CI/CD · observability.**
- **Next session (optional):** confirm the SNS subscription (or use a non-Gmail
  address / different protocol) to watch the actual alert email land; gate the
  deploy workflow so down-stack pushes skip instead of fail; or pick an item from
  "Later / optional upgrades" below (remote state, HTTPS + domain, autoscaling).

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

## Phase 5 — CI/CD (GitHub Actions + OIDC)  ✅
Make deploys push-button and keyless.

- GitHub repo + Actions workflow: build image → push to ECR → update ECS service
- AWS IAM OIDC identity provider + role GitHub assumes (no stored AWS keys)
- Workflow runs on push to `main`

**Done when:** a `git push` to `main` deploys a code change automatically, with
no AWS credentials stored in GitHub secrets.

**New concepts:** CI/CD pipelines, GitHub Actions, OIDC federation, keyless auth.

---

## Phase 6 — Observability  ✅ (applied & verified live 2026-06-22)
Be able to tell when it's healthy.

- CloudWatch log group for the Fargate tasks; structured app logs ✅
- ECS Container Insights enabled ✅
- A CloudWatch dashboard (request count, latency, 5xx, CPU/memory) ✅
- An alarm (e.g., 5xx rate or unhealthy host count) → SNS email ✅

**Done when:** the dashboard shows live traffic when you click links, and the
alarm fires (test it) to your email. ✅ Verified live 2026-06-22: dashboard +
structured logs confirmed, and the 5xx alarm fired + recovered through SNS. The
one unobserved bit is the SNS→**inbox** email hop — the AWS confirmation email
never reached Gmail, so the subscription stayed unconfirmed (see progress log /
`CLAUDE.md`). The alarm→SNS publish itself was proven via the alarm history.

**New concepts:** CloudWatch logs/metrics/dashboards/alarms, SNS, Container
Insights.

---

## Phase 7 — Web UI + local runner  ✅
Make it usable by a human, and testable without AWS.

- A lightweight web UI at `/`: a form to paste a long URL and get a short link
  back (inline HTML + vanilla JS, no framework, no build step). Thin client over
  the existing `POST /api/links`.
- A one-command local runner so anyone can try it with no AWS account:
  `docker-compose.yml` and `scripts/run_local.sh` both run the same app image +
  a local Postgres (standing in for RDS) on `http://127.0.0.1:8000`.

**Done when:** `./scripts/run_local.sh up` (or `docker compose up --build`) brings
the app up locally and you can shorten a link in the browser and follow it. ✅

**New concepts:** serving a front end from the API, Docker Compose / multi-
container local dev, the local-vs-cloud config seam (`DATABASE_URL` vs. Secrets
Manager).

**Scope note:** intentionally minimal. This is an infra project; the UI exists to
make the service usable and demoable, not to be a polished product. HTTPS + a
custom short domain (below) is what it would take to run this publicly for real.

---

## Later / optional upgrades
- **Remote Terraform state**: S3 bucket + DynamoDB lock table, migrate state off
  local. (Bootstrapped with its own tiny Terraform config to avoid chicken-egg.)
- **HTTPS**: ACM certificate + a domain on the ALB (443 listener).
- **Autoscaling**: ECS service autoscaling on CPU.
- **Custom CloudWatch metric**: emit a metric per click for a real dashboard line.
