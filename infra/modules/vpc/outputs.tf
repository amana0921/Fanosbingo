output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids, ordered by AZ. Index 0 hosts the instance today."
  value       = aws_subnet.public[*].id
}

output "isolated_subnet_ids" {
  description = "Isolated subnet ids. Consumed by the rds module's subnet group."
  value       = aws_subnet.isolated[*].id
}

output "availability_zones" {
  description = "The two AZs this VPC spans."
  value       = local.azs
}
