#!/usr/bin/env bash
# Copy hart_seed into the running STS container and restore it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_sts_docker() {
  if [[ -n "${STS_DOCKER:-}" && -d "${STS_DOCKER}" ]]; then
    STS_DOCKER="$(cd "${STS_DOCKER}" && pwd)"
    return
  fi
  local candidate
  for candidate in "${SCRIPT_DIR}/sts-docker" "${SCRIPT_DIR}/../sts-docker"; do
    if [[ -d "${candidate}" ]]; then
      STS_DOCKER="$(cd "${candidate}" && pwd)"
      return
    fi
  done
  echo "sts-docker not found. Set STS_DOCKER." >&2
  exit 1
}

resolve_default_sql_file() {
  if [[ -f "${SCRIPT_DIR}/hart_seed" ]]; then
    echo "${SCRIPT_DIR}/hart_seed"
  elif [[ -f "${SCRIPT_DIR}/backups/hart_seed" ]]; then
    echo "${SCRIPT_DIR}/backups/hart_seed"
  elif [[ -f "${SCRIPT_DIR}/sts-backups/hart_seed" ]]; then
    echo "${SCRIPT_DIR}/sts-backups/hart_seed"
  else
    echo "${SCRIPT_DIR}/backups/hart_seed"
  fi
}

resolve_backup_dir() {
  if [[ -d "${SCRIPT_DIR}/backups" ]]; then
    echo "${SCRIPT_DIR}/backups"
    return
  fi
  if [[ -d "${SCRIPT_DIR}/sts-backups" ]]; then
    echo "${SCRIPT_DIR}/sts-backups"
    return
  fi
  if [[ -n "${HART_CARDS_ROOT:-}" && -d "${HART_CARDS_ROOT}/sts-backups" ]]; then
    echo "${HART_CARDS_ROOT}/sts-backups"
    return
  fi
  if [[ -d "${SCRIPT_DIR}/../sts-backups" ]]; then
    echo "${SCRIPT_DIR}/../sts-backups"
    return
  fi
  echo "${SCRIPT_DIR}/backups"
}

resolve_sts_docker
SQL_FILE="$(resolve_default_sql_file)"
BACKUP_NAME="hart_seed"
COMPOSE=(docker compose -f "${STS_DOCKER}/docker-compose.yml" --profile build)

GENERATE=0
SYNC_IMAGES=0

usage() {
  cat <<'EOF'
Usage: apply_hart_seed.sh [options]

Generate (optional) and restore hart_seed into the running STS Docker stack.
Uses the same # -delimited SQL restore logic as STS Database Maintenance -> Restore.
Optionally syncs car photos from Car Cards into sts-backups/hart_seed_photos/.
Photos are always restored from that folder when it exists (same as STS Restore).

Options:
  --generate         Run generate_hart_seed.py before restoring
  --sync-images      Run sync_hart_car_images.py before restoring (refresh _photos folder)
  --sql-file PATH    SQL file to restore (default: sts-backups/hart_seed)
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
  python3 "${SCRIPT_DIR}/generate_hart_seed.py" --output "${SQL_FILE}"
elif [[ ! -f "${SQL_FILE}" ]]; then
  echo "SQL file not found: ${SQL_FILE}" >&2
  echo "Run with --generate or: python3 generate_hart_seed.py" >&2
  exit 1
fi

BACKUP_DIR="$(resolve_backup_dir)"
PHOTOS_DIR="${BACKUP_DIR}/${BACKUP_NAME}_photos"
if [[ ! -d "${BACKUP_DIR}" && -d "${SCRIPT_DIR}/hart_seed_photos" ]]; then
  PHOTOS_DIR="${SCRIPT_DIR}/hart_seed_photos"
fi

if [[ "${SYNC_IMAGES}" -eq 1 ]]; then
  echo "==> Syncing car images to ${PHOTOS_DIR}"
  python3 "${SCRIPT_DIR}/sync_hart_car_images.py" \
    --seed-sql "${SQL_FILE}" \
    --output-dir "${PHOTOS_DIR}"
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

# Ensure the file lives on the host backups mount (symlink to ~/sts-backups).
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

  // Match restore_db.php: always restore photos when _photos folder exists.
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

  if (is_readable("/var/www/html/sts/track_scale_helpers.php")) {
    require_once "/var/www/html/sts/track_scale_helpers.php";
    track_scale_reset_cached_weights($dbc, true);
    print "Track scale cached weights cleared (calibration kept).\n";
  }
'

echo ""
echo "Done. STS: http://localhost:8980/sts/"
