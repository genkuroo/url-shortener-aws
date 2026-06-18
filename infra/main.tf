# Provider configuration. `default_tags` are applied to every taggable resource
# this provider creates, so we don't repeat them on each resource.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
