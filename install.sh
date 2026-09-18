#!/usr/bin/env bash
# Install the AmneziaBackup scripts and create the protected storage layout.
set -Eeuo pipefail
umask 077

BASE_DIR=/opt/AmneziaBackup
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if (( EUID != 0 )); then
  echo "ERROR: run as root (for example: sudo $0)" >&2
  exit 1
fi

install -d -m 700 "$BASE_DIR" "$BASE_DIR/backups" "$BASE_DIR/logs"
install -m 700 "$SOURCE_DIR/backup.sh" "$BASE_DIR/backup.sh"
install -m 700 "$SOURCE_DIR/restore.sh" "$BASE_DIR/restore.sh"
chmod 700 "$BASE_DIR" "$BASE_DIR/backups" "$BASE_DIR/logs" "$BASE_DIR/backup.sh" "$BASE_DIR/restore.sh"
echo "Installed to $BASE_DIR"
