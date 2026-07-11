# Legacy CLI scripts (host-side only)

Runtime PHP for the Docker image lives in **`sts-docker/sts/`** and is baked in at build time (`COPY sts /var/www/html/sts`).

This folder keeps **optional command-line entry points** used by `sts-docker-helpers/bin/` scripts. They are hot-copied into the container only when you run those scripts—not part of the default image workflow.

| File | Used by |
|------|---------|
| `begin_operating_session.php` | `begin_session.sh` |
| `play_operating_session.php` | `play_operating_session.sh` |
| `simulate_warm_start.php` | `apply_warm_start.sh` |
| `simulate_ck1_weigh.php` | `rewind_ck1_weigh.sh`, `apply_warm_start.sh` |
| `setup_ck1_weigh_test.php` | manual / dev |

**Workflow editor, operational steps API, catalog dispatch, track scale, and switch-list helpers** are maintained under `sts-docker/sts/` only. After `docker compose build`, no `docker cp` sync is required for those files.
