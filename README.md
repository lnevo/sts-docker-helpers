# HART STS Docker helpers

Self-contained HART STS toolkit: seed generation, database restore, warm-start simulation, live session prep, and config sync.

Works with [sts-docker](https://github.com/lnevo/sts-docker) (clone or symlink as `./sts-docker`).

## Layout

```
sts-docker-helpers/
  bin/                 Shell entry points (run from here)
  seed/                Seed generator scripts + config
    inputs/            Roster, waybills, shipping maps
  tools/               DB sync utilities (Python)
  sts/                 PHP helpers (copied into container at run time)
  lib/paths.sh         Shared path resolution
  migrations/          Historical SQL patches
  backups/             SQL backups (hart_seed snapshot included)
  track_scale/         Track scale config reference
  docs/                Design notes
```

## Setup

```bash
git clone https://github.com/lnevo/sts-docker-helpers.git
cd sts-docker-helpers
git clone https://github.com/lnevo/sts-docker.git   # or: ln -sf /path/to/sts-docker ./sts-docker
cd sts-docker && docker compose --profile build up -d
```

Optional: symlink a host backups mount used by Docker:

```bash
ln -sf ~/sts/sts-backups ./sts-backups
```

## Commands (from repo root)

```bash
./bin/apply_hart_seed.sh --generate
./bin/apply_warm_start.sh --tracked
./bin/begin_session.sh --run-stg-scully
./bin/sync_hart_seed_config.sh --backup
python3 seed/generate_hart_seed.py --output backups/hart_seed
```

## Requirements

- Python 3.10+, Docker, `pip install openpyxl` (matrix import)
- `CarImagesFinal/` optional at repo root for car photos in generated seed

See `docs/HART_STS_REQUIREMENTS.md` for layout design notes.
