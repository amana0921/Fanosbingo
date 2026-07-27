/**
 * Remote state — partial configuration.
 *
 * The bucket name is supplied at init time rather than hardcoded, because it
 * embeds the AWS account id and should not be baked into the repository:
 *
 *   terraform init -backend-config="bucket=$TF_STATE_BUCKET"
 *
 * CI passes it from the TF_STATE_BUCKET GitHub variable. Locally, either pass
 * the same flag or create an untracked backend.hcl (gitignored):
 *
 *   echo 'bucket = "fanosbingo-tfstate-123456789012"' > backend.hcl
 *   terraform init -backend-config=backend.hcl
 *
 * The bucket itself is created by scripts/bootstrap-aws.sh — Terraform cannot
 * create the backend it is about to store its own state in.
 *
 * State holds RDS endpoints and every attribute Terraform manages, in plaintext
 * JSON. Bootstrap enables versioning, encryption and a public-access block on
 * it; do not weaken any of those.
 */

terraform {
  backend "s3" {
    key    = "dev/terraform.tfstate"
    region = "us-east-1"

    encrypt = true

    # S3-native locking (Terraform 1.11+), replacing the old DynamoDB lock table.
    use_lockfile = true
  }
}
