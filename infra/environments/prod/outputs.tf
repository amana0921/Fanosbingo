output "vpc_id" {
  description = "VPC id."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets. The application instance launches into index 0."
  value       = module.vpc.public_subnet_ids
}

output "isolated_subnet_ids" {
  description = "Isolated subnets backing the RDS subnet group."
  value       = module.vpc.isolated_subnet_ids
}

output "app_security_group_id" {
  description = "Security group for the application instance."
  value       = module.security_groups.app_security_group_id
}

output "rds_security_group_id" {
  description = "Security group for RDS."
  value       = module.security_groups.rds_security_group_id
}

output "cloudflare_ranges_admitted" {
  description = "How many Cloudflare ranges are allowed on 443. Expect ~15; 0 means the origin lock is broken."
  value       = module.security_groups.cloudflare_ipv4_count
}

output "kms_key_alias" {
  description = "Alias of the encryption CMK. Use with `aws ssm put-parameter --key-id`."
  value       = module.kms.main_key_alias
}

output "wallet_signing_key_id" {
  description = <<-EOT
    secp256k1 key id. Derive the deposit/withdrawal wallet address from it:
      aws kms get-public-key --key-id <this> --query PublicKey --output text
    The private half cannot be exported, which is the point.
  EOT
  value       = module.kms.wallet_signing_key_id
}

output "secrets_to_populate" {
  description = "SecureString parameters that MUST be set out-of-band before anything runs."
  value       = module.ssm.secret_parameter_names
}

output "app_public_ip" {
  description = <<-EOT
    Elastic IP of the application instance. Point Cloudflare A records for
    api.<domain> and rt.<domain> here, both PROXIED (orange cloud) so the
    security group's Cloudflare-only lock does not black-hole your traffic.
  EOT
  value       = module.ecs.public_ip
}

output "ecs_cluster_name" {
  description = "ECS cluster name, for `aws ecs` commands and CI deploys."
  value       = module.ecs.cluster_name
}

output "ecr_repository_urls" {
  description = "Repository URLs to docker push to."
  value       = module.ecr.repository_urls
}

output "rds_endpoint" {
  description = "PostgreSQL endpoint, host:port. Reachable only from inside the VPC."
  value       = module.rds.endpoint
}

output "rds_master_secret_arn" {
  description = <<-EOT
    Secrets Manager secret with the RDS-managed master password:
      aws secretsmanager get-secret-value --secret-id <this> \
        --query SecretString --output text
  EOT
  value       = module.rds.master_user_secret_arn
}

output "github_deploy_role_arn" {
  description = "Set as AWS_ROLE_ARN in the GitHub Actions workflow."
  value       = module.iam.github_deploy_role_arn
}

output "github_oidc_provider_arn" {
  description = "Pass to prod as existing_github_oidc_provider_arn; the provider is account-wide."
  value       = module.iam.github_oidc_provider_arn
}

output "spa_bucket_name" {
  description = "S3 bucket the built SPA is published to (created in Phase 5)."
  value       = local.spa_bucket_name
}

output "alerts_topic_arn" {
  description = "SNS topic for budget and alarm notifications."
  value       = module.monitoring.alerts_topic_arn
}

output "post_apply_checklist" {
  description = "What still needs doing by hand after a successful apply."
  value = [
    "1. Confirm the SNS subscription email(s) — unconfirmed means alarms go nowhere.",
    "2. Populate every SecureString in `secrets_to_populate` (they hold PLACEHOLDER_SET_ME_OUT_OF_BAND).",
    "3. Point Cloudflare A records for api.* and rt.* at `app_public_ip`, PROXIED (orange cloud).",
    "4. Reboot RDS once so rds.logical_replication and shared_preload_libraries take effect.",
    "5. Derive the wallet address from `wallet_signing_key_id` via kms get-public-key.",
  ]
}

output "metric_namespace" {
  description = "CloudWatch namespace for custom metrics such as SecondsSinceLastNumberCalled."
  value       = module.iam.metric_namespace
}
