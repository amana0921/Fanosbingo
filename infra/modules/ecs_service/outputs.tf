output "service_name" {
  description = "ECS service name, for `aws ecs update-service` in CI."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "Task definition ARN at the last terraform apply. CI registers newer revisions."
  value       = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "Task definition family. CI registers new revisions against this."
  value       = aws_ecs_task_definition.this.family
}
