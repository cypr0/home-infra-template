#!/usr/bin/env bash
# Renders bootstrap/mgmt-talos-patch.yaml with values from .env.
# Usage: ./scripts/render-mgmt-patch.sh
# Output: /tmp/mgmt-patch.yaml
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "Error: .env not found. Run 'cp .env.template .env' first." >&2
  exit 1
fi

set -a
source "$REPO_ROOT/.env"
set +a

envsubst < "$REPO_ROOT/bootstrap/mgmt-talos-patch.yaml" > /tmp/mgmt-patch.yaml
echo "Rendered to /tmp/mgmt-patch.yaml"
cat /tmp/mgmt-patch.yaml
