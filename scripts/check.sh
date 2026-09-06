#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash -n install.sh
bash -n docs/install.sh
bash -n scripts/sync-site.sh

if ! cmp -s install.sh docs/install.sh; then
  echo "docs/install.sh is out of sync. Run: bash scripts/sync-site.sh" >&2
  exit 1
fi

bash install.sh --status >/dev/null
systemd-analyze verify systemd/antigravity-linux-update.service systemd/antigravity-linux-update.timer

if ! grep -q '/usr/local/lib/antigravity-linux/install.sh' install.sh; then
  echo "install.sh must install and use a local update helper." >&2
  exit 1
fi

if ! grep -q 'antigravity-linux-update.timer' install.sh; then
  echo "install.sh must install the systemd update timer." >&2
  exit 1
fi

if ! grep -q '/opt/antigravity.new' install.sh || ! grep -q '/opt/antigravity-ide.new' install.sh; then
  echo "install.sh uninstall must remove interrupted .new staging directories." >&2
  exit 1
fi

echo "All checks passed."
