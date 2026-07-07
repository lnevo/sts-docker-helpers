# sts-docker-helpers

Self-contained HART STS toolkit: seed generation, database restore, warm-start simulation, live session prep, and config sync.

Works with [sts-docker](https://github.com/lnevo/sts-docker) (clone or symlink as `./sts-docker`).

## Layout

```
sts-docker-helpers/
  apply_hart_seed.sh       Generate/restore hart_seed SQL
  apply_warm_start.sh        Simulate prior sessions → hart_warm_start
  apply_shipment_tune.sh     Tune shipment intervals in live DB
  begin_session.sh           Begin live session (STG-SCULLY gate)
  rewind_ck1_weigh.sh        Restore warm start + re-weigh CK1 coke
  sync_hart_seed_config.py   Pull DB edits → hart_seed_config.json
  sync_hart_car_images.py    Build backup photos from CarImagesFinal/
  generate_hart_seed.py      Build hart_seed SQL from config + roster
  import_hart_job_matrix.py  Refresh jobs from Excel matrix
  hart_seed_config.json      Jobs, shipments, locations, criteria
  backups/hart_seed          Seed SQL snapshot (also ./hart_seed)
  migrations/                Historical SQL patches
  track_scale/               Track scale config reference
  sts/                       PHP helpers (synced into container at run time)
  lib/paths.sh               Path resolution for shell scripts
```

## Setup

```bash
git clone https://github.com/lnevo/sts-docker-helpers.git
cd sts-docker-helpers

# Clone sts-docker alongside or symlink your existing tree:
git clone https://github.com/lnevo/sts-docker.git
# ln -sf /path/to/sts-docker ./sts-docker

cd sts-docker && docker compose --profile build up -d
```

Optional: symlink a host `sts-backups` mount used by Docker:

```bash
ln -sf ~/sts/sts-backups ./sts-backups
```

Or use the bundled `./backups/` directory (default for scripts).

## Generate seed SQL

```bash
python3 generate_hart_seed.py --output ./backups/hart_seed
```

Requires `CarImagesFinal/` for revenue cars (not in repo — copy from Car Cards project or run with 0 cars by omitting images).

## Restore to Docker

```bash
./apply_hart_seed.sh --generate
./apply_hart_seed.sh --sql-file ./backups/hart_seed
./apply_hart_seed.sh --sync-images   # needs CarImagesFinal/
```

## Warm start & live session

```bash
./apply_warm_start.sh --tracked --max-sessions 10
./begin_session.sh --run-stg-scully --backup=session_start
```

## Sync manual STS edits into config

```bash
./sync_hart_seed_config.sh --backup
python3 generate_hart_seed.py --output ./backups/hart_seed
```

## Refresh jobs from Excel

```bash
python3 import_hart_job_matrix.py
python3 generate_hart_seed.py --output ./backups/hart_seed
```

## Requirements

- Python 3.10+
- Docker ([sts-docker](https://github.com/lnevo/sts-docker))
- `pip install openpyxl` (matrix import)

See `HART_STS_REQUIREMENTS.md` for layout design notes.
