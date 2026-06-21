# Phase 6 — Observability (CloudWatch dashboard, alarms, SNS alerts)
#
# Three pieces work together here:
#   1. An SNS topic + email subscription — the notification channel.
#   2. CloudWatch alarms that watch a metric and publish to that topic when a
#      threshold is breached (and again when it recovers).
#   3. A CloudWatch dashboard that graphs the app's golden signals so you can
#      eyeball health at a glance.
#
# The metrics themselves are emitted for free by the ALB and (with Container
# Insights enabled in ecs.tf) by ECS — we don't instrument anything by hand.

# ---------------------------------------------------------------------------
# Notification channel: SNS topic + email subscription
# ---------------------------------------------------------------------------
# Alarms publish to this topic; the topic fans out to subscribers. Email is the
# simplest subscriber. NOTE: AWS sends a confirmation email on first apply — you
# must click its link once before notifications flow (state stays
# "pending confirmation" until you do).
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------
# Server errors: more than a handful of 5xx responses from the app in a minute
# means something is broken (DB down, unhandled exception). This is the alarm we
# deliberately test by forcing it into ALARM state — see CLAUDE.md.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name        = "${var.project}-target-5xx"
  alarm_description = "App returned more than 5 HTTP 5xx responses in a minute."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }

  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  # No 5xx errors emits no data points; absence of errors is healthy, not unknown.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # notify on recovery too
}

# No healthy targets: the ALB has nothing to forward to, so the site is down.
# This catches a crash-looping task even if it never returns a 5xx.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.project}-unhealthy-hosts"
  alarm_description = "No healthy ECS tasks registered with the ALB target group."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2 # ~2 min, so a single in-flight deploy doesn't page
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data here means no healthy hosts

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# Dashboard — the app's golden signals on one screen
# ---------------------------------------------------------------------------
# Built with jsonencode so the layout is real Terraform, not a pasted blob.
# Each widget is a 12-wide half-row; (x,y) place them on a 24-column grid.
locals {
  alb_dim = ["LoadBalancer", aws_lb.main.arn_suffix]
  tg_dim  = ["TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix]
  ecs_dim = ["ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Requests / min"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim, [{ stat = "Sum", label = "Requests" }])
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Latency (target response time, s)"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95", label = "p95" }]),
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "Average", label = "avg" }])
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "5xx errors / min"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim, [{ stat = "Sum", label = "app 5xx" }]),
            concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim, [{ stat = "Sum", label = "ALB 5xx" }])
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "ECS CPU & memory (%)"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          yAxis   = { left = { min = 0, max = 100 } }
          metrics = [
            concat(["AWS/ECS", "CPUUtilization"], local.ecs_dim, [{ stat = "Average", label = "CPU %" }]),
            concat(["AWS/ECS", "MemoryUtilization"], local.ecs_dim, [{ stat = "Average", label = "Memory %" }])
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Healthy vs. unhealthy tasks"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dim, [{ stat = "Minimum", label = "healthy" }]),
            concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg_dim, [{ stat = "Maximum", label = "unhealthy" }])
          ]
        }
      }
    ]
  })
}
