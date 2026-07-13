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
| `track_scale_validate_readonly.php` | — (smoke-test read-only AJAX endpoints) |
| `home_split_benchmark.php` | `benchmark_home_split.sh` |
| `rebuild_waybill_pages.php` | — (one-time: re-render waybill pages after page-break refactor) |
| `cleanup_special_instructions.php` | — (one-time: string-replace stale instruction text on disk) |
| `update_special_instructions.php` | — (one-time: DB + cache + waybill instruction migration) |
| `merge_ck1_switchlists.php` | — (one-time: collapse CK1 inbound/outbound phases per session) |
| `build_station_report.php` | — (`php build_station_report.php [N|all]`: build/cache `session_N/station_report.html`; also built on demand via `so.php`) |

Sweep logs and temp configs are written under `sts-backups/session_editor/` (gitignored).
