#!/usr/bin/env bash
# Best-effort cleanup of podman machine state and leaked test processes.

set +e

pkill -f vfkit   2>/dev/null || true
pkill -f krunkit 2>/dev/null || true
pkill -f gvproxy 2>/dev/null || true
pkill -f ginkgo  2>/dev/null || true

rm -rf "$HOME/.local/share/containers/podman/machine" 2>/dev/null || true
rm -rf "$HOME/.config/containers/podman"               2>/dev/null || true
rm -rf "${TMPDIR:-/private/tmp}/podman"                2>/dev/null || true

true
