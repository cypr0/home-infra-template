#!/usr/bin/env bash
# Renders all *.yaml files in a directory via envsubst and applies them.
#
# Usage:
#   ./scripts/apply.sh <directory>            # kubectl apply
#   ./scripts/apply.sh <directory> --dry-run  # render only, do not apply
#   ./scripts/apply.sh <directory> --render   # print rendered YAML
#
# Prerequisite: .env must exist in the repo root (cp .env.template .env)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?Usage: $0 <directory> [--dry-run|--render]}"
MODE="${2:-apply}"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "Error: .env not found. Run 'cp .env.template .env' first." >&2
  exit 1
fi

set -a
source "$REPO_ROOT/.env"
set +a

shopt -s nullglob
YAML_FILES=("$TARGET"/*.yaml)

if [[ ${#YAML_FILES[@]} -eq 0 ]]; then
  echo "No *.yaml files found in $TARGET." >&2
  exit 1
fi

for f in "${YAML_FILES[@]}"; do
  case "$MODE" in
    --render)
      echo "--- # $f"
      envsubst < "$f"
      ;;
    --dry-run)
      echo "Dry-run: $f"
      envsubst < "$f" | kubectl apply --dry-run=client -f -
      ;;
    apply)
      echo "Apply: $f"
      envsubst < "$f" | kubectl apply -f -
      ;;
    *)
      echo "Unknown mode: $MODE" >&2
      exit 1
      ;;
  esac
done
