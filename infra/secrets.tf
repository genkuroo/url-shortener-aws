# Phase 4 — Secrets Manager (where the DB credentials live)
#
# The database password is never typed by a human or committed to git. Terraform
# generates a random one, gives it to RDS, and stores the full connection details
# as a single JSON secret. At runtime the app reads this secret using its task
# role (see iam.tf) — so the password exists in exactly two places: RDS itself
# and this secret, both inside AWS.

# Generate a strong random password. We restrict the special characters to ones
# Postgres/RDS accept in a master password (no /, @, ", or spaces).
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#%^*-_=+"
}

# The secret container. recovery_window_in_days = 0 means a destroy deletes it
# immediately instead of holding it for 7–30 days — convenient for this
# spin-up/tear-down project, but you'd keep the recovery window in production.
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project}/db"
  description             = "Postgres connection details for the URL shortener app"
  recovery_window_in_days = 0

  tags = { Name = "${var.project}-db-secret" }
}

# The actual secret value: everything the app needs to build a connection. It
# depends on the RDS instance because the host (address) isn't known until the
# database exists.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
  })
}
