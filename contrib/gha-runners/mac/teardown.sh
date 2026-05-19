#!/usr/bin/env bash
# Reverse of setup_host.sh: deregister the runner from GitHub, stop and
# remove the LaunchDaemon, optionally terminate the EC2 instance.
#
# Required IAM: ec2:DescribeInstances, ec2:TerminateInstances (only if
# --terminate-instance), secretsmanager:GetSecretValue
# Required gh : admin or maintain on the target repo

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd aws gh

NAME=""
REPO="$DEFAULT_REPO"
TERMINATE=false

usage() {
    cat >&2 <<EOF
Usage: $0 --name <MacM1-X> [--repo <owner/repo>] [--terminate-instance]

  --name                 Runner name (also the Instance Name tag)
  --repo                 GitHub repo, default '$DEFAULT_REPO'
  --terminate-instance   Also terminate the EC2 instance (default: keep alive)
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)               NAME="$2"; shift 2 ;;
        --repo)               REPO="$2"; shift 2 ;;
        --terminate-instance) TERMINATE=true; shift ;;
        -h|--help)            usage ;;
        *)                    log "unknown argument: $1"; usage ;;
    esac
done

[ -n "$NAME" ] || { log "--name is required"; usage; }
valid_runner_name "$NAME" || die "--name must be [A-Za-z0-9._-]{1,64}"
valid_repo "$REPO"        || die "--repo must look like 'owner/repo'"

# --- Deregister from GitHub --------------------------------------------------

runner_id=$(gh_runner_id_by_name "$REPO" "$NAME")
if [ -n "$runner_id" ]; then
    log "Deregistering runner '$NAME' (id=$runner_id) from $REPO..."
    gh api -X DELETE "repos/${REPO}/actions/runners/${runner_id}" >/dev/null
else
    log "Runner '$NAME' not registered with $REPO (nothing to deregister)."
fi

# --- Find the instance -------------------------------------------------------

INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    log "No live instance named '$NAME' — nothing more to do."
    exit 0
fi

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ]; then
    log "Removing LaunchDaemon on $PUBLIC_IP..."
    fetch_ssh_key
    trap cleanup_ssh_key EXIT
    PLIST_PATH="/Library/LaunchDaemons/com.github.actions.runner.${NAME}.plist"
    ssh_runner "$PUBLIC_IP" "
        set +e
        sudo launchctl bootout 'system/com.github.actions.runner.${NAME}' 2>/dev/null
        sudo rm -f '$PLIST_PATH'
        rm -rf \$HOME/actions-runner
        true
    "
fi

if $TERMINATE; then
    log "Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
    log "Termination requested (host will scrub for ~24h before reuse)."
else
    log "Instance $INSTANCE_ID left running (use --terminate-instance to stop it)."
fi

log "Teardown complete for '$NAME'."
