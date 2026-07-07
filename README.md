# HART STS Docker helpers

PHP CLI scripts and shell wrappers for warm-start simulation, live session prep, CK1 weigh tests, and syncing manual DB edits back into `hart_seed_config.json`.

Works with [sts-docker](https://github.com/lnevo/sts-docker) and the HART Car Cards project (`apply_hart_seed.sh`, `sts-backups/`, `hart_seed_config.json`).

## Layout

```
sts-docker-helpers/
  apply_warm_start.sh      Simulate prior sessions → hart_warm_start backup
  begin_session.sh         Begin live session after STG-SCULLY
  rewind_ck1_weigh.sh      Restore warm start + re-weigh CK1 coke cars
  sync_hart_seed_config.py Pull jobs/shipments/locations from DB → config JSON
  sts/                     PHP helpers (copied into container at run time)
  lib/paths.sh             Resolves sts-docker and Car Cards paths
```

## Prerequisites

- Docker: `sts-docker` running with `--profile build`
- HART Car Cards project (parent directory or set `HART_CARDS_ROOT`) for backups and seed restore
- Optional: `STS_DOCKER` env var if `sts-docker` is not a sibling directory

Typical clone layout:

```
~/HART/Car Cards/          # HART_CARDS_ROOT (apply_hart_seed.sh, sts-backups/)
~/HART/Car Cards/sts-docker/
~/HART/Car Cards/sts-docker-helpers/   # this repo
```

## Commands

```bash
# Warm start (restore hart_seed, simulate sessions, save hart_warm_start)
./apply_warm_start.sh --tracked --max-sessions 10

# Continue tracked warm start from current session
./apply_warm_start.sh --tracked --continue --sessions 3 --max-sessions 7

# Begin live session (blocked until STG-SCULLY is clear)
./begin_session.sh --run-stg-scully --backup=session_10_start

# Sync manual STS edits into hart_seed_config.json
./sync_hart_seed_config.sh --backup

# CK1 weigh test rewind
./rewind_ck1_weigh.sh
```

## Package

Included in `hart_seed_package/` when you run `build_hart_seed_package.sh` from the Car Cards project (portable backup alongside the seed generator).

## Install into container

Scripts `docker cp` files from `sts/` into the running web container before each run. You do not need to commit these into the sts-docker fork unless you want them baked into the image.
