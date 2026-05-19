#!/usr/bin/env bash
# Convenience wrapper: provision_host.sh + install_runner.sh in one call.
# Most operators should use this.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

HOST_ID=""
NAME=""
REPO="$DEFAULT_REPO"
LABEL="$RUNNER_LABEL"

usage() {
    cat >&2 <<EOF
Usage: $0 --host-id <h-...> [--name <MacM1-X>]
          [--repo <owner/repo>] [--label <label>]

Provisions a fresh instance on the given Dedicated Host and installs a GHA
self-hosted runner. Composes provision_host.sh + install_runner.sh.

  --host-id   Dedicated Host ID (tagged purpose=github)
  --name      Instance + runner name. Defaults to the host's Name tag.
  --repo      GitHub repo, default '$DEFAULT_REPO'
  --label     Custom runner label, default '$RUNNER_LABEL'
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host-id) HOST_ID="$2"; shift 2 ;;
        --name)    NAME="$2"; shift 2 ;;
        --repo)    REPO="$2"; shift 2 ;;
        --label)   LABEL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)         log "unknown argument: $1"; usage ;;
    esac
done

[ -n "$HOST_ID" ] || { log "--host-id is required"; usage; }
[[ "$HOST_ID" =~ ^h-[0-9a-f]+$ ]] || die "--host-id must look like 'h-0123456789abcdef'"
[ -z "$NAME" ] || valid_runner_name "$NAME" || die "--name must be [A-Za-z0-9._-]{1,64}"
valid_repo "$REPO"   || die "--repo must look like 'owner/repo'"
valid_label "$LABEL" || die "--label must be [A-Za-z0-9._-]{1,32}"

# Run provision and capture its trailing INSTANCE_ID=... / PUBLIC_IP=... lines.
log "=== provisioning ==="
provision_args=(--host-id "$HOST_ID")
[ -n "$NAME" ] && provision_args+=(--name "$NAME")

provision_out=$("$SCRIPT_DIR/provision_host.sh" "${provision_args[@]}")
echo "$provision_out"

INSTANCE_ID=$(printf '%s\n' "$provision_out" | awk -F= '/^INSTANCE_ID=/{print $2}')
[ -n "$INSTANCE_ID" ] || die "provision_host.sh did not print INSTANCE_ID"

# If --name was empty, recover it from the launched instance's tags.
if [ -z "$NAME" ]; then
    # JMESPath backticks are literal-value syntax, not shell substitution.
    # shellcheck disable=SC2016
    NAME=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`]|[0].Value' \
        --output text)
fi

log ""
log "=== installing runner ==="
"$SCRIPT_DIR/install_runner.sh" \
    --instance-id "$INSTANCE_ID" \
    --name "$NAME" \
    --repo "$REPO" \
    --label "$LABEL"

log ""
log "Done. Runner '$NAME' is registered with $REPO."
