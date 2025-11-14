#!/usr/bin/env bash
# Open edX backup: MySQL + Mongo (Tutor) + S3 upload
# - MySQL: mysqldump (supports --defaults-extra-file)
# - Mongo: tutor local exec/run + stream archive to host (NO writes in container)
# - S3: uploads tarball + .sha256 to S3 (AWS CLI)
# Cron-safe: explicit PATH; no interactive prompts

set -euo pipefail

########################################
# Load environment (edit this file)
########################################
ENV_FILE="${ENV_FILE:-/home/ubuntu/.mylcafe-backup.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
########################################
# Defaults (override in ENV_FILE)
########################################

# Local backup root (timestamped folder inside)
BACKUP_ROOT="${BACKUP_ROOT:-/home/ubuntu/data_backup}"

# Stop LMS/CMS/workers during backup? (safer but brief downtime)
STOP_SERVICES="${STOP_SERVICES:-true}"

# MySQL
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-openedx}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASES="${MYSQL_DATABASES:-openedx}"
# Safer: avoid password-in-ps by using a client file
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-}"

# Mongo (auth optional; dump runs *inside* mongodb container)
MONGO_HOST="${MONGO_HOST:-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"
MONGO_AUTH_DB="${MONGO_AUTH_DB:-admin}"
MONGO_USE_OPLOG="${MONGO_USE_OPLOG:-false}"

# Tutor binary (explicit path = cron-safe)
TUTOR_BIN="${TUTOR_BIN:-/home/ubuntu/.local/bin/tutor}"

# Docker Compose args (used by Tutor’s project)
COMPOSE_A="-f /home/ubuntu/.local/share/tutor/env/local/docker-compose.yml"
COMPOSE_B="-f /home/ubuntu/.local/share/tutor/env/local/docker-compose.prod.yml"
COMPOSE_P="--project-name tutor_local"

# ---------- S3 Upload ----------
# Set S3_BUCKET to enable upload, e.g. s3://my-bucket/edx-backups
S3_BUCKET="${S3_BUCKET:-}"                 # REQUIRED to upload
S3_PREFIX="${S3_PREFIX:-}"                 # optional, e.g. "daily"
BACKUP_HOST_TAG="${BACKUP_HOST_TAG:-$(hostname -s)}"  # helps organize by host
AWS_PROFILE="${AWS_PROFILE:-}"             # optional
AWS_REGION="${AWS_REGION:-}"               # optional
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-}"   # optional (MinIO, etc.)
S3_STORAGE_CLASS="${S3_STORAGE_CLASS:-}"   # e.g. STANDARD_IA, GLACIER (lifecycle recommended for Glacier)
S3_SSE="${S3_SSE:-}"                       # e.g. AES256 or aws:kms
S3_SSE_KMS_KEY_ID="${S3_SSE_KMS_KEY_ID:-}" # if using KMS
S3_DELETE_LOCAL_AFTER_UPLOAD="${S3_DELETE_LOCAL_AFTER_UPLOAD:-false}"  # rarely true

########################################
# PATH (cron-safe) and helpers
########################################
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/ubuntu/.local/bin:/home/ubuntu/venv/bin"

log() { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
tutor_cmd() { "$TUTOR_BIN" "$@"; }

########################################
# Pre-flight checks
########################################
require_cmd bash
require_cmd date
require_cmd gzip
require_cmd sha256sum
require_cmd tar
require_cmd docker
[[ -x "$TUTOR_BIN" ]] || die "Tutor CLI not found at $TUTOR_BIN (set TUTOR_BIN or install Tutor)."

# MySQL dumper
if command -v mysqldump >/dev/null 2>&1; then
  MYSQLDUMP_BIN="mysqldump"
elif command -v mariadb-dump >/dev/null 2>&1; then
  MYSQLDUMP_BIN="mariadb-dump"
else
  die "mysqldump (or mariadb-dump) not found."
fi

# AWS CLI only required if S3_BUCKET is set
if [[ -n "${S3_BUCKET}" ]]; then
  require_cmd aws
fi

########################################
# Timestamp, working dir, logs
########################################
TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="${BACKUP_ROOT}/${TS}"
mkdir -p "$WORKDIR"
LOGDIR="${BACKUP_ROOT}/logs"; mkdir -p "$LOGDIR"

########################################
# Service stop/start with trap
########################################
STOPPED=0
restore_services() {
  if (( STOPPED == 1 )) && [[ "$STOP_SERVICES" == "true" ]]; then
    log "Starting LMS/CMS + workers (trap)…"
    if "$TUTOR_BIN" --version >/dev/null 2>&1; then
      tutor_cmd local start -d lms cms lms-worker cms-worker || true
    else
      docker compose $COMPOSE_A $COMPOSE_B $COMPOSE_P start lms cms lms-worker cms-worker || true
    fi
  fi
}
trap restore_services EXIT

########################################
# Functions
########################################
mysql_dump() {
  log "Dumping MySQL…"
  local out_sql="${WORKDIR}/mysql.sql"
  local out_gz="${out_sql}.gz"

  if [[ -n "${MYSQL_DEFAULTS_FILE}" && -f "${MYSQL_DEFAULTS_FILE}" ]]; then
    ${MYSQLDUMP_BIN} \
      --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" \
      --single-transaction --routines --triggers --events \
      --databases ${MYSQL_DATABASES} > "${out_sql}"
  else
    ${MYSQLDUMP_BIN} \
      -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
      -u "${MYSQL_USER}" ${MYSQL_PASSWORD:+-p"${MYSQL_PASSWORD}"} \
      --single-transaction --routines --triggers --events \
      --databases ${MYSQL_DATABASES} > "${out_sql}"
  fi

  gzip -f "${out_sql}"
  log "MySQL dump: ${out_gz}"
}

mongo_dump_exec() {
  log "Dumping MongoDB inside container → copy to host (no stdout piping)…"

  local host="${MONGO_HOST:-mongodb}"
  local port="${MONGO_PORT:-27017}"

  local auth_flags=()
  if [[ -n "${MONGO_USER}" && -n "${MONGO_PASSWORD}" ]]; then
    auth_flags+=( --username="${MONGO_USER}" --password="${MONGO_PASSWORD}" --authenticationDatabase="${MONGO_AUTH_DB:-admin}" )
  fi
  [[ "${MONGO_USE_OPLOG:-false}" == "true" ]] && auth_flags+=( --oplog )

  local out_arc="${WORKDIR}/mongodb.archive.gz"                   # final file on host
  local err_log="${BACKUP_ROOT}/logs/mongodump_${TS}.stderr.log"  # stderr from in-container run
  mkdir -p "$(dirname "$err_log")"

  # Pick the right "no TTY" flag for your Tutor version (same logic as before)
  local NO_TTY_FLAG=""
  if "$TUTOR_BIN" local exec --help 2>&1 | grep -q -- '-T'; then
    NO_TTY_FLAG="-T"
  elif "$TUTOR_BIN" local exec --help 2>&1 | grep -q -- '--no-tty'; then
    NO_TTY_FLAG="--no-tty"
  fi

  # 1) Create a world-writable scratch dir *inside* the mongodb container; dump archive there
  #    No user switching; no stdout piping → avoids corrupt headers.
  "$TUTOR_BIN" local exec ${NO_TTY_FLAG} mongodb bash -lc '
    set -euo pipefail
    OUT_DIR=/var/tmp/dumps
    OUT="$OUT_DIR/mongodb.archive.gz"
    install -d -m 0777 "$OUT_DIR"
    rm -f "$OUT" 2>/dev/null || true
    mongodump --host '"${host}"' --port '"${port}"' '"${auth_flags[*]}"' --archive="$OUT" --gzip
    ls -lh "$OUT"
  ' 2>>"$err_log"

  # 2) Copy the archive to the host
  local cid
  cid=$(docker compose $COMPOSE_A $COMPOSE_B $COMPOSE_P ps -q mongodb)
  [[ -n "$cid" ]] || die "Could not determine mongodb container id."
  docker cp "$cid:/var/tmp/dumps/mongodb.archive.gz" "$out_arc"

  # 3) Validate the gzip on host (fail fast if broken)
  if ! gzip -t "$out_arc"; then
    die "Mongo dump produced a non-gzip file at ${out_arc}; see $(basename "$err_log")"
  fi

  log "Mongo dump: ${out_arc}  (stderr → $(basename "$err_log"))"
}


package_and_hash() {
  local tarball="${BACKUP_ROOT}/${TS}.tar.gz"
  log "Packaging ${WORKDIR} → ${tarball}"
  tar -C "${BACKUP_ROOT}" -czf "${tarball}" "${TS}"
  sha256sum "${tarball}" > "${tarball}.sha256"
  log "SHA256: ${tarball}.sha256"
  echo "${tarball}"
}

s3_upload() {
  local tarball="$1"
  local checksum="${tarball}.sha256"

  if [[ -z "${S3_BUCKET}" ]]; then
    log "S3_BUCKET not set — skipping S3 upload."
    return 0
  fi

  local AWS_OPTS=()
  [[ -n "${AWS_PROFILE}" ]]        && AWS_OPTS+=( --profile "${AWS_PROFILE}" )
  [[ -n "${AWS_REGION}" ]]         && AWS_OPTS+=( --region "${AWS_REGION}" )
  [[ -n "${AWS_ENDPOINT_URL}" ]]   && AWS_OPTS+=( --endpoint-url "${AWS_ENDPOINT_URL}" )
  [[ -n "${S3_STORAGE_CLASS}" ]]   && AWS_OPTS+=( --storage-class "${S3_STORAGE_CLASS}" )
  if [[ -n "${S3_SSE}" ]]; then
    AWS_OPTS+=( --sse "${S3_SSE}" )
    if [[ "${S3_SSE}" == "aws:kms" && -n "${S3_SSE_KMS_KEY_ID}" ]]; then
      AWS_OPTS+=( --sse-kms-key-id "${S3_SSE_KMS_KEY_ID}" )
    fi
  fi

  # s3://dagdata/dbbackup/mylcafedb/<host>/<ts>/
  local base="${S3_BUCKET%/}"
  [[ -n "${S3_PREFIX}" ]] && base="${base}/$(echo "${S3_PREFIX}" | sed 's#^/*##;s#/*$##')"
  local dest="${base}/${TS}"

  log "Uploading to ${dest}/ …"
  set +e
  aws s3 cp "${tarball}"  "${dest}/$(basename "${tarball}")"  --only-show-errors "${AWS_OPTS[@]}"; rc1=$?
  aws s3 cp "${checksum}" "${dest}/$(basename "${checksum}")" --only-show-errors "${AWS_OPTS[@]}"; rc2=$?
  set -e

  if (( rc1 != 0 || rc2 != 0 )); then
    log "WARNING: S3 upload failed (tar rc=${rc1}, sha rc=${rc2}). Check IAM & bucket/prefix."
    return 1
  fi

  log "S3 upload complete."
  if [[ "${S3_DELETE_LOCAL_AFTER_UPLOAD}" == "true" ]]; then
    log "Deleting local artifacts after upload (per config)…"
    rm -rf -- "${WORKDIR}" "${tarball}" "${checksum}" || true
  fi
}

########################################
# Main
########################################
log "Backup start → ${WORKDIR}"

if [[ "$STOP_SERVICES" == "true" ]]; then
  log "Stopping LMS/CMS + workers…"
  tutor_cmd local stop lms cms lms-worker cms-worker || true
  STOPPED=1
fi

mysql_dump
mongo_dump_exec

if (( STOPPED == 1 )) && [[ "$STOP_SERVICES" == "true" ]]; then
  log "Starting LMS/CMS + workers…"
  tutor_cmd local start -d lms cms lms-worker cms-worker || true
  STOPPED=0
fi

package_and_hash
tarball_path="${BACKUP_ROOT}/${TS}.tar.gz"
s3_upload "${tarball_path}"

log "Backup complete ✔"
