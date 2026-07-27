/**
 * VPC, subnets and routing.
 *
 * Deliberately has NO NAT Gateway. A NAT Gateway is ~$32/mo plus data charges,
 * which alone would consume a third of the monthly budget. Instead the single
 * application instance runs in a public subnet with a public IP; its security
 * group (see the security_groups module) admits traffic only from Cloudflare's
 * edge, so it is not directly reachable from the internet.
 *
 * RDS lives in isolated subnets whose route table has no internet route at all,
 * so the database has no path to or from the internet in either direction.
 *
 * The second public subnet and second isolated subnet are created but left
 * empty. They exist so that Stage 2 — two instances across two AZs and Multi-AZ
 * RDS — becomes a change to the ecs and rds modules only, never a change here.
 */

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# ---------------------------------------------------------------------------
# Public subnets — the application instance (no NAT required)
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Isolated subnets — RDS only. No routes beyond local.
# ---------------------------------------------------------------------------
resource "aws_subnet" "isolated" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-isolated-${local.azs[count.index]}"
    Tier = "isolated"
  })
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-isolated-rt" })
}

resource "aws_route_table_association" "isolated" {
  count = 2

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}
