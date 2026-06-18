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
