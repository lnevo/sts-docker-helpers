# HART STS Docker helpers

Self-contained HART STS toolkit: seed generation, database restore, warm-start
simulation, switch list generation, and live session prep.

Works with [sts-docker](https://github.com/lnevo/sts-docker) (at
`external/sts-docker`, next to this repo).

## Layout

```
sts-docker-helpers/
  bin/                 Shell entry points (canonical — run these)
  seed/                Seed generator + hart_seed_config.json
    inputs/            Roster, waybills, shipping maps
  tools/               Python utilities (sync, merge fleet, job descriptions)
  sts/                 PHP helpers (copied into the container at run time)
  lib/paths.sh         Shared path resolution (Docker, backups, seed dirs)
  migrations/          Historical SQL patches
  backups/             Optional local SQL snapshots (not Docker mount)
  track_scale/         Track scale config reference
  docs/                Design notes
```

Docker bind-mounts `external/sts-docker-data/backups`. Scripts write `hart_seed`
and session backups there.

## Commands

Run from **`external/sts-helpers/`** (the repo root, or its `bin/`):

| Script                           | Purpose                                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `apply_hart_seed.sh`             | Generate and/or restore `hart_seed`                                                                    |
| `apply_warm_start.sh`            | Simulate prior operating sessions                                                                      |
| `run_session_simulations.sh`     | Warm start once, then begin + switch lists + play per session                                          |
| `play_operating_session.sh`      | Play through one operating session (after begin_session)                                               |
| `generate_switchlists.sh`        | Dry-run phased switch lists (D749, NVL, CK1)                                                           |
| `sync_operational_steps.sh`      | Hot-deploy session editor to the web container                                                         |
| `begin_session.sh`               | Live session prep after STG-SCULLY                                                                     |
| `apply_hart_job_descriptions.sh` | Push crew instructions from seed config → DB                                                           |
| `sync_hart_seed_config.sh`       | Export manual STS edits back into `hart_seed_config.json`                                              |
| `merge_car_fleet_from_backup.sh` | Copy car roster from a backup into generated seed                                                      |
| `apply_shipment_tune.sh`         | Tune shipment order intervals in the live DB                                                           |
| `rewind_ck1_weigh.sh`            | CK1 weigh simulation / rewind                                                                          |
| `build_hart_seed_package.sh`     | Assemble portable `hart_seed_package/`                                                                 |
| `tools/add_hart_cars.py`         | Add new cars to the seed and the running database, with fixed ids (run by hart-ops `bin/cars publish`) |

### Examples

```bash
# Fresh seed with car fleet from session10 backup
./sts-docker-helpers/bin/apply_hart_seed.sh --generate --merge-fleet

# Ten operating sessions: warm start once → begin + switch lists + play (×10)
./sts-docker-helpers/bin/run_session_simulations.sh --sessions 10

# Single session prep + switch lists (after STG-SCULLY backlog exists)
./sts-docker-helpers/bin/begin_session.sh --run-stg-scully --switchlists

# Regenerate switch lists only (current DB session)
./sts-docker-helpers/bin/generate_switchlists.sh --format=phased
```

Browse switch lists: `http://localhost:8980/switchlists/index.html`

Session editor: `http://localhost:8980/sts/editor.html` · API docs:
`http://localhost:8980/sts/operational_steps_api-docs.html`

Switch list design, phase logic, and known gaps:
**`docs/SWITCHLIST_BUILDING.md`**.

Workflow from an STS user perspective:

- **`docs/WARM_START_STEPS.md`** — prior-session simulation (run once)
- **`docs/BEGIN_SESSION_STEPS.md`** — session-open prep and switch list capture
  point
- **`docs/FULL_OPERATING_SESSION.md`** — one complete cycle (warm start → begin
  → lists → play)

Editor recipes and CSVs live under
**`external/sts-docker-data/backups/session_editor/`** (Docker bind-mount).

## Talking to STS

The core pipeline drives STS through its REST API v1
(`sts-docker/sts/api/README.md`, Swagger at `/sts/api/docs/`) instead of
`docker exec php` and raw SQL.

- **Base URL:** `STS_API_URL`, else derived: `COMPOSE_PROJECT_NAME=sts-sandbox`
  gives `http://localhost:8981/sts/api/v1` (sandbox), anything else
  `http://localhost:8980/sts/api/v1` (live).
- **Token:** `STS_API_TOKEN`, else the file in `STS_API_TOKEN_FILE`, else
  `<sts-docker-data>/config/bootstrap_admin.token` (beside the backups dir; the
  sandbox uses `$STS_SANDBOX_DATA/config`). Reads need no token by default;
  writes need an admin token.
- **Clients:** `lib/sts_api.sh` (`sts_api METHOD PATH [JSON]`, `sts_task_wait`,
  `sts_task_run`, `sts_session_nbr`) and `lib/sts_api.py` (`get`, `post`, `put`,
  `patch`, `task_wait`).
- **Target guard:** the first write of a run prints
  `==> STS API target: <stack> (<url>)` and checks `/health`. A sandbox compose
  project must see stack `sandbox`, otherwise `live` (`STS_EXPECT_STACK`
  overrides); a mismatch refuses the call, so a wrong URL cannot hit the other
  stack.
- **Sandbox vs live:** run parity work with
  `COMPOSE_PROJECT_NAME=sts-sandbox STS_SANDBOX_DATA=... STS_BACKUPS_DIR=$STS_SANDBOX_DATA/backups STS_DOCKER=...`
  set. Never point the simulation helpers at the live stack.
- **Task output:** long jobs (restore, warm start, begin/play, workflow run) are
  API tasks; their log streams to the console. `STS_TASK_KEEP_TS=1` keeps the
  log timestamps.

Use the API: `apply_hart_seed.sh`, `apply_warm_start.sh` (except `--ck1-test`),
`begin_session.sh`, `play_operating_session.sh`, `run_catalog_workflow.sh`,
`run_session_simulations.sh`, `snapshot_session_db.sh`,
`validate_hart_seed_references.sh`, `apply_hart_job_descriptions.sh`,
`sync_hart_seed_config.sh`, `tools/sync_hart_status.py`,
`tools/add_hart_cars.py`.

Still docker by design, and why:

- Sweeps, waves and traffic runs (`run_*sweep*`, `run_traffic_*`, `run_*_wave`,
  `run_coke_stagger_compare`, `run_track_scale_10x10`), `diagnostics/`,
  `rewind_session.sh`, `backup_sessions.sh`, `sync_operational_steps.sh`,
  `fix_temp_permissions.sh`: dev tools that run PHP inside the container or
  touch its files directly.
- `apply_warm_start.sh --ck1-test`: no API equivalent.
- `run_catalog_tests.sh`: `validate_catalog_api.php` and the OpenAPI/recipe
  generators read the PHP source.
- `run_session_simulations.sh` cleans the container's `switchlists/` dir, and
  `validate_hart_seed_references.sh` checks legacy location aliases, with docker
  (no API route).
- `tools/add_hart_cars.py` needs the new car to get the seed's id; the API
  assigns ids, so it fails loudly when they differ.

## Requirements

- Python 3.10+, Docker, curl, `pip install openpyxl` (matrix import)
- `ops/car-cards/car-images/CarImagesFinal/` in the hart repo for car photos in
  generated seed

See `docs/HART_STS_REQUIREMENTS.md` for layout design notes.
