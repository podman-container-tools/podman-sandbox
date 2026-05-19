#!/usr/bin/env bash
# One-time setup: create the shared 'mac-gha-runner' EC2 keypair and store
# its private material in AWS Secrets Manager. Idempotent for the
# already-bootstrapped case (both keypair + secret already exist); refuses
# to proceed on a half-bootstrapped state so the operator investigates.
#
# Required IAM:
#   ec2:CreateKeyPair, ec2:DescribeKeyPairs,
#   secretsmanager:CreateSecret, secretsmanager:TagResource

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd aws mktemp

kp_exists=false
secret_exists=false

if aws ec2 describe-key-pairs --key-names "$KEYPAIR_NAME" >/dev/null 2>&1; then
    kp_exists=true
fi
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
    secret_exists=true
fi

if $kp_exists && $secret_exists; then
    log "Already bootstrapped: keypair '$KEYPAIR_NAME' and secret '$SECRET_NAME' both exist."
    exit 0
fi

if $kp_exists && ! $secret_exists; then
    die "keypair '$KEYPAIR_NAME' exists in EC2 but secret '$SECRET_NAME' is missing.
The private key cannot be recovered from EC2 — only from the operator who
created it. Fix manually: either restore the secret from a backup, or
delete the keypair (aws ec2 delete-key-pair --key-name $KEYPAIR_NAME) and
re-run this script."
fi

if ! $kp_exists && $secret_exists; then
    die "secret '$SECRET_NAME' exists but keypair '$KEYPAIR_NAME' is missing from EC2.
Either re-import the keypair into EC2 from the secret's public key, or
delete the secret (aws secretsmanager delete-secret --secret-id $SECRET_NAME
--force-delete-without-recovery) and re-run this script."
fi

log "Creating EC2 keypair '$KEYPAIR_NAME'..."
tmpfile=$(mktemp -t mac-gha-runner-priv.XXXXXX)
chmod 600 "$tmpfile"
# shellcheck disable=SC2064  # expand $tmpfile now (it's already set)
trap "rm -f '$tmpfile'" EXIT

aws ec2 create-key-pair \
    --key-name "$KEYPAIR_NAME" \
    --key-type ed25519 \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=purpose,Value=github},{Key=shared,Value=true}]" \
    --query KeyMaterial --output text > "$tmpfile"

log "Storing private key in Secrets Manager as '$SECRET_NAME'..."
aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Shared SSH private key for GHA self-hosted Mac runners (created by 00_bootstrap_key.sh)" \
    --secret-string "file://$tmpfile" \
    --tags '[{"Key":"purpose","Value":"github"},{"Key":"shared","Value":"true"}]' \
    >/dev/null

log ""
log "Bootstrap complete."
log "  Keypair : $KEYPAIR_NAME"
log "  Secret  : $SECRET_NAME"
log ""
log "Public key (for audit / authorized_keys append on existing hosts):"
aws ec2 describe-key-pairs \
    --key-names "$KEYPAIR_NAME" \
    --include-public-key \
    --query 'KeyPairs[0].PublicKey' --output text
