output "github_deploy_role_arn" {
  description = "Set this as AWS_ROLE_ARN in the GitHub Actions workflow."
  value       = aws_iam_role.github_deploy.arn
}

output "github_oidc_provider_arn" {
  description = "OIDC provider ARN. Pass to the other environment as existing_github_oidc_provider_arn."
  value       = local.github_oidc_arn
}

output "ec2_instance_profile_name" {
  description = "Instance profile for the ECS container instance launch template."
  value       = aws_iam_instance_profile.ec2_instance.name
}

output "ec2_instance_role_arn" {
  description = "EC2 container instance role."
  value       = aws_iam_role.ec2_instance.arn
}

output "task_execution_role_arn" {
  description = "ECS task execution role, shared by every task definition."
  value       = aws_iam_role.task_execution.arn
}

output "task_ticker_role_arn" {
  description = "Runtime role for the ticker (game loop + deposit indexer)."
  value       = aws_iam_role.task_ticker.arn
}

output "task_functions_role_arn" {
  description = "Runtime role for the ported functions. The only principal that may sign withdrawals."
  value       = aws_iam_role.task_functions.arn
}

output "task_data_role_arn" {
  description = "Runtime role for PostgREST, Realtime and Caddy."
  value       = aws_iam_role.task_data.arn
}

output "metric_namespace" {
  description = "CloudWatch namespace the task roles are permitted to publish to."
  value       = local.metric_namespc
}
