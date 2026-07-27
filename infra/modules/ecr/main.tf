/**
 * Container image repositories.
 *
 * Only images we build live here. PostgREST and Realtime are pulled from their
 * upstream registries at task start — mirroring them would cost storage for no
 * benefit at this scale.
 *
 * One caveat worth knowing: anonymous Docker Hub pulls are rate-limited per
 * source IP. With a single instance pulling a handful of images that is fine,
 * but if you ever hit "toomanyrequests", the fix is an ECR pull-through cache
 * rule rather than retrying.
 *
 * Lifecycle policies matter more than they look: without them every deploy
 * leaves an untagged layer behind forever, and ECR storage quietly becomes a
 * line item. These keep the last N tagged images and expire untagged ones the
 * next day.
 */

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name = "${var.name_prefix}/${each.value}"

  # IMMUTABLE: a tag, once pushed, can never be repointed at different bytes.
  # This means deploys must tag by git SHA and task definitions must reference
  # that exact tag — never a floating `:latest`. That is the better pattern
  # regardless: what is running is always traceable to a commit, and a rollback
  # is a task-definition revision rather than a rebuild.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Basic scanning is free. Findings appear in the console per image.
    scan_on_push = true
  }

  encryption_configuration {
    # AES256 is free; KMS encryption adds per-request charges for no meaningful
    # gain on public application images.
    encryption_type = "AES256"
  }

  # Dev repositories should disappear with the environment. Prod keeps images
  # even if the repository resource is removed from state.
  force_delete = var.force_delete

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.value}" })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.keep_last_images} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
