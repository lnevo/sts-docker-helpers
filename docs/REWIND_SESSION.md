# Session snapshot & rewind

STS keeps **no automatic per-session database snapshot**. The only persistent
"which session are we in" state is the `session_nbr` row in the `settings` table,
and advancing a session is just an integer increment plus new `car_orders` /
`shipments.last_ship_date` writes. The `session_state/` tree holds only generated
HTML/JSON **output**, not database rows.

So to roll a session back reliably you must have captured the DB **at the end of
the previous session**. Two host-side helpers support this:

| Script | Purpose |
|--------|---------|
| `bin/snapshot_session_db.sh` | Write a full `#`-delimited SQL dump of the current DB to `sts-backups/db_session_<N>` |
| `bin/rewind_session.sh` | Delete a session and restore the DB to the end of the previous session |

Both operate on the running Docker stack (`sts-docker-web-1` / `sts-docker-db-1`)
and resolve paths via `lib/paths.sh`.

## Recommended workflow (going forward)

At the **end of each operating session**, before generating/working the next one,
snapshot the DB:

```bash
bin/snapshot_session_db.sh          # writes sts-backups/db_session_<current N>
```

This is the enabling prerequisite — with a `db_session_<N>` on hand, rewinding the
next session is a clean, authoritative restore.

## Rewinding

```bash
bin/rewind_session.sh --dry-run     # show the plan, change nothing
bin/rewind_session.sh               # remove current session, restore PREV snapshot
bin/rewind_session.sh --to 11       # remove session 11 (restore db_session_10)
bin/rewind_session.sh --snapshot NAME   # restore an explicitly named dump
```

Each rewind:

1. Safety-dumps the current DB to `sts-backups/rewind_undo_<timestamp>`.
2. Restores `db_session_<PREV>` (full SQL replay; car photos and track-scale
   calibration are left untouched).
3. Archives + removes the `session_state/session_<N>` output tree(s) into
   `sts-backups/rewind_archive/`.
4. Verifies `settings.session_nbr == PREV`.

To undo a rewind, restore the printed `rewind_undo_<timestamp>` dump.

## No snapshot? (best effort)

If no `db_session_<PREV>` exists, `--allow-reverse` will delete the session's
`car_orders` (`NNN-%` waybills) and `history` rows, revert
`shipments.last_ship_date`, and decrement `session_nbr`. **This cannot restore
car positions or status** (`cars.current_location_id`, `status`,
`handled_by_job_id`, `position`, `last_spotted`) — only a snapshot can. Treat it
as a partial cleanup, not a true rewind.

## Notes

- Snapshots/dumps live in `sts-backups/` (bind-mounted to
  `/var/www/html/sts/backups` in the web container), so they are visible to the
  STS Database Maintenance → Restore UI as well.
- The restore replays the same `#`-delimited format used by `apply_hart_seed.sh`
  and the web Restore, but deliberately skips the ImageStore wipe so rewinding
  never deletes rolling-stock photos.
- `session_redirect_if_beyond_current()` already makes the web UI tolerate a
  decremented `session_nbr`, so stale deep links fall back to the current session.
