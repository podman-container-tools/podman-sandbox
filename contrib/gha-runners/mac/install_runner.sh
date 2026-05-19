#!/usr/bin/env bash
# Configure a GHA self-hosted runner on an already-launched EC2 Mac instance:
# downloads actions/runner, runs config.sh, installs a LaunchDaemon, kicks it
# off. Verifies the runner reaches 'online' before exiting.
#
# Required IAM: ec2:DescribeInstances, secretsmanager:GetSecretValue
# Required gh : admin or maintain on the target repo

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd aws gh ssh jq

INSTANCE_ID=""
IP=""
NAME=""
REPO="$DEFAULT_REPO"
LABEL="$RUNNER_LABEL"

usage() {
    cat >&2 <<EOF
Usage: $0 (--instance-id <i-...> | --ip <public-ip>) --name <MacM1-X>
          [--repo <owner/repo>] [--label <label>]

  --instance-id  EC2 instance to target (public IP resolved automatically)
  --ip           Public IP, alternative to --instance-id
  --name         Runner name + LaunchDaemon label suffix (required)
  --repo         GitHub repo, default '$DEFAULT_REPO'
  --label        Custom label for the runner, default '$RUNNER_LABEL'
                 (GitHub auto-adds self-hosted, macOS, ARM64)
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --ip)          IP="$2"; shift 2 ;;
        --name)        NAME="$2"; shift 2 ;;
        --repo)        REPO="$2"; shift 2 ;;
        --label)       LABEL="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)             log "unknown argument: $1"; usage ;;
    esac
done

[ -n "$NAME" ] || { log "--name is required"; usage; }
valid_runner_name "$NAME" || die "--name must be [A-Za-z0-9._-]{1,64}"
valid_repo "$REPO"        || die "--repo must look like 'owner/repo'"
valid_label "$LABEL"      || die "--label must be [A-Za-z0-9._-]{1,32}"
if [ -n "$INSTANCE_ID" ] && [ -n "$IP" ]; then
    log "use --instance-id OR --ip, not both"; usage
fi
[ -n "$INSTANCE_ID" ] || [ -n "$IP" ] || { log "one of --instance-id or --ip is required"; usage; }
[ -z "$INSTANCE_ID" ] || [[ "$INSTANCE_ID" =~ ^i-[0-9a-f]+$ ]] \
    || die "--instance-id must look like 'i-0123456789abcdef'"
[ -z "$IP" ] || [[ "$IP" =~ ^[0-9.]+$ ]] || die "--ip must be a dotted IPv4"

# --- Resolve IP if needed ----------------------------------------------------

if [ -z "$IP" ]; then
    IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
    [ -n "$IP" ] && [ "$IP" != "None" ] \
        || die "could not resolve public IP for $INSTANCE_ID"
fi
log "Target     : $IP (name=$NAME, repo=$REPO, label=$LABEL)"

# --- Pre-flight: gh + SSH ----------------------------------------------------

fetch_ssh_key

log "Minting registration token..."
REG_TOKEN=$(gh_registration_token "$REPO")

# --- Render plist locally ----------------------------------------------------

PLIST_TMPL="$SCRIPT_DIR/launchd/com.github.actions.runner.plist.tmpl"
[ -f "$PLIST_TMPL" ] || die "plist template not found: $PLIST_TMPL"

PLIST_TMP=$(mktemp -t mac-gha-plist.XXXXXX)
# shellcheck disable=SC2064  # capture $PLIST_TMP value now
trap "cleanup_ssh_key; rm -f '$PLIST_TMP'" EXIT
# Use a safe sed-free substitution (the runner name is user-supplied)
awk -v n="$NAME" '{ gsub(/__RUNNER_NAME__/, n); print }' "$PLIST_TMPL" > "$PLIST_TMP"

# --- Remote provisioning -----------------------------------------------------
# REG_TOKEN must not appear in the remote argv (visible in ps for ~30s
# during config.sh). Pipe everything via stdin so the token enters the
# remote bash's environment, not its command line. `%q` escapes for re-eval.
log "Configuring runner on $IP (this takes ~30s)..."
{
    printf 'REG_TOKEN=%q\nRUNNER_VERSION=%q\nRUNNER_NAME=%q\nREPO=%q\nLABEL=%q\nexport REG_TOKEN RUNNER_VERSION RUNNER_NAME REPO LABEL\n' \
        "$REG_TOKEN" "$RUNNER_VERSION" "$NAME" "$REPO" "$LABEL"
    cat <<'REMOTE_EOF'
set -euo pipefail

cd "$HOME"
if [ -d actions-runner ]; then
    echo "ERROR: ~/actions-runner already exists. Run teardown.sh first." >&2
    exit 1
fi

mkdir actions-runner
cd actions-runner
curl -fsSL -o actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
tar xzf actions-runner.tar.gz
rm actions-runner.tar.gz

./config.sh --url "https://github.com/${REPO}" \
            --token "$REG_TOKEN" \
            --name "$RUNNER_NAME" \
            --labels "$LABEL" \
            --work _work \
            --unattended --replace
REMOTE_EOF
} | ssh_runner "$IP" 'bash -s'

# Push the plist file
log "Installing LaunchDaemon..."
PLIST_PATH="/Library/LaunchDaemons/com.github.actions.runner.${NAME}.plist"
ssh_runner "$IP" "sudo tee '$PLIST_PATH' >/dev/null" < "$PLIST_TMP"
ssh_runner "$IP" "sudo chown root:wheel '$PLIST_PATH' && sudo chmod 644 '$PLIST_PATH'"
ssh_runner "$IP" "sudo launchctl bootstrap system '$PLIST_PATH' && \
                  sudo launchctl enable 'system/com.github.actions.runner.${NAME}' && \
                  sudo launchctl kickstart -k 'system/com.github.actions.runner.${NAME}'"

# --- Verify online -----------------------------------------------------------

log "Waiting for runner to register as online..."
for _ in $(seq 1 30); do
    status=$(gh api "repos/${REPO}/actions/runners" \
        --jq ".runners[] | select(.name==\"$NAME\") | .status" 2>/dev/null || true)
    if [ "$status" = "online" ]; then
        log "Runner '$NAME' is online."
        exit 0
    fi
    sleep 2
done

die "runner '$NAME' did not become online within 60s. Check:
    ssh -i \$KEY_FILE ec2-user@$IP 'tail -50 ~/actions-runner/runner.err.log'"
