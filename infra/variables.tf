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
  default     = "v1"
}
