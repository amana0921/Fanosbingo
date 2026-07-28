/**
 * Pinned container-instance AMI for prod.
 *
 * ONE LINE, ON PURPOSE. .github/workflows/ami-bump.yml rewrites it and opens a
 * pull request when AWS publishes a newer ECS-optimized AL2023 arm64 image, so
 * the review diff is unambiguous and the instance replacement it causes is a
 * decision somebody made rather than a side effect of an unrelated apply.
 *
 * Empty means "follow whatever AWS currently recommends". That is correct for a
 * brand-new environment and wrong for one serving traffic -- the first bump PR
 * fills it in.
 *
 * To roll back a bad AMI: put the previous id here and apply. The id is in the
 * pull request history, which is the point of pinning it in git.
 */

locals {
  ecs_ami_id = ""
}
