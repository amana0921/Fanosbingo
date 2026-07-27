/**
 * Remote state — partial configuration.
 *
 * The bucket name is supplied at init time (it embeds the AWS account id):
 *
 *   terraform init -backend-config="bucket=$TF_STATE_BUCKET"
 *
 * Separate state key from dev, so the two environments can never interfere with
 * each other. A shared state file is how a dev `terraform destroy` takes prod
 * with it.
 */

terraform {
  backend "s3" {
    key    = "prod/terraform.tfstate"
    region = "us-east-1"

    encrypt      = true
    use_lockfile = true
  }
}
