# Shared helpers for the Mac GHA runner provisioning scripts.
# Sourced; do not execute. Callers `source ./lib.sh` and use the functions.

# shellcheck shell=bash

# --- Constants ---------------------------------------------------------------
# `export` not because these need to cross subshell boundaries, but to mark
# them as the library's public interface (silences shellcheck SC2034).

export KEYPAIR_NAME="mac-gha-runner"
export SECRET_NAME="mac-gha-runner/private-key"

# Launch template that ships the canonical Mac CI runner config (mac2.metal,
# macOS Tahoe AMI, 100GB EBS, default SG, tenancy=host, 96-hour failsafe
# UserData). v15 is the version validated for this work; bump deliberately if
# you switch AMIs or security groups.
export LAUNCH_TEMPLATE_ID="lt-022eab7d409952e5e"
export LAUNCH_TEMPLATE_VERSION="15"

# GHA actions/runner release. Bump and re-test against the workflow before
# committing.
export RUNNER_VERSION="2.334.0"

export DEFAULT_REPO="podman-io/podman-sandbox"
export RUNNER_LABEL="podman-machine"

export REMOTE_USER="ec2-user"

# --- Logging -----------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- Input validation --------------------------------------------------------
# Anything that gets interpolated into a remote shell command or a launchctl
# label must pass these checks. Reject early; never sanitize-and-continue.

# valid_runner_name <s>
#   Runner name + LaunchDaemon label suffix + instance Name tag. Conservative:
#   letters, digits, dot, underscore, hyphen, 1-64 chars.
valid_runner_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

# valid_repo <s>
#   GitHub <owner>/<repo>. Letters, digits, dot, underscore, hyphen on each side.
valid_repo() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

# valid_label <s>
#   Custom runner label. GitHub's own rules are looser, but we restrict to a
#   shell-safe subset.
valid_label() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

# --- Pre-flight --------------------------------------------------------------

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing required command(s): ${missing[*]}"
    fi
}

# --- AWS helpers -------------------------------------------------------------

# fetch_ssh_key
#   Pulls the shared private key from AWS Secrets Manager to a 0600 tmpfile.
#   Exports KEY_FILE. The caller MUST register cleanup themselves, e.g.:
#       fetch_ssh_key
#       trap cleanup_ssh_key EXIT
#   Cleanup is not done in this function because zsh fires function-scoped
#   EXIT traps on function return (not on shell exit), which would race the
#   caller's SSH attempt.
fetch_ssh_key() {
    require_cmd aws mktemp
    KEY_FILE=$(mktemp -t mac-gha-runner.XXXXXX) || die "mktemp failed"
    chmod 600 "$KEY_FILE"
    aws secretsmanager get-secret-value \
        --secret-id "$SECRET_NAME" \
        --query SecretString --output text > "$KEY_FILE" \
        || die "could not read secret '$SECRET_NAME' (run 00_bootstrap_key.sh first?)"
    chmod 600 "$KEY_FILE"
    export KEY_FILE
}

# cleanup_ssh_key
#   Removes the tmpfile created by fetch_ssh_key. Safe to call multiple times.
cleanup_ssh_key() {
    if [ -n "${KEY_FILE:-}" ]; then
        rm -f "$KEY_FILE"
        unset KEY_FILE
    fi
}

# aws_subnet_for_az <availability-zone>
#   Prints a subnet ID located in the given AZ. Picks the first one returned;
#   adequate when the VPC has one subnet per AZ (the default-VPC case).
aws_subnet_for_az() {
    local az="$1"
    aws ec2 describe-subnets \
        --filters "Name=availability-zone,Values=$az" \
        --query 'Subnets[0].SubnetId' --output text \
        | grep -v '^None$' \
        || die "no subnet found in AZ $az"
}

# --- SSH helpers -------------------------------------------------------------

# ssh_runner <host> <cmd...>
#   Runs a command on the runner host using the fetched key + canonical flags.
#   Requires fetch_ssh_key to have been called first.
ssh_runner() {
    local host="$1"; shift
    [ -n "${KEY_FILE:-}" ] || die "KEY_FILE not set; call fetch_ssh_key first"
    ssh -i "$KEY_FILE" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "${REMOTE_USER}@${host}" "$@"
}

# wait_ssh <host> [timeout_sec]
#   Polls until an SSH handshake succeeds. Default timeout 600s (10 min) —
#   enough for a fresh Mac AMI to finish cloud-init.
wait_ssh() {
    local host="$1"
    local timeout="${2:-600}"
    local deadline=$(( $(date +%s) + timeout ))
    [ -n "${KEY_FILE:-}" ] || die "KEY_FILE not set; call fetch_ssh_key first"
    log "Waiting for SSH on $host (up to ${timeout}s)..."
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh -i "$KEY_FILE" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR \
               -o BatchMode=yes \
               -o ConnectTimeout=5 \
               "${REMOTE_USER}@${host}" 'true' 2>/dev/null; then
            log "SSH ready."
            return 0
        fi
        sleep 10
    done
    die "SSH did not become ready within ${timeout}s"
}

# --- GitHub helpers ----------------------------------------------------------

# gh_registration_token <owner/repo>
#   Mints a fresh runner registration token. Valid ~1 hour.
gh_registration_token() {
    require_cmd gh
    local repo="$1"
    gh api -X POST "repos/${repo}/actions/runners/registration-token" \
        --jq .token \
        || die "could not mint registration token for $repo (gh auth?)"
}

# gh_runner_id_by_name <owner/repo> <runner-name>
#   Prints the numeric runner id for a runner registered with the given name,
#   or empty string if not found.
gh_runner_id_by_name() {
    require_cmd gh
    local repo="$1" name="$2"
    gh api "repos/${repo}/actions/runners" \
        --jq ".runners[] | select(.name==\"$name\") | .id"
}
