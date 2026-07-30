/**
 * Pinned container-instance AMI for dev.
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
  # Pinned 2026-07-29 to the image the running instance is already on, so this
  # is a no-op rather than an upgrade.
  #
  # It was "" until now, which meant the launch template's image_id followed the
  # SSM recommended pointer -- the exact behaviour modules/ecs warns about in its
  # header. AWS has since published ami-0d52a9965700d5237, so the next apply for
  # any reason at all was going to rewrite image_id as a side effect. It showed
  # up in the plan for a Cloudflare rate-limit change, which is precisely the
  # "riding along invisibly" the pin exists to prevent.
  #
  # ami-bump.yml was meant to fill this in and has never run: its first
  # scheduled fire is the Monday after the workflow landed. Waiting for that
  # left the environment unpinned in the meantime.
  #
  # The upgrade to the newer image is deliberately NOT taken here. It belongs in
  # its own pull request, from ami-bump.yml, where the instance replacement it
  # causes is the subject of the change rather than a footnote to one.
  ecs_ami_id = "ami-0b196d9d9718c1dd3"
}
