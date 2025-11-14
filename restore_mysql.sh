#!/usr/bin/env bash
set -euo pipefail

### =========================
### CONFIG (override via env)
### =========================

# Load shared config if present
CONF_FILE="${CONF_FILE:-$HOME/openedx-restore.conf}"
if [[ -f "${CONF_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONF_FILE}"
fi

S3_BUCKET="${S3_BUCKET:-s3://dagdata/dbbackup/mylcafedb}"
DB_HOST="${DB_HOST:-devdb.daglearning.com}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_NAME="${DB_NAME:-}"              # optional: force import into a specific DB (see IMPORT_MODE=one_db)
IMPORT_MODE="${IMPORT_MODE:-auto}"  # auto|one_db
WORKDIR="${WORKDIR:-$HOME/mysql-restore}"
ASK_PASSWORD="${ASK_PASSWORD:-true}"  # true|false; if false, use MYSQL_PWD env var
PARALLEL_GZIP="${PARALLEL_GZIP:-false}" # true|false; uses pigz if available

### =========================
### USAGE / ARGS
### =========================
usage() {
  cat <<EOF
Usage: $(basename "$0") [--ts TIMESTAMP] [--list] [--dry-run]

Options:
  --ts TIMESTAMP   Restore this backup (e.g., 20251108T184125Z). If omitted, the latest is used.
  --list           List available backup timestamps and exit.
  --dry-run        Don’t import; just show what would happen.
  -h, --help       Show this help.

Environment overrides:
  S3_BUCKET     (default: ${S3_BUCKET})
  DB_HOST       (default: ${DB_HOST})
  DB_PORT       (default: ${DB_PORT})
  DB_USER       (default: ${DB_USER})
  DB_NAME       (default: empty)
  IMPORT_MODE   (auto|one_db; default: auto)
  WORKDIR       (default: ${WORKDIR})
  ASK_PASSWORD  (true|false; default: true)
  PARALLEL_GZIP (true|false; default: false)

Notes:
- In IMPORT_MODE=auto, the SQL file's own CREATE DATABASE / USE statements are honored.
- In IMPORT_MODE=one_db, the dump is piped into a single DB named by DB_NAME (it will be created if missing).
EOF
}

LIST_ONLY=false
DRY_RUN=false
TS="${TS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ts)       TS="$2"; shift 2;;
    --list)     LIST_ONLY=true; shift;;
    --dry-run)  DRY_RUN=true; shift;;
    -h|--help)  usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

### =========================
### DEP CHECKS
### =========================
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need aws
need mysql
need sha256sum
need tar

GZIP="gunzip -c"
if [[ "${PARALLEL_GZIP}" == "true" ]] && command -v pigz >/dev/null 2>&1; then
  GZIP="pigz -dc"
fi

mkdir -p "${WORKDIR}"

### =========================
### PICK TIMESTAMP
### =========================
list_timestamps() {
  # List prefixes one level below bucket root (timestamps)
  aws s3 ls "${S3_BUCKET}/" | awk '{print $2}' | sed 's#/##' | sed '/^$/d' | sort
}

if $LIST_ONLY; then
  echo "Available timestamps under ${S3_BUCKET}/:"
  list_timestamps
  exit 0
fi

if [[ -z "${TS}" ]]; then
  # Choose latest by lexicographic order (TS format is sortable)
  TS="$(list_timestamps | tail -n 1)"
  if [[ -z "${TS}" ]]; then
    echo "No backups found under ${S3_BUCKET}/" >&2
    exit 1
  fi
fi

DEST_DIR="${WORKDIR}/${TS}"
mkdir -p "${DEST_DIR}"
echo "[*] Using timestamp: ${TS}"
echo "[*] Workdir: ${DEST_DIR}"

### =========================
### DOWNLOAD & VERIFY
### =========================
TAR="${TS}.tar.gz"
SHA="${TS}.tar.gz.sha256"
S3_PREFIX="${S3_BUCKET}/${TS}"

if [[ ! -f "${DEST_DIR}/${TAR}" ]]; then
  echo "[*] Downloading ${TAR} …"
  aws s3 cp "${S3_PREFIX}/${TAR}" "${DEST_DIR}/${TAR}"
else
  echo "[*] Found existing ${DEST_DIR}/${TAR} (skipping download)"
fi

if [[ ! -f "${DEST_DIR}/${SHA}" ]]; then
  echo "[*] Downloading ${SHA} …"
  aws s3 cp "${S3_PREFIX}/${SHA}" "${DEST_DIR}/${SHA}"
else
  echo "[*] Found existing ${DEST_DIR}/${SHA} (skipping download)"
fi

echo "[*] Verifying checksum …"

EXPECTED_HASH="$(cut -d' ' -f1 "${DEST_DIR}/${SHA}")"
echo "${EXPECTED_HASH}  ${DEST_DIR}/${TAR}" | sha256sum -c -

echo "[*] Inspecting tarball layout …"
# Find mysql.sql.gz no matter where it sits inside the tar
SQL_IN_TAR="$(tar -tzf "${DEST_DIR}/${TAR}" | grep -E '(^|/)(mysql\.sql\.gz)$' | head -n1 || true)"
if [[ -z "${SQL_IN_TAR}" ]]; then
  echo "Could not find mysql.sql.gz inside ${TAR}" >&2
  echo "First 50 entries for debugging:" >&2
  tar -tzf "${DEST_DIR}/${TAR}" | head -n 50 >&2
  exit 1
fi
echo "[*] Found: ${SQL_IN_TAR}"
echo "[*] Extracting ${SQL_IN_TAR} …"
tar -xzf "${DEST_DIR}/${TAR}" -C "${DEST_DIR}" "${SQL_IN_TAR}"

# Normalize to ${DEST_DIR}/mysql.sql.gz
if [[ "${SQL_IN_TAR}" != "mysql.sql.gz" ]]; then
  cp -f "${DEST_DIR}/${SQL_IN_TAR}" "${DEST_DIR}/mysql.sql.gz"
  # optional cleanup of the extracted subfolder
  SUBDIR="$(dirname "${SQL_IN_TAR}")"
  [[ "${SUBDIR}" != "." ]] && rm -rf "${DEST_DIR}/${SUBDIR}" || true
fi

SQL_GZ="${DEST_DIR}/mysql.sql.gz"
[[ -f "${SQL_GZ}" ]] || { echo "Extraction failed: ${SQL_GZ} missing" >&2; exit 1; }

### =========================
### PREPARE MYSQL AUTH
### =========================
PASS_ARG=()
if [[ "${ASK_PASSWORD}" == "true" ]]; then
  # Prompt safely
  read -r -s -p "Enter MySQL password for user ${DB_USER}@${DB_HOST}: " MYSQL_PWD_INPUT
  echo
  export MYSQL_PWD="${MYSQL_PWD_INPUT}"
  PASS_ARG=()  # mysql client will read from MYSQL_PWD
else
  # Expect MYSQL_PWD already set in env (or rely on ~/.my.cnf)
  :
fi

### =========================
### DRY RUN INFO
### =========================
echo "[*] Ready to import into MySQL at ${DB_HOST}:${DB_PORT} as ${DB_USER}"
if $DRY_RUN; then
  echo "[DRY-RUN] Would execute one of the following imports:"
  if [[ "${IMPORT_MODE}" == "one_db" ]]; then
    echo "  ${GZIP} ${SQL_GZ} | mysql -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_NAME}"
  else
    echo "  ${GZIP} ${SQL_GZ} | mysql -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER}"
  fi
  exit 0
fi

### =========================
### IMPORT
### =========================
echo "[*] Starting import … (this can take a while)"

if [[ "${IMPORT_MODE}" == "one_db" ]]; then
  if [[ -z "${DB_NAME}" ]]; then
    echo "IMPORT_MODE=one_db requires DB_NAME to be set" >&2
    exit 1
  fi
  # Create DB if needed, then import strictly into that DB
  mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" "${PASS_ARG[@]}" \
    -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  ${GZIP} "${SQL_GZ}" | mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" "${PASS_ARG[@]}" "${DB_NAME}"
else
  # auto: honor whatever databases are in the dump
  ${GZIP} "${SQL_GZ}" | mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" "${PASS_ARG[@]}"
fi

echo "[✓] MySQL restore complete."

### =========================
### POST-CHECK (optional but handy)
### =========================
echo "[*] Listing databases (post-restore):"
mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" "${PASS_ARG[@]}" -e "SHOW DATABASES;"