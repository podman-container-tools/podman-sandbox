#!/usr/bin/env bash
# Wipe podman machine state on the self-hosted Mac runner. Runs both before
# a job (in case the previous run left things behind) and after (so the next
# run starts pristine). Idempotent, best-effort, never fails the job over a
# cleanup miss. No sudo, no /opt/podman — everything is in user space.
# Mirrors contrib/cirrus/mac_cleanup.sh.

set +e

# Kill any leaked test processes from a previous run.
pkill -f vfkit   2>/dev/null || true
pkill -f krunkit 2>/dev/null || true
pkill -f gvproxy 2>/dev/null || true
pkill -f ginkgo  2>/dev/null || true

# Remove machine state under $HOME (no sudo).
rm -rf "$HOME/.local/share/containers/podman/machine" 2>/dev/null || true
rm -rf "$HOME/.config/containers/podman"               2>/dev/null || true

# Stale Unix sockets under TMPDIR (set to /private/tmp at workflow env).
rm -rf "${TMPDIR:-/private/tmp}/podman" 2>/dev/null || true

true
