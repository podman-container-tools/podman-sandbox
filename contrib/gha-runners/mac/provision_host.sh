#!/usr/bin/env bash
# Launch a mac2.metal instance on a Mac Dedicated Host using the canonical
# launch template, then wait for SSH to be reachable with the shared key.
#
# Outputs (last 2 lines, machine-parseable):
#   INSTANCE_ID=<i-...>
#   PUBLIC_IP=<ip>
#
# Required IAM:
#   ec2:DescribeHosts, ec2:DescribeSubnets, ec2:RunInstances,
#   ec2:DescribeInstances, ec2:CreateTags, secretsmanager:GetSecretValue

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd aws jq

HOST_ID=""
NAME=""
SUBNET_ID=""

usage() {
    cat >&2 <<EOF
Usage: $0 --host-id <h-...> [--name <MacM1-X>] [--subnet-id <subnet-...>]

  --host-id     Dedicated Host ID to launch on (must be tagged purpose=github)
  --name        Instance Name tag. Defaults to the host's Name tag.
  --subnet-id   Subnet to use. Defaults to first subnet in the host's AZ.
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host-id)   HOST_ID="$2"; shift 2 ;;
        --name)      NAME="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *)           log "unknown argument: $1"; usage ;;
    esac
done

[ -n "$HOST_ID" ] || { log "--host-id is required"; usage; }
[[ "$HOST_ID" =~ ^h-[0-9a-f]+$ ]] || die "--host-id must look like 'h-0123456789abcdef'"
[ -z "$NAME" ] || valid_runner_name "$NAME" || die "--name must be [A-Za-z0-9._-]{1,64}"
[ -z "$SUBNET_ID" ] || [[ "$SUBNET_ID" =~ ^subnet-[0-9a-f]+$ ]] || die "--subnet-id must look like 'subnet-0123...'"

# --- Validate host -----------------------------------------------------------

host_json=$(aws ec2 describe-hosts --host-ids "$HOST_ID" --output json \
    2>/dev/null || die "host $HOST_ID not found")

host_state=$(jq -r '.Hosts[0].State' <<<"$host_json")
host_az=$(jq -r '.Hosts[0].AvailabilityZone' <<<"$host_json")
host_instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' <<<"$host_json")
host_purpose=$(jq -r '.Hosts[0].Tags[]? | select(.Key=="purpose") | .Value' <<<"$host_json")
host_name_tag=$(jq -r '.Hosts[0].Tags[]? | select(.Key=="Name") | .Value' <<<"$host_json")
host_running=$(jq -r '.Hosts[0].Instances | length' <<<"$host_json")

[ "$host_state" = "available" ] \
    || die "host $HOST_ID state is '$host_state' (need 'available')"
[ "$host_purpose" = "github" ] \
    || die "host $HOST_ID is not tagged purpose=github (got '$host_purpose'); refusing to clobber a non-github host"
[ "$host_running" = "0" ] \
    || die "host $HOST_ID already has $host_running instance(s) running; refusing to launch another"

[ -n "$NAME" ] || NAME="${host_name_tag:-mac-gha-runner-${HOST_ID#h-}}"
# Re-validate after defaulting from the host's Name tag (the tag value is
# attacker-influenceable if someone has aws ec2 create-tags on the host).
valid_runner_name "$NAME" \
    || die "resolved name '$NAME' fails [A-Za-z0-9._-]{1,64} (host Name tag?)"

log "Target host : $HOST_ID ($host_name_tag, $host_instance_type, $host_az)"
log "Instance Name: $NAME"

# --- Resolve subnet ----------------------------------------------------------

if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID=$(aws_subnet_for_az "$host_az")
fi
log "Subnet      : $SUBNET_ID"

# --- Launch ------------------------------------------------------------------

log "Launching instance..."
launch_json=$(aws ec2 run-instances \
    --launch-template "LaunchTemplateId=${LAUNCH_TEMPLATE_ID},Version=${LAUNCH_TEMPLATE_VERSION}" \
    --key-name "$KEYPAIR_NAME" \
    --subnet-id "$SUBNET_ID" \
    --placement "HostId=${HOST_ID},Tenancy=host" \
    --tag-specifications "ResourceType=instance,Tags=[
        {Key=Name,Value=${NAME}},
        {Key=purpose,Value=github},
        {Key=PWPoolReady,Value=false},
        {Key=automation,Value=false},
        {Key=architecture,Value=arm64_mac},
        {Key=provisioned-by,Value=mac-gha-runner-scripts}
    ]" \
    --count 1 \
    --output json)

INSTANCE_ID=$(jq -r '.Instances[0].InstanceId' <<<"$launch_json")
log "Launched   : $INSTANCE_ID"

log "Waiting for instance to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
log "Public IP  : $PUBLIC_IP"

# --- Wait for SSH ------------------------------------------------------------

fetch_ssh_key
trap cleanup_ssh_key EXIT
wait_ssh "$PUBLIC_IP"

# Machine-parseable output (last lines)
echo "INSTANCE_ID=$INSTANCE_ID"
echo "PUBLIC_IP=$PUBLIC_IP"
