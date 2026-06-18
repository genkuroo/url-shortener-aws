# Phase 3 — Application Load Balancer (the public front door)
#
# The ALB receives all internet traffic on port 80, health-checks the
# containers, and forwards requests only to healthy ones.

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false # internet-facing
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for s in aws_subnet.public : s.id] # needs 2 AZs

  tags = { Name = "${var.project}-alb" }
}

# A target group is the pool of containers the ALB forwards to. target_type
# "ip" is required for Fargate (each task gets its own IP via awsvpc networking).
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  # The ALB calls /healthz; a container must answer 200 to receive traffic.
  health_check {
    path                = "/healthz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
    timeout             = 5
  }

  tags = { Name = "${var.project}-tg" }
}

# The listener ties it together: traffic arriving on port 80 is forwarded to the
# target group.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
