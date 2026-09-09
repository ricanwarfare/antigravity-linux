#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Validate the real units in a disposable filesystem root. A clean CI runner
# must not need the helper installed at /usr/local/lib to pass verification.
VERIFY_ROOT=$(mktemp -d)
trap 'rm -rf -- "$VERIFY_ROOT"' EXIT
install -Dm0755 "$ROOT_DIR/install.sh" "$VERIFY_ROOT/usr/local/lib/antigravity-linux/install.sh"
install -d "$VERIFY_ROOT/etc/systemd/system"
for unit in "$ROOT_DIR"/systemd/*; do
  install -m0644 "$unit" "$VERIFY_ROOT/etc/systemd/system/"
done
for target in sysinit basic shutdown timers network-online; do
  printf '[Unit]\nDescription=Verification fixture\nDefaultDependencies=no\n' > "$VERIFY_ROOT/etc/systemd/system/$target.target"
done
systemd-analyze verify --root="$VERIFY_ROOT" --generators=no \
  /etc/systemd/system/antigravity-linux-update.service \
  /etc/systemd/system/antigravity-linux-update.timer
