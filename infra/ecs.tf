# Phase 3 — ECS Fargate (runs the container)

# Where the container's stdout/logs go. Full dashboards/alarms are Phase 6;
# this group is the minimum the task needs to emit logs.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}"
  retention_in_days = 7
}

# A cluster is the logical grouping the service runs in.
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
}

# The task definition is the blueprint for a running container: which image,
# how much CPU/memory, which port, and where logs go.
resource "aws_ecs_task_definition" "app" {
  family                   = var.project
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # 512 MB
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  # The app runs AS this role and uses it to read the DB secret at startup.
  task_role_arn = aws_iam_role.ecs_task.arn

  # Run on ARM64 (AWS Graviton). Matches the arm64 image built on Apple Silicon
  # and is ~20% cheaper than x86. Without this, Fargate defaults to x86_64 and
  # the arm64 binary fails with "exec format error".
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        { containerPort = 8000, protocol = "tcp" }
      ]
      # Tell the app which secret to read and what region to call. The app uses
      # its task role to fetch the secret's value (the actual DB password is
      # never passed here as plaintext — only the secret's ARN).
      environment = [
        { name = "DB_SECRET_ARN", value = aws_secretsmanager_secret.db.arn },
        { name = "AWS_REGION", value = var.region }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

# The service keeps the desired number of tasks running and registers them with
# the load balancer's target group.
resource "aws_ecs_service" "app" {
  name            = "${var.project}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [for s in aws_subnet.public : s.id]
    security_groups = [aws_security_group.task.id]
    # Public IP so the task can reach ECR/CloudWatch without a NAT gateway.
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8000
  }

  # Don't start the service until everything it needs exists: the listener (so
  # the target group is wired up), the database (so the app can connect on its
  # first try instead of crash-looping while RDS provisions, which takes a few
  # minutes), and the secret's value (so the app can read the credentials).
  depends_on = [
    aws_lb_listener.http,
    aws_db_instance.main,
    aws_secretsmanager_secret_version.db,
  ]
}
