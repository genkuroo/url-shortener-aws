# Phase 3 — IAM execution role for ECS tasks
#
# Fargate assumes this role to do infrastructure work on the task's behalf:
# pull the image from ECR and ship logs to CloudWatch. This is the *execution*
# role. A separate *task* role (for app permissions, like reading the DB secret)
# arrives in Phase 4.

# Trust policy: only the ECS tasks service is allowed to assume this role.
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${var.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# AWS-managed policy granting exactly the ECR-pull + CloudWatch-logs permissions
# a Fargate task needs to start. Least-privilege; nothing extra.
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Phase 4 — IAM TASK role (the app's own identity at runtime)
#
# The execution role above is for Fargate's plumbing (pull image, write logs).
# This task role is what the *application code* runs as. The container reads the
# DB secret using these permissions. They're separate on purpose: the app should
# be able to read its one secret, but it has no business pulling images or
# touching anything else. (Same trust policy — both are assumed by ECS tasks.)
resource "aws_iam_role" "ecs_task" {
  name               = "${var.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Least-privilege: read exactly one secret, nothing more.
data "aws_iam_policy_document" "task_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "task_secret" {
  name   = "${var.project}-read-db-secret"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.task_secret.json
}
