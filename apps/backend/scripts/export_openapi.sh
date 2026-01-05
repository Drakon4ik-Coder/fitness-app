#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUTPUT_PATH="${OUTPUT_PATH:-$ROOT_DIR/contracts/openapi.yaml}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

poetry run python manage.py spectacular --file "$OUTPUT_PATH"
