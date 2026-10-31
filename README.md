# HART STS Docker helpers

Self-contained HART STS toolkit: seed generation, database restore, warm-start simulation, switch list generation, and live session prep.

Works with [sts-docker](https://github.com/lnevo/sts-docker) (at `external/sts-docker`, next to this repo).

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

Docker bind-mounts `external/sts-docker-data/backups`. Scripts write `hart_seed` and session backups there.

## Commands

Run from **`external/sts-helpers/`** (the repo root, or its `bin/`):

| Script | Purpose |
|--------|---------|
| `apply_hart_seed.sh` | Generate and/or restore `hart_seed` |
| `apply_warm_start.sh` | Simulate prior operating sessions |
| `run_session_simulations.sh` | Warm start once, then begin + switch lists + play per session |
| `play_operating_session.sh` | Play through one operating session (after begin_session) |
| `generate_switchlists.sh` | Dry-run phased switch lists (D749, NVL, CK1) |
| `sync_operational_steps.sh` | Hot-deploy session editor to the web container |
| `begin_session.sh` | Live session prep after STG-SCULLY |
| `apply_hart_job_descriptions.sh` | Push crew instructions from seed config → DB |
| `sync_hart_seed_config.sh` | Export manual STS edits back into `hart_seed_config.json` |
| `merge_car_fleet_from_backup.sh` | Copy car roster from a backup into generated seed |
| `apply_shipment_tune.sh` | Tune shipment order intervals in the live DB |
| `rewind_ck1_weigh.sh` | CK1 weigh simulation / rewind |
| `build_hart_seed_package.sh` | Assemble portable `hart_seed_package/` |
| `tools/add_hart_cars.py` | Add new cars to the seed and the running database, with fixed ids (run by hart-ops `bin/cars publish`) |

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

Session editor: `http://localhost:8980/sts/editor.html` · API docs: `http://localhost:8980/sts/operational_steps_api-docs.html`

Switch list design, phase logic, and known gaps: **`docs/SWITCHLIST_BUILDING.md`**.

Workflow from an STS user perspective:

- **`docs/WARM_START_STEPS.md`** — prior-session simulation (run once)
- **`docs/BEGIN_SESSION_STEPS.md`** — session-open prep and switch list capture point
- **`docs/FULL_OPERATING_SESSION.md`** — one complete cycle (warm start → begin → lists → play)

Editor recipes and CSVs live under **`external/sts-docker-data/backups/session_editor/`** (Docker bind-mount).

## Requirements

- Python 3.10+, Docker, `pip install openpyxl` (matrix import)
- `ops/car-cards/car-images/CarImagesFinal/` in the hart repo for car photos in generated seed

See `docs/HART_STS_REQUIREMENTS.md` for layout design notes.
