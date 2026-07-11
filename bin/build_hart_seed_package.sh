#!/usr/bin/env bash
# Assemble hart_seed_package/ — portable backup of everything needed to generate hart_seed.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${_script_home##*/}" != "bin" ]] && _script_home="${_script_home}/bin"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"


CARDS_ROOT="$(cd "${HELPERS_ROOT}/.." && pwd)"
PKG="${CARDS_ROOT}/hart_seed_package"
SEED_INPUTS="${SEED_DIR}/inputs"

rm -rf "${PKG}"
mkdir -p "${PKG}"

copy_cards() {
  local src="$1"
  if [[ -e "${CARDS_ROOT}/${src}" ]]; then
    cp -R "${CARDS_ROOT}/${src}" "${PKG}/$(basename "${src}")"
    echo "  + ${src}"
  else
    echo "  ! missing: ${src}" >&2
  fi
}

copy_seed() {
  local src="$1"
  if [[ -e "${SEED_DIR}/${src}" ]]; then
    cp -R "${SEED_DIR}/${src}" "${PKG}/$(basename "${src}")"
    echo "  + seed/${src}"
  else
    echo "  ! missing: seed/${src}" >&2
  fi
}

copy_tool() {
  local src="$1"
  if [[ -e "${TOOLS_DIR}/${src}" ]]; then
    cp "${TOOLS_DIR}/${src}" "${PKG}/$(basename "${src}")"
    echo "  + tools/${src}"
  else
    echo "  ! missing: tools/${src}" >&2
  fi
}

copy_seed_input() {
  local src="$1"
  if [[ -e "${SEED_INPUTS}/${src}" ]]; then
    cp -R "${SEED_INPUTS}/${src}" "${PKG}/$(basename "${src}")"
    echo "  + seed/inputs/${src}"
  else
    echo "  ! missing: seed/inputs/${src}" >&2
  fi
}

write_wrapper() {
  local name="$1"
  local target="$2"
  cat > "${PKG}/${name}" <<EOF
#!/usr/bin/env bash
exec "\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)/${target}" "\$@"
EOF
  chmod +x "${PKG}/${name}"
  echo "  + ${name} (wrapper -> ${target})"
}

echo "Building ${PKG} ..."

# Generators and matrix workflow (flat copies for portable package use)
copy_seed generate_hart_seed.py
copy_seed balance_shipment_yards.py
copy_seed import_hart_job_matrix.py
copy_cards generate_hart_job_matrix.py
copy_tool sync_hart_seed_config.py
copy_tool sync_hart_car_images.py
copy_tool merge_car_fleet_from_backup.py

# Config and job matrix source
copy_seed hart_seed_config.json
copy_cards hart_job_criteria_matrix.xlsx

# Roster, spots, waybills
copy_cards HART_MergedCarRoster.xml
copy_cards HART_Spot_Waybills.csv
copy_seed_input spot_assignments.csv
copy_cards image_metadata.csv
copy_seed_input spurs

# Shipping / interchange maps
copy_seed_input hart_scully_nville_shipping_map_proposed.csv
copy_seed_input hart_ix_shipping_map_proposed.csv
copy_seed_input hart_expanded_shipping_map_proposed.csv
copy_seed_input hart_shipment_code_renames_proposed.csv
copy_seed_input MRR-AAR_Class_Codes.csv

# Reference doc
if [[ -f "${HELPERS_ROOT}/docs/HART_STS_REQUIREMENTS.md" ]]; then
  cp "${HELPERS_ROOT}/docs/HART_STS_REQUIREMENTS.md" "${PKG}/HART_STS_REQUIREMENTS.md"
  echo "  + docs/HART_STS_REQUIREMENTS.md"
elif [[ -f "${CARDS_ROOT}/HART_STS_REQUIREMENTS.md" ]]; then
  copy_cards HART_STS_REQUIREMENTS.md
fi

# SQL migrations
mkdir -p "${PKG}/migrations"
migration_count=0
for pattern in *_migration.sql tune_shipment*.sql restore_pu_criteria*.sql pu_criteria_backup*.sql; do
  for file in "${MIGRATIONS_DIR}"/${pattern} "${CARDS_ROOT}"/${pattern}; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "${PKG}/migrations/$(basename "${file}")"
    migration_count=$((migration_count + 1))
  done
done
echo "  + migrations/ (${migration_count} SQL files)"

# Track scale config
if [[ -f "${BACKUPS_DIR}/track_scale/track_scale_config.json" ]]; then
  mkdir -p "${PKG}/track_scale"
  cp "${BACKUPS_DIR}/track_scale/track_scale_config.json" "${PKG}/track_scale/"
  echo "  + track_scale/track_scale_config.json"
fi

# Optional seed SQL snapshot
if [[ "${INCLUDE_SEED_SNAPSHOT:-1}" == "1" && -f "${BACKUPS_DIR}/hart_seed" ]]; then
  cp "${BACKUPS_DIR}/hart_seed" "${PKG}/hart_seed"
  echo "  + hart_seed (snapshot from ${BACKUPS_DIR})"
fi

# Full sts-docker-helpers tree (canonical scripts live in bin/)
if [[ -d "${HELPERS_ROOT}" ]]; then
  mkdir -p "${PKG}/sts-docker-helpers"
  rsync -a \
    --exclude '.git' \
    --exclude '__pycache__' \
    "${HELPERS_ROOT}/" "${PKG}/sts-docker-helpers/"
  echo "  + sts-docker-helpers/"
else
  echo "  ! missing: sts-docker-helpers" >&2
fi

write_wrapper apply_hart_seed.sh sts-docker-helpers/bin/apply_hart_seed.sh
write_wrapper apply_warm_start.sh sts-docker-helpers/bin/apply_warm_start.sh
write_wrapper begin_session.sh sts-docker-helpers/bin/begin_session.sh
write_wrapper apply_hart_job_descriptions.sh sts-docker-helpers/bin/apply_hart_job_descriptions.sh
write_wrapper merge_car_fleet_from_backup.sh sts-docker-helpers/bin/merge_car_fleet_from_backup.sh
write_wrapper rewind_ck1_weigh.sh sts-docker-helpers/bin/rewind_ck1_weigh.sh
write_wrapper apply_shipment_tune.sh sts-docker-helpers/bin/apply_shipment_tune.sh
write_wrapper sync_hart_seed_config.sh sts-docker-helpers/bin/sync_hart_seed_config.sh
write_wrapper generate_switchlists.sh sts-docker-helpers/bin/generate_switchlists.sh
write_wrapper run_session_simulations.sh sts-docker-helpers/bin/run_session_simulations.sh

if [[ "${INCLUDE_CAR_IMAGES:-1}" == "1" ]]; then
  copy_cards CarImagesFinal
else
  echo "  ~ CarImagesFinal skipped (cars will be omitted from generated seed)"
fi

cat > "${PKG}/README.md" <<'EOF'
# HART STS seed generator package

Self-contained backup of inputs, migrations, scripts, and helpers to build and restore `hart_seed` (STS Database Maintenance → Restore format).

All operational shell scripts live under `sts-docker-helpers/bin/`. Top-level wrappers in this package re-exec those scripts.

## Requirements

- Python 3.10+
- For matrix Excel import: `pip install openpyxl`
- [sts-docker](https://github.com/lnevo/sts-docker) running with `--profile build`
- For restore/photos: `sts-backups` bind-mounted in the container

## Generate seed SQL

```bash
python3 generate_hart_seed.py --output ./hart_seed
```

## Restore to Docker

```bash
./apply_hart_seed.sh --generate --merge-fleet
./apply_hart_seed.sh --sync-images
```

## Warm start, switch lists, and live session prep

```bash
./run_session_simulations.sh --sessions 10
./apply_warm_start.sh --tracked
./begin_session.sh --run-stg-scully --switchlists
./generate_switchlists.sh --format=phased
```

See `sts-docker-helpers/README.md` for full command reference.

## Rebuild this package

From the parent Car Cards project:

```bash
./build_hart_seed_package.sh
```
EOF

(
  cd "${PKG}"
  find . -type f ! -name MANIFEST.txt | sed 's|^\./||' | sort
) > "${PKG}/MANIFEST.txt"

echo "Done: ${PKG} ($(wc -l < "${PKG}/MANIFEST.txt" | tr -d ' ') files)"
echo "Zip:  cd \"$(dirname "${PKG}")\" && zip -r hart_seed_package.zip \"$(basename "${PKG}")\""
