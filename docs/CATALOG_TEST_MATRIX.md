# Catalog Test Matrix

Test coverage for **selectable** workflow-editor commands (`adder_functions[]` where `disabled` is not set). Greyed-out entries (Reports, Waybills) are listed in the catalog but excluded from this matrix — no API or dispatch work is required for them.

## Regenerate

```bash
# After catalog changes — deploy and validate:
bin/sync_operational_steps.sh --test-catalog

# Or validate/generate only (container must be running):
bin/run_catalog_tests.sh
```

Outputs:

- `sts-backups/session_editor/WORKFLOW_TEST_ALL_TYPES.recipe.json`
- `sts-docker-helpers/docs/WORKFLOW_TEST_ALL_TYPES.recipe.json` (mirror)

## Build Switch Lists ↔ STS GUI

| Workflow command | STS GUI | Simulation dispatch |
|------------------|---------|---------------------|
| `build_switchlists_sts` | Build Switch Lists → **Assign Cars Station-by-Station** | Assign ordered cars at station to job |
| `auto_assign_locals` | Build Switch Lists → **Auto-Assign Cars** → `auto_assign.php` | Criteria-based assign per job(s) |

Test workflow includes two variants of each (specific station/job or jobs list, and locals default).

## Selectable commands (26)

| Group | Command | Test section |
|-------|---------|--------------|
| Before Operations | `generate_orders` | Before Operations |
| | `fill_orders` | Before Operations |
| | `reposition_empties` | Before Operations |
| During Operations | `build_switchlists_sts` ×2 | During Operations |
| | `auto_assign_locals` ×2 | During Operations |
| | `pick_up_cars` ×2 | During Operations |
| | `set_out_cars` ×2 | During Operations |
| | `run_job_criterion` | During Operations |
| | `track_scale` | During Operations |
| After Operations | `load_unload` | After Operations |
| Session | `increment_session` | Session |
| Switch Lists | `generate_switchlists` | Switch Lists |
| | `generate_waybills` | Switch Lists |
| Database | `restore_database` | Setup |
| | `backup_database` | Database |
| | `validate_database` | Database |
| | `import_data` | Database |
| | `restart_session` | Database |
| | `reset_session` | Database |
| | `remove_backup` | Database |
| Notes | `section_label` | Each section header |
| | `text_instruction` | Workflow notes |
| | `if_then` | Workflow notes |
| | `goto` | Workflow notes |
| | `stop` | Final step |

**Not in test workflow:** `wipe_database` (destructive; compile-only if needed later).

## Greyed out (no test/API work)

| Group | Commands |
|-------|----------|
| Waybills | `report_waybill_list`, `report_waybill_cars_print`, `report_waybill_shipments_print` |
| Reports | `report_station_car`, `report_wheel`, `report_fleet`, `report_shipment_forecast`, `report_car_forecast`, `report_car_qr`, `report_location_qr` |

## Integration run

After API validation, run the test recipe against the live DB simulation:

```bash
bin/run_catalog_workflow.sh          # recipe dispatch only
bin/run_catalog_tests.sh             # validate + generate + dispatch (default)
RUN_WORKFLOW=0 bin/run_catalog_tests.sh   # validate + generate only
```

The workflow restores `hart_seed` at step 2, then exercises all runnable catalog commands. Non-runnable steps (validate, import, remove backup) appear as skipped in the log.

For each matrix step:

1. Catalog definition has `label`, `gui_template`
2. `operational_steps_compile_gui()` produces non-empty instruction
3. Recipe → CSV instruction column matches compile output
4. CSV instruction → `guess_function()` returns same command id (except known skips)

Round-trip skipped for: `fill_orders`, `reposition_empties`, `load_unload`, `import_data`, `goto`, `text_instruction`, `track_scale` (legacy `Weigh Cars CK1` alias).

## Source files

| File | Role |
|------|------|
| `sts/catalog_test_matrix.php` | Section/step definitions |
| `bin/generate_test_workflow_csv.php` | Build test workflow JSON |
| `bin/validate_catalog_api.php` | Catalog ↔ compile ↔ import checks |
| `bin/run_catalog_tests.sh` | Docker runner |
