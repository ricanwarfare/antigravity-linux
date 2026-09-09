#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh
bash -n docs/install.sh
bash -n scripts/sync-site.sh
bash -n scripts/check.sh
bash -n scripts/verify-units.sh
python3 -m unittest discover -s tests -v
bash scripts/verify-units.sh

echo "All checks passed."
