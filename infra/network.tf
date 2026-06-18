# Phase 1 — Networking
#
# A VPC with two public subnets (for the ALB + Fargate tasks) and two private
# subnets (for RDS), spread across two Availability Zones. No NAT gateway: the
# private subnets have no route to the internet, which keeps RDS isolated AND
# avoids the ~$32/mo NAT cost.

# Look up the AZs available in this region so we don't hard-code AZ names.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use the first two AZs in whatever region we're deploying to.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # One map entry per subnet. for_each (below) turns each into a real subnet.
  public_subnets = {
    public-a = { cidr = "10.0.0.0/24", az = local.azs[0] }
    public-b = { cidr = "10.0.1.0/24", az = local.azs[1] }
  }

  private_subnets = {
    private-a = { cidr = "10.0.10.0/24", az = local.azs[0] }
    private-b = { cidr = "10.0.11.0/24", az = local.azs[1] }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# The internet gateway is what makes the public subnets actually public.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}

# Public subnets: instances launched here get a public IP automatically.
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${each.key}"
    Tier = "public"
  }
}

# Private subnets: no public IPs, no internet route. RDS lives here.
resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${var.project}-${each.key}"
    Tier = "private"
  }
}

# Public route table: send all non-local traffic (0.0.0.0/0) to the internet
# gateway, then attach it to both public subnets.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route table: intentionally has NO 0.0.0.0/0 route. Traffic can only
# move within the VPC (the implicit "local" route), so RDS can't reach — and
# can't be reached from — the internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
