#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$ROOT_DIR/install.sh" "$ROOT_DIR/docs/install.sh"
chmod +x "$ROOT_DIR/docs/install.sh"
python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
body = (root / 'README.md').read_text().split('A community installer and updater', 1)[1]
(root / 'docs/llms.txt').write_text('# Antigravity Linux Installer\n\nA community installer and updater' + body)
PY
