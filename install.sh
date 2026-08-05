#!/bin/bash
# Installs/updates the CEC daemon. Run as root (or via sudo) on the box
# with the CEC adapter (e.g. a Framework HDMI Expansion Card at /dev/cec0).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo ./install.sh)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 755 "$SCRIPT_DIR/cec-daemon.sh" /usr/local/bin/cec-daemon.sh
install -m 644 "$SCRIPT_DIR/cec-daemon.service" /etc/systemd/system/cec-daemon.service

systemctl daemon-reload
systemctl enable --now cec-daemon.service

echo "Installed. Check status with: systemctl status cec-daemon.service"
echo "Watch logs with: journalctl -t cec-daemon -f"
