#!/bin/bash
# entrypoint.sh — IT-Stack iredmail container entrypoint
set -euo pipefail

echo "Starting IT-Stack IREDMAIL (Module 09)..."

# Source any environment overrides
if [ -f /opt/it-stack/iredmail/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/iredmail/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
