# Phase 2 — ECR (Elastic Container Registry)
#
# A private registry that stores our built container image. We push the image
# here from the laptop; in Phase 3 the Fargate service pulls it from here to run.

resource "aws_ecr_repository" "app" {
  name = var.project

  # Allow `terraform destroy` to delete the repo even if it still holds images
  # (fits the tear-down workflow; you'd set this to false in production).
  force_delete = true

  # Scan images for known vulnerabilities automatically on push.
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-ecr" }
}
