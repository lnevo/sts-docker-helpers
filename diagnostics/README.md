# STS diagnostics (not part of web runtime)

CLI sweep and benchmark scripts for shipment tuning, traffic studies, and
track-scale sampling. These are **operational dev tools**, not served by Apache.

## Usage

Run via the matching `sts-docker-helpers/bin/run_*.sh` wrapper (copies the script
into the web container and executes it), or locally when PHP can reach the DB:

```bash
php diagnostics/traffic_sweep.php 10 hart_session
```

Scripts bootstrap from `bootstrap.php`, which locates `sts-docker/sts/` for
`require_once` of runtime helpers.

## Scripts

| Script | Bin wrapper |
|--------|-------------|
| `traffic_sweep.php` | — |
| `lane_tune_round.php` | `run_lane_tune_sweep.sh` |
| `nvl_tune_round.php` | `run_nvl_tune_sweep.sh` |
| `coke_stagger_compare.php` | `run_coke_stagger_compare.sh` |
| `track_scale_10x10.php` | `run_track_scale_10x10.sh`, `run_traffic_extremes.sh`, `run_gate_reposition_sweep.sh` |
| `home_split_benchmark.php` | `benchmark_home_split.sh` |

Sweep logs and temp configs are written under `sts-backups/session_editor/` (gitignored).
