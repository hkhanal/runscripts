#!/usr/bin/env bash
set -euo pipefail

# Directory of this script (so we can call the other two reliably)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optionally load shared config once here too
CONF_FILE="${CONF_FILE:-$HOME/openedx-restore.conf}"
if [[ -f "${CONF_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONF_FILE}"
fi

MYSQL_SCRIPT="${SCRIPT_DIR}/restore_mysql.sh"
MONGO_SCRIPT="${SCRIPT_DIR}/restore_mongodb.sh"   # rename if your file name differs

if [[ ! -x "${MYSQL_SCRIPT}" ]]; then
  echo "MySQL restore script not found or not executable: ${MYSQL_SCRIPT}" >&2
  exit 1
fi

if [[ ! -x "${MONGO_SCRIPT}" ]]; then
  echo "Mongo restore script not found or not executable: ${MONGO_SCRIPT}" >&2
  exit 1
fi

echo "=============================="
echo " Open edX DB Restore Launcher"
echo "=============================="
echo

echo "[1/2] Restoring MySQL (devdb)…"
"${MYSQL_SCRIPT}" "$@"

echo
echo "[2/2] Restoring MongoDB (Tutor mongodb)…"
"${MONGO_SCRIPT}" "$@"

echo
echo "[✓] Both MySQL and MongoDB restores completed."
