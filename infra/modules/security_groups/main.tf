/**
 * Security groups.
 *
 * The application instance sits in a public subnet, which is only safe because
 * of the ingress lock below: port 443 is reachable exclusively from Cloudflare's
 * published edge ranges. Without this, an attacker could hit the Elastic IP
 * directly and bypass Cloudflare's WAF and rate limiting entirely — which is the
 * whole reason we can skip a $17/mo ALB and a $13/mo AWS WAF.
 *
 * Cloudflare's ranges are fetched at plan time rather than hardcoded, because
 * they do change. If the fetch fails the plan fails loudly, which is the right
 * outcome: better a broken plan than a security group that silently admits
 * nothing (locking you out) or is quietly left stale.
 */

data "http" "cloudflare_ips_v4" {
  url = "https://www.cloudflare.com/ips-v4"

  request_headers = {
    Accept = "text/plain"
  }
}

locals {
  cloudflare_ipv4 = [
    for cidr in split("\n", trimspace(data.http.cloudflare_ips_v4.response_body)) :
    trimspace(cidr) if trimspace(cidr) != ""
  ]
}

# Guard against the endpoint returning something unexpected (an error page, an
# empty body). Cloudflare publishes ~15 IPv4 ranges; anything far outside that
# means we should not be writing security group rules from it.
resource "terraform_data" "cloudflare_range_sanity" {
  lifecycle {
    precondition {
      condition     = length(local.cloudflare_ipv4) >= 10 && length(local.cloudflare_ipv4) <= 40
      error_message = "Fetched ${length(local.cloudflare_ipv4)} Cloudflare ranges, expected 10-40. Refusing to build security group rules from a suspect response."
    }
  }
}

# ---------------------------------------------------------------------------
# Application instance
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "Application instance. HTTPS from Cloudflare edge only; no SSH."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_https_from_cloudflare" {
  for_each = toset(local.cloudflare_ipv4)

  security_group_id = aws_security_group.app.id
  description       = "HTTPS from Cloudflare edge ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  depends_on = [terraform_data.cloudflare_range_sanity]
}

# No port 22 rule, anywhere. Shell access is via SSM Session Manager, which
# needs no inbound rule, no key pair, and leaves a CloudTrail audit trail.

# Egress is unrestricted because the instance must reach the BSC RPC providers,
# the Telegram Bot API, ECR, SSM and CloudWatch. There is no NAT Gateway to
# route through, so this is its only path out.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound (BSC RPC, Telegram, ECR, SSM, CloudWatch)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "PostgreSQL. Reachable only from the application security group."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Referencing the app security group rather than a CIDR means this stays correct
# when the instance is replaced or a second one is added in Stage 2.
resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from the application instances only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# No egress rule: RDS never initiates outbound connections.
