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
Optionally syncs car photos from Car Cards into sts-backups/hart_seed0_photos/.
Photos are always restored from that folder when it exists (same as STS Restore).

The default name hart_seed0 carries session token 0 so Session Overview
"Restart Session" can discover it when restarting session 1.

Options:
  --generate         Run generate_hart_seed.py before restoring
  --merge-fleet      After --generate, copy car fleet from --fleet-backup (default: session10)
  --fleet-backup PATH  STS backup with car roster (default: sts-backups/session10)
  --sync-images      Run sync_hart_car_images.py before restoring (refresh _photos folder)
  --sql-file PATH    SQL file to restore (default: sts-backups/hart_seed0)
  -h, --help         Show this help

Requires the build-profile web + db containers to be running:
  cd sts-docker && docker compose --profile build up -d

The sts-backups directory is bind-mounted into the container at
/var/www/html/sts/backups, so the file is visible without docker cp.
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

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
DB_CID="$("${COMPOSE[@]}" ps -q db 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running. Start with:" >&2
  echo "  cd ${STS_DOCKER} && docker compose --profile build up -d" >&2
  exit 1
fi

MYSQL_USER="${MYSQL_USER:-sts_user}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-sts_password}"
MYSQL_DATABASE="${MYSQL_DATABASE:-sts_db3}"

mysql_exec() {
  if [[ -z "${DB_CID}" ]]; then
    echo "Database container is not running." >&2
    exit 1
  fi
  docker exec -i "${DB_CID}" \
    mariadb -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" "${MYSQL_DATABASE}" "$@"
}

echo "==> Recreating ${MYSQL_DATABASE} (full seed restore)"
mysql_exec -e "
DROP DATABASE IF EXISTS ${MYSQL_DATABASE};
CREATE DATABASE ${MYSQL_DATABASE} CHARACTER SET latin1 COLLATE latin1_swedish_ci;
"

mkdir -p "${BACKUP_DIR}"
if [[ "$(cd "$(dirname "${SQL_FILE}")" && pwd)" != "$(cd "${BACKUP_DIR}" && pwd)" ]]; then
  echo "==> Copying ${SQL_FILE} -> ${BACKUP_DIR}/${BACKUP_NAME}"
  cp "${SQL_FILE}" "${BACKUP_DIR}/${BACKUP_NAME}"
fi

CONTAINER_SQL="/var/www/html/sts/backups/${BACKUP_NAME}"
echo "==> Restoring ${BACKUP_NAME} in web container"

docker exec \
  -e RESTORE_SQL_FILE="${CONTAINER_SQL}" \
  -e RESTORE_BACKUP_NAME="${BACKUP_NAME}" \
  "${WEB_CID}" php -r '
  function clear_image_folder($dir) {
    foreach (glob($dir . "/*.*") as $file) {
      if (is_file($file)) {
        unlink($file);
      }
    }
  }

  require "/var/www/html/sts/credentials.php";
  chdir("/var/www/html/sts");
  $sql_file = getenv("RESTORE_SQL_FILE");
  if ($sql_file && $sql_file[0] !== "/") {
    $sql_file = getcwd() . "/" . $sql_file;
  }
  if (!$sql_file || !is_file($sql_file)) {
    fwrite(STDERR, "SQL file not found in container: $sql_file\n");
    exit(1);
  }

  $dbc = mysqli_connect(
    getenv("MYSQL_HOST"),
    getenv("MYSQL_USER"),
    getenv("MYSQL_PASSWORD"),
    getenv("MYSQL_DATABASE")
  );
  if (!$dbc) {
    fwrite(STDERR, mysqli_connect_error() . "\n");
    exit(1);
  }

  $sql_string = file_get_contents($sql_file);
  foreach (explode("#", $sql_string) as $sql_cmd) {
    $sql_cmd = trim($sql_cmd);
    if ($sql_cmd === "") {
      continue;
    }
    if (!mysqli_query($dbc, $sql_cmd)) {
      if (stripos($sql_cmd, "drop") === false) {
        fwrite(STDERR, "SQL error: " . mysqli_error($dbc) . "\n");
        fwrite(STDERR, substr($sql_cmd, 0, 200) . "...\n");
        exit(1);
      }
    }
  }

  clear_image_folder("./ImageStore/DB_Images/barcodes");
  clear_image_folder("./ImageStore/DB_Images/qrcodes");
  clear_image_folder("./ImageStore/DB_Images/uploads");
  clear_image_folder("./ImageStore/DB_Images/RollingStock");

  $restore_name = getenv("RESTORE_BACKUP_NAME");
  $restore_dir = "./backups/" . $restore_name . "_photos";
  if (is_dir($restore_dir)) {
    $files = glob($restore_dir . "/*.*");
    if ($files) {
      $photo_dir = "./ImageStore/DB_Images/RollingStock";
      foreach ($files as $file) {
        copy($file, $photo_dir . "/" . basename($file));
      }
      print count($files) . " rolling stock photos restored.\n";
    }
  }

  print basename($sql_file) . " restored successfully.\n";

  $track_scale_helpers = "/var/www/html/sts/plugins/track_scale/track_scale_helpers.php";
  if (is_readable($track_scale_helpers)) {
    require_once $track_scale_helpers;
    track_scale_reset_cached_weights($dbc, true);
    print "Track scale cached weights cleared (calibration kept).\n";
  }
'

echo ""
echo "Done. STS: http://localhost:8980/sts/"
