output "main_key_arn" {
  description = "Symmetric CMK for encryption at rest."
  value       = aws_kms_key.main.arn
}

output "main_key_id" {
  description = "Symmetric CMK id."
  value       = aws_kms_key.main.key_id
}

output "main_key_alias" {
  description = "Alias for the encryption CMK."
  value       = aws_kms_alias.main.name
}

output "wallet_signing_key_arn" {
  description = "secp256k1 signing key. Private material is non-exportable by design."
  value       = aws_kms_key.wallet_signing.arn
}

output "wallet_signing_key_id" {
  description = <<-EOT
    secp256k1 signing key id. Derive the BSC wallet address from its public key:
      aws kms get-public-key --key-id <this> --query PublicKey --output text
    then keccak256 the uncompressed point and take the last 20 bytes.
  EOT
  value       = aws_kms_key.wallet_signing.key_id
}
