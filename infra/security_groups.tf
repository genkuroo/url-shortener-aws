# Phase 3 — Security groups (per-resource firewalls)
#
# The chain: internet → (port 80) → ALB → (port 8000) → containers.
# Containers accept traffic ONLY from the ALB's security group, never directly
# from the internet — even though they sit in public subnets.

# ALB: accept HTTP (port 80) from anyone on the internet.
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Allow HTTP from the internet to the load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# Containers: accept the app port (8000) ONLY from the ALB security group.
# Referencing the ALB's SG (not a CIDR) is "security-group chaining" — the rule
# follows the ALB wherever its IPs are, instead of pinning to fixed addresses.
resource "aws_security_group" "task" {
  name        = "${var.project}-task"
  description = "Allow app traffic from the ALB to the containers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from ALB only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Outbound open so the task can pull its image from ECR and write logs.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-task-sg" }
}

# Phase 4 — Database: accept Postgres (port 5432) ONLY from the task security
# group. This extends the chain one more hop: internet → ALB → task → db. The
# database is unreachable from the internet (private subnets) AND from anything
# in the VPC except the app containers.
resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = "Allow Postgres from the Fargate tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from app tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }

  # No egress rules needed — the database never initiates outbound connections.
  # (Omitting egress entirely denies all outbound, which is fine for RDS.)

  tags = { Name = "${var.project}-db-sg" }
}
