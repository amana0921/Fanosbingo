/**
 * Remote state — partial configuration.
 *
 * Same bucket as the environment roots, different key. The bucket name embeds
 * the AWS account id and is supplied at init time:
 *
 *   terraform init -backend-config="bucket=$TF_STATE_BUCKET"
 */

terraform {
  backend "s3" {
    key    = "account/terraform.tfstate"
    region = "us-east-1"

    encrypt = true

    use_lockfile = true
  }
}
