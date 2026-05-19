# Mac GHA self-hosted runner provisioning scripts

This directory contains the recipe for standing up new EC2 `mac2.metal`
runners that serve the `machine` job in `.github/workflows/mac.yml`. The
`build` job runs on GHA-hosted `macos-15`; only `podman machine` e2e tests
need a self-hosted Mac (Anka-managed runners block nested Hypervisor.framework
access — see `docs/plans/2026-05-19-mac-ci-poc-results.md`).

## Prereqs

On the operator's machine:

- `aws` CLI v2 configured for the AWS account that owns the Mac dedicated hosts
- `gh` CLI authenticated with admin (or maintain) on the target repo
  (`gh auth login --insecure-storage -h github.com -p https -s repo` if the
  macOS Keychain rejects token storage)
- `jq`, `ssh`, `awk`, `mktemp` (all standard)

On AWS:

- A pre-allocated Mac Dedicated Host (`mac2.metal` or `mac1.metal`), state
  `available`, tagged `purpose=github`. These scripts refuse to launch on
  any host that isn't tagged that way — the tag is the safety net against
  accidentally clobbering a host still serving Cirrus.

## One-time bootstrap

```
./00_bootstrap_key.sh
```

Creates an EC2 keypair `mac-gha-runner` (ed25519) and stores the private
material in AWS Secrets Manager as `mac-gha-runner/private-key`. Idempotent
when both already exist; refuses to proceed on a half-bootstrapped state.

Print the public key after creation so it can be appended to existing hosts'
`~ec2-user/.ssh/authorized_keys` while you're migrating off any personal keys.

## Day-to-day: provision a new host

```
./list_hosts.sh                                        # see what's available
./setup_host.sh --host-id h-0813dfdc57f9f4fad --name MacM1-7
```

`setup_host.sh` composes:

1. `provision_host.sh` — launches a fresh `mac2.metal` instance on the host
   using launch template `lt-022eab7d409952e5e` v15 + tag overrides
   (`purpose=github`, `PWPoolReady=false`); waits for SSH to be reachable
   with the shared key.
2. `install_runner.sh` — downloads `actions/runner` v2.334.0, configures
   it against the repo with the `podman-machine` label (auto-adds
   `self-hosted`, `macOS`, `ARM64`), installs a LaunchDaemon (rendered
   from `launchd/com.github.actions.runner.plist.tmpl`), and waits until
   the runner reports `online`.

Each subscript is also usable on its own — e.g. `install_runner.sh
--instance-id <i-...> --name MacM1-6` for re-attaching a runner to an
already-launched instance after a `teardown.sh` without `--terminate-instance`.

## Teardown

```
./teardown.sh --name MacM1-7                  # keep instance alive
./teardown.sh --name MacM1-7 --terminate-instance   # also kill instance
```

Deregisters the runner from GitHub, removes the LaunchDaemon, and removes
`~/actions-runner` on the host. The instance is left running by default
(so a fresh `install_runner.sh` can re-attach without paying another 5–15 min
boot wait).

## Migrating a host that's currently keyed to a personal SSH key

Example: MacM1-6 was originally provisioned with a personal `tizhou-mac-dedicated`
keypair. To switch it onto the shared key without downtime:

```
# 1. Bootstrap (once for the whole org)
./00_bootstrap_key.sh

# 2. Append shared pubkey to the host's authorized_keys, using the personal
#    key one last time
PUB=$(aws ec2 describe-key-pairs --key-names mac-gha-runner \
    --include-public-key --query 'KeyPairs[0].PublicKey' --output text)
ssh -i ~/.ssh/tizhou-mac-dedicated.pem ec2-user@<host-ip> \
    "echo '$PUB' >> ~/.ssh/authorized_keys"

# 3. Confirm shared key works
source ./lib.sh
fetch_ssh_key
trap cleanup_ssh_key EXIT     # zsh fires function-scoped EXIT traps on
                              # function return, so cleanup is caller-owned
ssh_runner <host-ip> 'whoami'

# 4. Eventually deprecate the personal key:
#    - Remove its pubkey line from authorized_keys
#    - aws ec2 delete-key-pair --key-name tizhou-mac-dedicated
#    - rm ~/.ssh/tizhou-mac-dedicated.pem
```

## Required IAM permissions

For `00_bootstrap_key.sh` (one-time, run by the first operator):

- `ec2:CreateKeyPair`, `ec2:DescribeKeyPairs`
- `secretsmanager:CreateSecret`, `secretsmanager:DescribeSecret`,
  `secretsmanager:TagResource`

For everyone running `setup_host.sh` / `install_runner.sh` / `teardown.sh`:

- `ec2:DescribeHosts`, `ec2:DescribeSubnets`, `ec2:DescribeInstances`,
  `ec2:RunInstances`, `ec2:CreateTags`
- `ec2:TerminateInstances` (only if using `teardown.sh --terminate-instance`)
- `secretsmanager:GetSecretValue` on `mac-gha-runner/private-key`

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `wait_ssh` times out after 10 min | Security group missing inbound 22, or instance still booting | `aws ec2 describe-instance-status --instance-ids <id>`; security group needs SSH from your IP |
| `gh_registration_token` fails with TLS error | Sandboxed Keychain rejecting the cert chain | `gh auth login --insecure-storage -h github.com -p https -s repo` then retry |
| Runner stuck `offline` after install | LaunchDaemon couldn't start `run.sh` | `ssh ... 'sudo tail -50 ~/actions-runner/runner.err.log'` |
| `provision_host.sh` refuses with "not tagged purpose=github" | Safety check — host is in Cirrus prod pool | Tag the host `purpose=github` and `PWPoolReady=true` (so the existing PW pool script also skips it), or pick a different host |
| `00_bootstrap_key.sh` errors "keypair exists but secret missing" | Someone created the keypair without storing the secret | Cannot recover; delete the keypair and re-run |

## What these scripts deliberately do NOT do

- Bake an AMI (the base Amazon macOS AMI in the launch template is sufficient)
- Install Homebrew / vfkit / krunkit on the host (the workflow installs them
  from the `.pkg` artifact every run and signs them at CI time — see
  `docs/plans/2026-05-19-mac-ci-poc-results.md` for why)
- Batch-migrate the fleet (`apply_to_fleet.sh`) — rollout is intentionally
  one-host-at-a-time during the parallel-run period
- Touch the Cirrus per-task scripts in `contrib/cirrus/mac_*.sh`
- Provision a LaunchAgent variant for GUI-required Mac workloads — none of
  the current CI workloads need an Aqua session

## Files

| File | Purpose |
|---|---|
| `lib.sh` | Shared bash helpers + constants (sourced) |
| `00_bootstrap_key.sh` | One-time keypair + secret creation |
| `list_hosts.sh` | Read-only discovery of `purpose=github` hosts |
| `provision_host.sh` | Launch + SSH-ready wait |
| `install_runner.sh` | Configure GHA runner + LaunchDaemon |
| `setup_host.sh` | Wrapper around provision + install |
| `teardown.sh` | Deregister + uninstall (instance termination optional) |
| `launchd/com.github.actions.runner.plist.tmpl` | LaunchDaemon plist template (`__RUNNER_NAME__` placeholder) |
