# Outputs are values Terraform prints after `apply` and that later phases (and
# you, from the CLI) can reference. `terraform output` reprints them anytime.

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (ALB + Fargate)."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (RDS)."
  value       = [for s in aws_subnet.private : s.id]
}

output "ecr_repository_url" {
  description = "URL of the ECR repository to push the app image to."
  value       = aws_ecr_repository.app.repository_url
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer — the app's URL."
  value       = "http://${aws_lb.main.dns_name}"
}
