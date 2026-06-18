variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix applied to all resources (and the Project tag)."
  type        = string
  default     = "url-shortener"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "image_tag" {
  description = "ECR image tag that Fargate should run."
  type        = string
  # Bumped to v2 in Phase 4: the v1 image was the in-memory build with no DB
  # driver and would crash-loop against Postgres. Build & push the new app as v2.
  default = "v2"
}

variable "db_name" {
  description = "Name of the initial Postgres database created by RDS."
  type        = string
  default     = "urlshortener"
}

variable "db_username" {
  description = "Master username for the Postgres database."
  type        = string
  default     = "appuser"
}

variable "github_owner" {
  description = "GitHub org/user that owns the repo allowed to deploy via OIDC."
  type        = string
  default     = "genkuroo"
}

variable "github_repo" {
  description = "GitHub repo name allowed to assume the deploy role via OIDC."
  type        = string
  default     = "url-shortener-aws"
}
