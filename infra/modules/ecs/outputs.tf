output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "capacity_provider_name" {
  description = <<-EOT
    Capacity provider backing the cluster. Stage 3 replaces this with FARGATE
    on the service's capacity_provider_strategy; task definitions do not change.
  EOT
  value       = aws_ecs_capacity_provider.app.name
}

output "log_group_name" {
  description = "CloudWatch log group for container logs."
  value       = aws_cloudwatch_log_group.ecs.name
}

output "autoscaling_group_name" {
  description = "ASG name, for instance-refresh and alarm dimensions."
  value       = aws_autoscaling_group.app.name
}

output "public_ip" {
  description = <<-EOT
    Elastic IP the instance claims on boot. Point the Cloudflare A records for
    api.<domain> and rt.<domain> at this, both PROXIED (orange cloud).
  EOT
  value       = aws_eip.app.public_ip
}

output "eip_allocation_id" {
  description = "Elastic IP allocation id."
  value       = aws_eip.app.allocation_id
}

output "ecs_ami_id" {
  description = "ECS-optimized AL2023 arm64 AMI currently resolved."
  value       = local.ecs_ami_id
}

output "recommended_ecs_ami_id" {
  description = "The AMI AWS currently recommends. Differs from ecs_ami_id when the pin is behind; .github/workflows/ami-bump.yml watches for exactly that."
  value       = data.aws_ssm_parameter.ecs_ami.value
}
