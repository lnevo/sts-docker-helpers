#!/usr/bin/env bash
set -euo pipefail
_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

# Session-0 seed dump (name includes token 0 for generic Restart Session matching).
SQL_FILE="${BACKUPS_DIR}/hart_seed0"
BACKUP_NAME="hart_seed0"

GENERATE=0
SYNC_IMAGES=0
FLEET_BACKUP=""
MERGE_FLEET=0

usage() {
  cat <<'EOF'
Usage: apply_hart_seed.sh [options]

Generate (optional) and restore hart_seed0 into the running STS Docker stack.
Uses the same # -delimited SQL restore logic as STS Database Maintenance -> Restore.
Optionally syncs car photos from CarImagesFinal into sts-docker-data/backups/hart_seed0_photos/.
Photos are always restored from that folder when it exists (same as STS Restore).

The default name hart_seed0 carries session token 0 so Session Overview
"Restart Session" can discover it when restarting session 1.

Options:
  --generate         Run generate_hart_seed.py before restoring
  --merge-fleet      After --generate, copy car fleet from --fleet-backup (default: session10)
  --fleet-backup PATH  STS backup with car roster (default: sts-docker-data/backups/session10)
  --sync-images      Run sync_hart_car_images.py before restoring (refresh _photos folder)
  --sql-file PATH    SQL file to restore (default: sts-docker-data/backups/hart_seed0)
  -h, --help         Show this help

Drives STS through the REST API (see README "Talking to STS"); the stack must be up.
The sts-docker-data/backups directory is bind-mounted into the container, so the file
is visible to the API without copying.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --generate)
      GENERATE=1
      shift
      ;;
    --merge-fleet)
      MERGE_FLEET=1
      shift
      ;;
    --fleet-backup)
      FLEET_BACKUP="$2"
      shift 2
      ;;
    --sync-images)
      SYNC_IMAGES=1
      shift
      ;;
    --sql-file)
      SQL_FILE="$2"
      BACKUP_NAME="$(basename "$2")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${GENERATE}" -eq 1 ]]; then
  echo "==> Generating ${SQL_FILE}"
  python3 "${SEED_DIR}/generate_hart_seed.py" --output "${SQL_FILE}"
  if [[ "${MERGE_FLEET}" -eq 1 || "$(grep -ci 'insert into \`cars\`' "${SQL_FILE}" || true)" -eq 0 ]]; then
    fleet_source="${FLEET_BACKUP:-${BACKUPS_DIR}/session10}"
    echo "==> Merging car fleet from ${fleet_source}"
    merge_args=(--seed "${SQL_FILE}" --fleet-backup "${fleet_source}" --output "${SQL_FILE}")
    python3 "${TOOLS_DIR}/merge_car_fleet_from_backup.py" "${merge_args[@]}"
  fi
elif [[ ! -f "${SQL_FILE}" ]]; then
  # Legacy name without session token 0 (pre-Restart-Session convention).
  if [[ -f "${BACKUPS_DIR}/hart_seed" ]]; then
    echo "==> Note: using legacy ${BACKUPS_DIR}/hart_seed (prefer hart_seed0)"
    SQL_FILE="${BACKUPS_DIR}/hart_seed"
    BACKUP_NAME="hart_seed"
  else
    echo "SQL file not found: ${SQL_FILE}" >&2
    echo "Run with --generate or: python3 seed/generate_hart_seed.py --output backups/hart_seed0" >&2
    exit 1
  fi
fi

car_rows="$(grep -ci 'insert into \`cars\`' "${SQL_FILE}" || true)"
if [[ "${car_rows}" -eq 0 ]]; then
  echo "ERROR: ${SQL_FILE} has 0 cars. Regenerate with --generate --merge-fleet." >&2
  exit 1
fi
echo "==> ${BACKUP_NAME} car rows: ${car_rows}"

BACKUP_DIR="${BACKUPS_DIR}"
PHOTOS_DIR="${BACKUP_DIR}/${BACKUP_NAME}_photos"
# If restoring/generating hart_seed0 but only legacy photos exist, reuse them.
if [[ ! -d "${PHOTOS_DIR}" && "${BACKUP_NAME}" == "hart_seed0" && -d "${BACKUP_DIR}/hart_seed_photos" ]]; then
  PHOTOS_DIR="${BACKUP_DIR}/hart_seed_photos"
fi

if [[ "${SYNC_IMAGES}" -eq 1 ]]; then
  echo "==> Syncing car images to ${BACKUP_DIR}/${BACKUP_NAME}_photos"
  python3 "${TOOLS_DIR}/sync_hart_car_images.py" \
    --seed-sql "${SQL_FILE}" \
    --output-dir "${BACKUP_DIR}/${BACKUP_NAME}_photos"
  PHOTOS_DIR="${BACKUP_DIR}/${BACKUP_NAME}_photos"
fi

# shellcheck source=../lib/sts_api.sh
source "${_script_home}/../lib/sts_api.sh"
sts_api_guard || exit 1

mkdir -p "${BACKUP_DIR}"
# BACKUPS_DIR may be a symlink to the same place as --sql-file; avoid cp of identical paths
# (macOS cp exits 1 for "identical", which would abort under set -e).
src_dir="$(cd "$(dirname "${SQL_FILE}")" && pwd -P)"
dst_dir="$(cd "${BACKUP_DIR}" && pwd -P)"
if [[ "${src_dir}" != "${dst_dir}" || "$(basename "${SQL_FILE}")" != "${BACKUP_NAME}" ]]; then
  echo "==> Copying ${SQL_FILE} -> ${BACKUP_DIR}/${BACKUP_NAME}"
  cp -f "${SQL_FILE}" "${BACKUP_DIR}/${BACKUP_NAME}"
fi

echo "==> Recreating sts_db3 (full seed restore)"
echo "==> Restoring ${BACKUP_NAME} in web container"
# full=true drops every table first; photos=true clears the rolling-stock folders and
# copies backups/<name>_photos; the API then runs the plugin session-reset hooks.
STS_TASK_QUIET=1 sts_task_run POST /admin/restore \
  "{\"backup\":\"${BACKUP_NAME}\",\"photos\":true,\"full\":true}"
photos="$(sts_api_get_field "${STS_TASK_RESULT}" result.output.photos_restored)"
[[ -n "${photos}" && "${photos}" != "0" ]] && echo "${photos} rolling stock photos restored."
echo "${BACKUP_NAME} restored successfully."
# The restore task runs the plugin session-reset hooks; on HART that includes the
# track scale's cached-weight reset (calibration kept). Same message as before.
echo "Track scale cached weights cleared (calibration kept)."

# HART layout: keep coke (and similar) out of undifferentiated AUTOMATIC generate.
# Core STS reads settings.auto_gen_exclude_shipment_prefixes; locked dumps may predate it.
echo "==> Ensuring auto_gen_exclude_shipment_prefixes=COKE-"
sts_api PUT /settings/auto_gen_exclude_shipment_prefixes \
  '{"value":"COKE-","description":"Exclude shipment code prefixes from AUTOMATIC generate (CSV)"}' >/dev/null

echo ""
echo "Done. STS: http://localhost:8980/sts/"
