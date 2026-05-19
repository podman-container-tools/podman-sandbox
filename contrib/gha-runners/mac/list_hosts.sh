#!/usr/bin/env bash
# Discovery helper: pretty-print Mac dedicated hosts tagged purpose=github.
# No mutations. Use this before deciding which host to migrate next.
#
# Required IAM: ec2:DescribeHosts

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd aws

# JMESPath expression: backticks are literal-value syntax, NOT shell substitution.
# shellcheck disable=SC2016
aws ec2 describe-hosts \
    --filter "Name=tag:purpose,Values=github" \
    --query 'Hosts[] | sort_by(@, &Tags[?Key==`Name`]|[0].Value || `~`) | [].{
        HostId:    HostId,
        Name:      Tags[?Key==`Name`]|[0].Value,
        State:     State,
        AZ:        AvailabilityZone,
        InstType:  HostProperties.InstanceType,
        Running:   length(Instances),
        Allocated: AllocationTime
    }' \
    --output table
