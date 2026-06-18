# Phase 5 — CI/CD identity (GitHub Actions → AWS via OIDC)
#
# The problem this solves: GitHub Actions needs to push images to ECR and tell
# ECS to redeploy — but we don't want long-lived AWS access keys sitting in
# GitHub secrets (they leak, they never expire, they're a top cause of breaches).
#
# OIDC fixes that. GitHub hands each workflow run a short-lived, signed identity
# token. AWS is told to TRUST that token issuer, and to let it assume an IAM role
# — but only for our specific repo and branch. The credentials the workflow gets
# last minutes and are scoped to exactly what a deploy needs. Nothing is stored.

# Fetch GitHub's OIDC TLS certificate so we can register its thumbprint without
# hard-coding a fingerprint that could change over time.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# Tell AWS to trust GitHub's OIDC token issuer. "Audience" sts.amazonaws.com is
# what the configure-aws-credentials action requests.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = { Name = "${var.project}-github-oidc" }
}

# Trust policy: only a token from GitHub's issuer (the provider above), for the
# sts audience, AND whose "sub" claim is THIS repo on the main branch, may assume
# the role. A different repo, a fork, or a feature branch cannot.
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json

  tags = { Name = "${var.project}-github-actions" }
}

# Least-privilege permissions for a deploy: authenticate to ECR, push to OUR
# repo, and trigger a redeploy of OUR service. Nothing else.
data "aws_iam_policy_document" "github_actions" {
  # ECR auth token is account-wide and can't be resource-scoped.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull layers and images, scoped to this one repository.
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # Trigger and watch a rolling deploy of our service. force-new-deployment uses
  # UpdateService; the workflow's "wait" step polls DescribeServices.
  statement {
    sid       = "EcsDeploy"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = [aws_ecs_service.app.id]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${var.project}-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}
