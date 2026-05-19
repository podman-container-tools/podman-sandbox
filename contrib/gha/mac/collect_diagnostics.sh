#!/usr/bin/env bash
# Collect diagnostic logs on machine-test failure. Best-effort — the
# podman/machine state dir is usually nuked by ginkgo's DeferCleanup before
# this runs, so we also pull macOS unified log entries for vfkit/krunkit.
# Outputs go to CWD as machine-*.log and macos-system-log.log.

set +e

find /private/tmp -path '*/podman/machine/*' -type f \
    \( -name '*.log' -o -name 'vfkit*' -o -name 'krunkit*' \) 2>/dev/null \
  | while IFS= read -r src; do
      cp "$src" "./machine-$(echo "$src" | tr '/' '_').log" 2>/dev/null
    done

# shellcheck disable=SC2024  # redirect target is ec2-user-owned; sudo only
# needs to elevate `log show`, not the file write.
sudo log show \
    --predicate 'process == "vfkit" OR process == "krunkit" OR senderImagePath CONTAINS "Hypervisor" OR senderImagePath CONTAINS "Virtualization"' \
    --last 30m --style compact \
    > ./macos-system-log.log 2>&1

true
