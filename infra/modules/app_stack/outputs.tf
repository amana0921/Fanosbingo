output "resolved_images" {
  description = "Image URI in effect per service. A null means the service has never been built and was not created."
  value       = local.images
}

output "running_services" {
  description = "Services this environment actually created."
  value       = [for name, image in local.images : name if image != null]
}

output "image_parameter_path" {
  description = "SSM path the deploy workflow writes image pointers to."
  value       = "/${var.name_prefix}/images"
}
