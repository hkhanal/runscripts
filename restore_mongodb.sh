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


### =========================
### CONFIG (override via env)
### =========================
S3_BUCKET="${S3_BUCKET:-s3://dagdata/dbbackup/mylcafedb}"
WORKDIR="${WORKDIR:-$HOME/mongo-restore}"

MAP_FROM="${MAP_FROM:-}"
MAP_TO="${MAP_TO:-}"

DROP_BEFORE_RESTORE="${DROP_BEFORE_RESTORE:-true}"   # true|false
TUTOR_BIN="${TUTOR_BIN:-tutor}"

# New: which namespace(s) to include by default
MONGO_NS_INCLUDE="${MONGO_NS_INCLUDE:-openedx.*}"

### =========================
### USAGE / ARGS
### =========================
usage() {
  cat <<EOF
Usage: $(basename "$0") [--ts TIMESTAMP] [--list] [--dry-run]

Options:
  --ts TIMESTAMP   Restore this backup (e.g., 20251108T184125Z). If omitted, the latest is used.
  --list           List available backup timestamps and exit.
  --dry-run        Don't restore; just show what would happen.
  -h, --help       Show help.

Env overrides:
  S3_BUCKET            (default: ${S3_BUCKET})
  WORKDIR              (default: ${WORKDIR})
  DROP_BEFORE_RESTORE  (true|false; default: true)
  MAP_FROM             (e.g., "openedx.*")
  MAP_TO               (e.g., "openedx_restore.*")
  TUTOR_BIN            (default: tutor)

Examples:
  # Restore latest backup as-is (drop existing):
  ${0##*/}

  # Restore a specific timestamp:
  ${0##*/} --ts 20251108T184125Z

  # Dry run:
  ${0##*/} --dry-run

  # Restore to a temp namespace first:
  MAP_FROM="openedx.*" MAP_TO="openedx_restore.*" ${0##*/} --ts 20251108T184125Z

EOF
}

LIST_ONLY=false
DRY=false
TS="${TS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ts)       TS="$2"; shift 2;;
    --list)     LIST_ONLY=true; shift;;
    --dry-run)  DRY=true; shift;;
    -h|--help)  usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

### =========================
### DEPS
### =========================
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need aws
need tar
need grep
need sha256sum
need "${TUTOR_BIN}"

# make sure tutor can reach mongodb service
if ! "${TUTOR_BIN}" local status >/dev/null 2>&1; then
  echo "Tutor appears not running; starting containers…" >&2
  "${TUTOR_BIN}" local start -q
fi

# detect a no-tty flag for tutor exec (varies by version)
NO_TTY_FLAG=""
if "${TUTOR_BIN}" local exec --help 2>&1 | grep -q -- ' -T\b'; then
  NO_TTY_FLAG="-T"
elif "${TUTOR_BIN}" local exec --help 2>&1 | grep -q -- '--no-tty'; then
  NO_TTY_FLAG="--no-tty"
fi

### =========================
### LIST / PICK TIMESTAMP
### =========================
list_ts() {
  aws s3 ls "${S3_BUCKET}/" | awk '{print $2}' | sed 's#/##' | sed '/^$/d' | sort
}

if $LIST_ONLY; then
  echo "Available timestamps under ${S3_BUCKET}/:"
  list_ts
  exit 0
fi

if [[ -z "${TS}" ]]; then
  TS="$(list_ts | tail -n1)"
  [[ -n "${TS}" ]] || { echo "No backups found under ${S3_BUCKET}/" >&2; exit 1; }
fi

DEST_DIR="${WORKDIR}/${TS}"
mkdir -p "${DEST_DIR}"
echo "[*] Using timestamp: ${TS}"
echo "[*] Workdir: ${DEST_DIR}"

TAR="${TS}.tar.gz"
SHA="${TS}.tar.gz.sha256"
S3_PREFIX="${S3_BUCKET}/${TS}"

### =========================
### DOWNLOAD + VERIFY
### =========================
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

### =========================
### EXTRACT mongodb.archive.gz
### =========================
echo "[*] Inspecting tarball layout …"
MONGO_IN_TAR="$(tar -tzf "${DEST_DIR}/${TAR}" | grep -E '(^|/)(mongodb\.archive\.gz)$' | head -n1 || true)"
if [[ -z "${MONGO_IN_TAR}" ]]; then
  echo "Could not find mongodb.archive.gz inside ${TAR}" >&2
  tar -tzf "${DEST_DIR}/${TAR}" | head -n 50 >&2
  exit 1
fi
echo "[*] Found: ${MONGO_IN_TAR}"
echo "[*] Extracting ${MONGO_IN_TAR} …"
tar -xzf "${DEST_DIR}/${TAR}" -C "${DEST_DIR}" "${MONGO_IN_TAR}"

# normalize to ${DEST_DIR}/mongodb.archive.gz
if [[ "${MONGO_IN_TAR}" != "mongodb.archive.gz" ]]; then
  cp -f "${DEST_DIR}/${MONGO_IN_TAR}" "${DEST_DIR}/mongodb.archive.gz"
  SUBDIR="$(dirname "${MONGO_IN_TAR}")"
  [[ "${SUBDIR}" != "." ]] && rm -rf "${DEST_DIR}/${SUBDIR}" || true
fi

ARC="${DEST_DIR}/mongodb.archive.gz"
[[ -f "${ARC}" ]] || { echo "Extraction failed: ${ARC} missing" >&2; exit 1; }

### =========================
### DRY-RUN SUMMARY + RESTORE
### =========================

# Build base mongorestore args
RESTORE_ARGS=( mongorestore --archive --gzip )

# Optional namespace include (default from config: openedx.*)
if [[ -n "${MONGO_NS_INCLUDE:-}" ]]; then
  RESTORE_ARGS+=( --nsInclude="${MONGO_NS_INCLUDE}" )
fi

# Optional namespace remap
if [[ -n "${MAP_FROM}" && -n "${MAP_TO}" ]]; then
  RESTORE_ARGS+=( --nsFrom "${MAP_FROM}" --nsTo "${MAP_TO}" )
fi

# Drop before restore
if [[ "${DROP_BEFORE_RESTORE}" == "true" ]]; then
  RESTORE_ARGS+=( --drop )
fi

echo "[*] Ready to restore:"
echo "    archive: ${ARC}"
echo "    nsInclude: ${MONGO_NS_INCLUDE}"
echo "    drop before restore: ${DROP_BEFORE_RESTORE}"

if $DRY; then
  echo "[DRY-RUN] ${TUTOR_BIN} local exec -T mongodb \\"
  echo "           mongorestore --archive --gzip --nsInclude=\"${MONGO_NS_INCLUDE}\" ${DROP_BEFORE_RESTORE:+--drop} < \"${ARC}\""
  exit 0
fi

### =========================
### RESTORE
### =========================
echo "[*] Restoring into Tutor Mongo… (this can take a while)"
set -o pipefail
"${TUTOR_BIN}" local exec -T mongodb \
  mongorestore --archive --gzip --nsInclude="${MONGO_NS_INCLUDE}" ${DROP_BEFORE_RESTORE:+--drop} < "${ARC}"
RC=$?
set +o pipefail

if (( RC != 0 )); then
  echo "Restore exited with code ${RC}" >&2
  exit ${RC}
fi

echo "[✓] Mongo restore complete."


### =========================
### QUICK SANITY COUNTS
### =========================
echo "[*] Sample counts (definitions/structures/fs.files):"
COUNT_SNIPPET='
  function countColl(dbname, coll){
    try{
      const d = db.getSiblingDB(dbname);
      const n = d.getCollection(coll).countDocuments({});
      print(dbname+"."+coll+" = "+n);
    } catch(e){ /* ignore missing */ }
  }
  // check both openedx + openedx_restore namespaces
  var dbs = ["openedx","openedx_restore"];
  var cols = ["modulestore.definitions","modulestore.structures","fs.files"];
  for (const dbn of dbs){
    for (const c of cols){ countColl(dbn, c); }
  }
'
"${TUTOR_BIN}" local exec mongodb bash -lc "mongosh --quiet --eval '${COUNT_SNIPPET}'" || true
