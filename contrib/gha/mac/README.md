# GHA Mac workflow scripts

Per-task scripts called from `.github/workflows/mac.yml jobs.machine`.
Mirrors the per-task split that `contrib/cirrus/mac_*.sh` uses for the
Cirrus persistent-worker model: no `sudo`, no `.pkg` install at test time.
Helper binaries (vfkit, krunkit, gvproxy) are installed once at host setup
via Homebrew and live at `/opt/homebrew/bin/`. Podman is built in-job at
`$GITHUB_WORKSPACE/bin/darwin/podman` and tests are driven by
`make localmachine`.

| Script | When | Purpose |
|---|---|---|
| `clean_state.sh` | Pre + post machine job | Best-effort cleanup of podman machine state, stale Unix sockets, and any leaked vfkit/krunkit/gvproxy/ginkgo processes. Idempotent, no sudo. |
| `collect_diagnostics.sh` | On `if: failure()` | Pull podman/machine logs and the macOS unified log entries for vfkit/krunkit on failure. Writes to CWD as `machine-*.log` and `macos-system-log.log`. |

## Host-side dependencies (one-time per runner)

The machine job assumes the runner has these on `/opt/homebrew/bin/`,
installed by Homebrew at host provisioning time. Brew bottles ship signed
with the right entitlements, so no codesign step is needed at CI time.

| Binary | Source | Version reference |
|---|---|---|
| `vfkit` | `brew install vfkit` (Homebrew core) | `contrib/pkginstaller/Makefile` `VFKIT_VERSION` |
| `krunkit` | `brew tap slp/krunkit && brew install krunkit` | `contrib/pkginstaller/Makefile` `KRUNKIT_VERSION` |
| `gvproxy` | direct download from `containers/gvisor-tap-vsock` releases; chmod +x; `xattr -cr` | `go.mod` `github.com/containers/gvisor-tap-vsock` version |

Provisioning these is owned by the host-setup scripts on the
`ci/mac-host-provisioning` branch.
