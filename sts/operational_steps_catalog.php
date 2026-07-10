<?php
/**
 * STS operational step catalog, recipe compile, and CSV import/export.
 */

require_once __DIR__ . '/warm_start_helpers.php';

function operational_steps_catalog_categories()
{
    return [
        'session' => 'Session flow',
        'operations' => 'Operations',
        'switchlists' => 'Switch lists',
        'reports' => 'Reports',
        'database' => 'Database',
        'workflow' => 'Workflow notes',
    ];
}

/** Groupings for the step-adder dropdown (generic STS commands). */
function operational_steps_catalog_adder_categories()
{
    return [
        'before' => 'Before Operations',
        'during' => 'During Operations',
        'after' => 'After Operations',
        'session' => 'Session',
        'switchlists' => 'Switch Lists',
        'waybills' => 'Waybills',
        'reports' => 'Reports',
        'database' => 'Database',
        'workflow' => 'Notes',
    ];
}

function operational_steps_catalog_adder_order()
{
    return [
        'before' => ['generate_orders', 'fill_orders', 'reposition_empties'],
        'during' => [
            'assign_cars', 'pick_up_cars', 'set_out_cars', 'organize_cars',
            'auto_assign_locals', 'pick_up_locals', 'set_out_locals',
            'run_job_criterion', 'track_scale',
        ],
        'after' => ['load_unload'],
        'session' => ['increment_session'],
        'switchlists' => [
            'generate_switchlists', 'generate_waybills',
            'build_switchlists_sts', 'display_switchlists_sts',
        ],
        'waybills' => [
            'report_waybill_list', 'report_waybill_cars_print', 'report_waybill_shipments_print',
        ],
        'reports' => [
            'report_station_car', 'report_wheel', 'report_fleet',
            'report_shipment_forecast', 'report_car_forecast',
            'report_car_qr', 'report_location_qr',
        ],
        'database' => [
            'restore_database', 'backup_database', 'validate_database',
            'restart_session', 'reset_session', 'import_data', 'remove_backup', 'wipe_database',
        ],
        'workflow' => ['section_label', 'if_then', 'goto', 'stop'],
    ];
}

function operational_steps_catalog_text_param($key, $label, $default = '', $required = false, $placeholder = '')
{
    return [
        'key' => $key,
        'label' => $label,
        'type' => 'text',
        'default' => $default,
        'required' => $required,
        'placeholder' => $placeholder,
    ];
}

function operational_steps_catalog_job_param($required = true, $optional_label = 'Job')
{
    return [
        'key' => 'job',
        'label' => $optional_label,
        'type' => 'job',
        'options_from' => 'jobs',
        'allow_custom' => true,
        'required' => $required,
        'default' => '',
    ];
}

function operational_steps_catalog_location_param($required = true, $label = 'Location', $optional = false)
{
    return [
        'key' => 'location',
        'label' => $label,
        'type' => 'location',
        'options_from' => 'locations',
        'allow_custom' => true,
        'required' => $required && !$optional,
        'default' => '',
    ];
}

function operational_steps_catalog_backup_param($required = true, $default = '')
{
    return [
        'key' => 'backup',
        'label' => 'Backup file',
        'type' => 'backup',
        'options_from' => 'backups',
        'allow_custom' => true,
        'required' => $required,
        'default' => $default,
    ];
}

function operational_steps_catalog_scope_param()
{
    return [
        'key' => 'scope',
        'label' => 'Scope',
        'type' => 'scope',
        'options_from' => 'scopes',
        'allow_custom' => true,
        'required' => false,
        'default' => 'locals',
    ];
}

function operational_steps_fetch_dynamic_options($dbc)
{
    $jobs = [];
    $rs = mysqli_query($dbc, 'SELECT id, name FROM jobs ORDER BY name');
    while ($row = mysqli_fetch_array($rs)) {
        $jobs[] = ['id' => (int) $row['id'], 'name' => (string) $row['name']];
    }

    $locations = [];
    $rs = mysqli_query(
        $dbc,
        'SELECT locations.id, locations.code, routing.station AS station_name
         FROM locations
         LEFT JOIN routing ON locations.station = routing.id
         ORDER BY routing.station, locations.code'
    );
    while ($row = mysqli_fetch_array($rs)) {
        $code = (string) ($row['code'] ?? '');
        $station = (string) ($row['station_name'] ?? '');
        $locations[] = [
            'id' => (int) $row['id'],
            'code' => $code,
            'station' => $station,
            'label' => ($station !== '' ? $station . ' / ' : '') . $code,
        ];
    }

    $location_aliases = array_keys(operational_steps_catalog_locations());
    foreach ($location_aliases as $alias) {
        $locations[] = ['id' => 0, 'code' => $alias, 'station' => '', 'label' => $alias];
    }

    $scopes = [['value' => 'locals', 'label' => 'All locals (non-staging)']];
    foreach ($jobs as $job) {
        $scopes[] = ['value' => $job['name'], 'label' => $job['name']];
    }

    $backups = [];
    $backup_dir = __DIR__ . '/backups';
    if (is_dir($backup_dir)) {
        foreach (scandir($backup_dir) ?: [] as $entry) {
            if ($entry === '.' || $entry === '..' || is_dir($backup_dir . '/' . $entry)) {
                continue;
            }
            if (preg_match('/_photos$/', $entry)) {
                continue;
            }
            $backups[] = $entry;
        }
        sort($backups);
    }

    $setout_extras = [
        ['value' => 'remainder', 'label' => 'remainder (clear train)'],
        ['value' => 'Demmler/Scully', 'label' => 'Demmler/Scully'],
        ['value' => 'Island/Shenango', 'label' => 'Island/Shenango'],
    ];
    $setout_locations = [];
    foreach ($location_aliases as $alias) {
        $setout_locations[] = ['value' => $alias, 'label' => $alias];
    }
    foreach ($locations as $loc) {
        if ($loc['code'] !== '' && !in_array($loc['code'], $location_aliases, true)) {
            $setout_locations[] = ['value' => $loc['code'], 'label' => $loc['label']];
        }
    }
    foreach ($setout_extras as $extra) {
        $setout_locations[] = $extra;
    }

    $shipments = [];
    $rs = mysqli_query($dbc, 'SELECT id, code, description FROM shipments ORDER BY code');
    while ($row = mysqli_fetch_array($rs)) {
        $shipments[] = [
            'id' => (int) $row['id'],
            'code' => (string) $row['code'],
            'label' => (string) $row['code'] . ' — ' . (string) $row['description'],
        ];
    }

    $car_codes = [];
    $rs = mysqli_query($dbc, 'SELECT id, code, description FROM car_codes ORDER BY code');
    while ($row = mysqli_fetch_array($rs)) {
        $car_codes[] = [
            'id' => (int) $row['id'],
            'code' => (string) $row['code'],
            'label' => (string) $row['code'] . ' — ' . (string) $row['description'],
        ];
    }

    $commodities = [];
    $rs = mysqli_query($dbc, 'SELECT id, code, description FROM commodities ORDER BY code');
    while ($row = mysqli_fetch_array($rs)) {
        $commodities[] = [
            'id' => (int) $row['id'],
            'code' => (string) $row['code'],
            'label' => (string) $row['code'] . ' — ' . (string) $row['description'],
        ];
    }

    require_once __DIR__ . '/session_helpers.php';

    return [
        'jobs' => $jobs,
        'locations' => $locations,
        'scopes' => $scopes,
        'backups' => $backups,
        'setout_extras' => $setout_extras,
        'setout_locations' => $setout_locations,
        'shipments' => $shipments,
        'car_codes' => $car_codes,
        'commodities' => $commodities,
        'condition_variables' => session_condition_variables(),
        'condition_operators' => session_condition_operators(),
    ];
}

function operational_steps_catalog_jobs()
{
    return ['D749', 'NVL', 'CK1', 'STG-SCULLY', 'STG-DEMMLER'];
}

function operational_steps_catalog_locations()
{
    return [
        'Demmler' => 'Demmler Yard / offline (station 10)',
        'South-Yard' => 'South Yard (SOUTH)',
        'Scully' => 'Scully yard (station 9)',
        'Scully-Offline' => 'Scully offline / McKees Rock',
        'Shenango' => 'Shenango Coke Works (station 12)',
        'South-Scale' => 'South Yard scale track',
        'Island' => 'Neville Island (station 3)',
    ];
}

function operational_steps_catalog_definitions()
{
    $jobs = operational_steps_catalog_jobs();
    $locs = array_keys(operational_steps_catalog_locations());

    return [
        [
            'id' => 'restore_database',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Restore Database',
            'gui_template' => 'Restore Database {backup}',
            'description' => 'Restore STS from a backup file in sts/backups/. Shell: apply_hart_seed.sh for hart_seed.',
            'runnable' => true,
            'dispatch' => 'restore_database',
            'gui_path' => '/sts/restore_db.php',
            'params' => [
                operational_steps_catalog_backup_param(true, 'hart_seed'),
            ],
        ],
        [
            'id' => 'backup_database',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Create Backup',
            'gui_template' => 'Create Backup {backup}',
            'description' => 'Export current database to sts/backups/. GUI: backup_db.php.',
            'runnable' => true,
            'dispatch' => 'backup_database',
            'gui_path' => '/sts/backup_db.php',
            'params' => [
                operational_steps_catalog_backup_param(true, 'manual_backup'),
            ],
        ],
        [
            'id' => 'validate_database',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Validate Database',
            'gui_template' => 'Validate Database',
            'description' => 'Check STS for broken links and data integrity. GUI: validate_db.php.',
            'runnable' => false,
            'gui_path' => '/sts/validate_db.php',
            'params' => [],
        ],
        [
            'id' => 'remove_backup',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Remove Backup',
            'gui_template' => 'Remove Backup {backup}',
            'description' => 'Delete a backup file from sts/backups/. GUI: remove_backup.php.',
            'runnable' => false,
            'gui_path' => '/sts/remove_backup.php',
            'params' => [
                operational_steps_catalog_backup_param(true),
            ],
        ],
        [
            'id' => 'import_data',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Import Data',
            'gui_template' => 'Import Data {table} ({add_replace})',
            'description' => 'Import tables from CSV. GUI: import_tables.php.',
            'runnable' => false,
            'gui_path' => '/sts/import_tables.php',
            'params' => [
                [
                    'key' => 'table',
                    'label' => 'Table',
                    'type' => 'select',
                    'options' => ['commodities', 'car_codes', 'routing', 'locations', 'shipments', 'cars'],
                    'default' => 'shipments',
                ],
                [
                    'key' => 'add_replace',
                    'label' => 'Mode',
                    'type' => 'select',
                    'options' => ['append', 'replace'],
                    'default' => 'append',
                ],
                operational_steps_catalog_text_param('file', 'CSV file path', '', false, 'uploads/myfile.csv'),
            ],
        ],
        [
            'id' => 'restart_session',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Restart Session',
            'gui_template' => 'Restart Session',
            'description' => 'Restart shippers, cancel waybills, release all cars. GUI: restart.php.',
            'runnable' => false,
            'gui_path' => '/sts/restart.php',
            'params' => [],
        ],
        [
            'id' => 'reset_session',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Reset Session',
            'gui_template' => 'Reset Session',
            'description' => 'Restart session and reset all cars. GUI: reset.php.',
            'runnable' => false,
            'gui_path' => '/sts/reset.php',
            'params' => [],
        ],
        [
            'id' => 'wipe_database',
            'category' => 'database',
            'adder' => true,
            'adder_group' => 'database',
            'label' => 'Wipe Database',
            'gui_template' => 'Wipe Database',
            'description' => 'Erase all STS data — use only when rebuilding. GUI: wipe.php.',
            'runnable' => false,
            'gui_path' => '/sts/wipe.php',
            'params' => [],
        ],
        [
            'id' => 'warm_start_tracked',
            'category' => 'session',
            'label' => 'Warm Start (tracked)',
            'gui_template' => 'Warm Start tracked simulation',
            'description' => 'Simulate prior operating days until STG-SCULLY backlog is ready. CLI: apply_warm_start.sh.',
            'runnable' => true,
            'dispatch' => 'warm_start_tracked',
            'params' => [
                ['key' => 'min_sessions', 'label' => 'Min sessions', 'type' => 'number', 'default' => '3', 'min' => 1, 'max' => 30],
                ['key' => 'max_sessions', 'label' => 'Max sessions', 'type' => 'number', 'default' => '12', 'min' => 1, 'max' => 30],
            ],
        ],
        [
            'id' => 'begin_operating_session',
            'category' => 'session',
            'adder' => false,
            'label' => 'Begin Operating Session (composite)',
            'gui_template' => 'Begin Operating Session',
            'description' => 'STG-SCULLY (optional), load/unload, increment session, fill, reposition, auto-assign.',
            'runnable' => true,
            'dispatch' => 'begin_operating_session',
            'params' => [
                ['key' => 'run_stg_scully', 'label' => 'Run STG-SCULLY', 'type' => 'select', 'options' => ['yes', 'no'], 'default' => 'yes'],
            ],
        ],
        [
            'id' => 'play_operating_session',
            'category' => 'session',
            'adder' => false,
            'label' => 'Play Operating Session (composite)',
            'gui_template' => 'Play Operating Session',
            'description' => 'Run dispatch through session end; defer STG-SCULLY for next begin. CLI: play_operating_session.sh.',
            'runnable' => true,
            'dispatch' => 'play_operating_session',
            'params' => [],
        ],
        [
            'id' => 'evaluate_session_prep',
            'category' => 'session',
            'adder' => false,
            'label' => 'Evaluate Session Prep',
            'gui_template' => 'Evaluate Session Prep',
            'description' => 'Report unfilled orders, empties, staging backlog, and per-job assign eligibility.',
            'runnable' => true,
            'dispatch' => 'evaluate_session_prep',
            'params' => [],
        ],
        [
            'id' => 'section_label',
            'category' => 'workflow',
            'adder' => true,
            'adder_group' => 'workflow',
            'label' => 'Section label',
            'gui_template' => '{label}',
            'description' => 'Section heading with optional remarks (non-operational).',
            'runnable' => false,
            'params' => [
                ['key' => 'label', 'label' => 'Label', 'type' => 'text', 'default' => '', 'required' => true],
            ],
        ],
        [
            'id' => 'stop',
            'category' => 'workflow',
            'adder' => true,
            'adder_group' => 'workflow',
            'label' => 'Stop',
            'gui_template' => 'Stop execution',
            'description' => 'Halt recipe execution at this step.',
            'runnable' => true,
            'dispatch' => 'stop',
            'params' => [],
        ],
        [
            'id' => 'goto',
            'category' => 'workflow',
            'adder' => true,
            'adder_group' => 'workflow',
            'label' => 'Goto step',
            'gui_template' => 'Goto step {step}',
            'description' => 'Jump to another step number in this recipe.',
            'runnable' => true,
            'dispatch' => 'goto',
            'params' => [
                ['key' => 'step', 'label' => 'Target step #', 'type' => 'number', 'default' => '1', 'required' => true, 'min' => 1],
            ],
        ],
        [
            'id' => 'if_then',
            'category' => 'workflow',
            'adder' => true,
            'adder_group' => 'workflow',
            'label' => 'If … then',
            'gui_template' => 'If {variable} {operator} {value}',
            'description' => 'When false, skip the next step. Variables: session #, unfilled count, STG backlog, cars on job, cars at location.',
            'runnable' => true,
            'dispatch' => 'if_then',
            'params' => [
                [
                    'key' => 'variable',
                    'label' => 'Variable',
                    'type' => 'select',
                    'options' => [
                        'session_nbr', 'unfilled_count', 'stg_backlog_eligible', 'stg_backlog_on_jobs',
                        'cars_on_job', 'cars_at_location', 'awaiting_assignment',
                    ],
                    'default' => 'session_nbr',
                ],
                [
                    'key' => 'operator',
                    'label' => 'Operator',
                    'type' => 'select',
                    'options' => ['=', '!=', '<', '<=', '>', '>='],
                    'default' => '>=',
                ],
                ['key' => 'value', 'label' => 'Value', 'type' => 'text', 'default' => '1', 'required' => true],
                operational_steps_catalog_job_param(false, 'Job (for cars_on_job)'),
                operational_steps_catalog_location_param(false, 'Location (for cars_at_location)', true),
            ],
        ],
        [
            'id' => 'marker',
            'category' => 'workflow',
            'adder' => false,
            'label' => 'Section note (legacy)',
            'gui_template' => '{note}',
            'description' => 'Legacy marker — use Section label instead.',
            'runnable' => false,
            'params' => [
                ['key' => 'note', 'label' => 'Note', 'type' => 'text', 'default' => '', 'required' => true],
            ],
        ],
        [
            'id' => 'run_stg_scully',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Run STG-SCULLY',
            'gui_template' => 'Run STG-SCULLY {context}',
            'description' => 'Assign, pick up, set out at Scully offline. Clears staging backlog.',
            'runnable' => true,
            'dispatch' => 'staging_job',
            'params' => [
                ['key' => 'context', 'label' => 'Context', 'type' => 'select', 'options' => ['pending backlog', 'Scully', 'Scully-Offline'], 'default' => 'Scully-Offline'],
            ],
        ],
        [
            'id' => 'run_stg_demmler',
            'category' => 'operations',
            'label' => 'Run STG-DEMMLER',
            'gui_template' => 'Run STG-DEMMLER',
            'description' => 'Session-end Demmler offline staging swap.',
            'runnable' => true,
            'dispatch' => 'staging_job',
            'dispatch_job' => 'STG-DEMMLER',
            'params' => [],
        ],
        [
            'id' => 'defer_stg_scully',
            'category' => 'session',
            'label' => 'Defer STG-SCULLY',
            'gui_template' => 'Defer STG-SCULLY leave backlog {location}',
            'description' => 'Leave cars at Scully eligible; do not run STG-SCULLY.',
            'runnable' => false,
            'params' => [
                ['key' => 'location', 'label' => 'Location', 'type' => 'select', 'options' => ['Scully'], 'default' => 'Scully'],
            ],
        ],
        [
            'id' => 'generate_orders',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'before',
            'label' => 'Generate Car Orders',
            'gui_template' => 'Generate Orders {shipment}',
            'description' => 'Manual generate for one shipment (all loads for that shipment, no session increment). Leave shipment blank for auto-generate all.',
            'runnable' => true,
            'dispatch' => 'generate_orders',
            'params' => [
                [
                    'key' => 'shipment',
                    'label' => 'Shipment',
                    'type' => 'shipment',
                    'options_from' => 'shipments',
                    'allow_custom' => true,
                    'required' => false,
                    'default' => '',
                ],
            ],
        ],
        [
            'id' => 'increment_session',
            'category' => 'session',
            'adder' => true,
            'adder_group' => 'session',
            'label' => 'Increment Session Number',
            'gui_template' => 'Increment Session Number',
            'description' => 'Settings → advance session number by 1.',
            'runnable' => true,
            'dispatch' => 'increment_session',
            'params' => [],
        ],
        [
            'id' => 'fill_orders',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'before',
            'label' => 'Fill Car Orders',
            'gui_template' => 'Fill Orders',
            'description' => 'Orders → fill unfilled car orders.',
            'runnable' => true,
            'dispatch' => 'fill_orders',
            'params' => [
                ['key' => 'fraction', 'label' => 'Fraction', 'type' => 'number', 'default' => '1', 'required' => false, 'min' => 0, 'max' => 1, 'step' => 0.05],
            ],
        ],
        [
            'id' => 'reposition_empties',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'before',
            'label' => 'Reposition Empty Cars',
            'gui_template' => 'Reposition Empties',
            'description' => 'Create/fill reposition (E) orders for off-home empties.',
            'runnable' => true,
            'dispatch' => 'reposition_empties',
            'params' => [
                ['key' => 'fraction', 'label' => 'Fraction', 'type' => 'number', 'default' => '0.65', 'required' => false, 'min' => 0, 'max' => 1, 'step' => 0.05],
            ],
        ],
        [
            'id' => 'auto_assign_locals',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Auto-Assign Cars',
            'gui_template' => 'Auto-Assign Cars {scope}',
            'description' => 'Auto-assign cars to jobs. Use scope "locals" or a specific job name.',
            'runnable' => true,
            'dispatch' => 'auto_assign_locals',
            'params' => [
                operational_steps_catalog_scope_param(),
            ],
        ],
        [
            'id' => 'assign_cars',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Assign Cars',
            'gui_template' => 'Assign Cars {job} {location}',
            'description' => 'Assign eligible/ordered cars at a location to a job.',
            'runnable' => true,
            'dispatch' => 'assign_cars',
            'params' => [
                operational_steps_catalog_job_param(true),
                operational_steps_catalog_location_param(true),
            ],
        ],
        [
            'id' => 'pick_up_cars',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Pick Up Cars',
            'gui_template' => 'Pick Up Cars {job} {location_suffix}',
            'description' => 'Pick up assigned cars onto a job train.',
            'runnable' => true,
            'dispatch' => 'pick_up_cars',
            'params' => [
                operational_steps_catalog_job_param(true),
                operational_steps_catalog_location_param(false, 'Location (optional)', true),
            ],
        ],
        [
            'id' => 'set_out_cars',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Set Out Cars',
            'gui_template' => 'Set Out Cars {job} {location}',
            'description' => 'Set out cars from a job train at a location or destination.',
            'runnable' => true,
            'dispatch' => 'set_out_cars',
            'params' => [
                operational_steps_catalog_job_param(true),
                [
                    'key' => 'location',
                    'label' => 'Location',
                    'type' => 'setout_location',
                    'options_from' => 'setout_locations',
                    'allow_custom' => true,
                    'required' => true,
                    'default' => '',
                ],
            ],
        ],
        [
            'id' => 'pick_up_locals',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Pick Up Cars (all jobs)',
            'gui_template' => 'Pick Up Cars locals',
            'description' => 'Pick up all assigned local jobs (staging excluded).',
            'runnable' => true,
            'dispatch' => 'pick_up_locals',
            'params' => [],
        ],
        [
            'id' => 'set_out_locals',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Set Out Cars (all jobs)',
            'gui_template' => 'Set Out Cars locals',
            'description' => 'Set out all local jobs per criteria.',
            'runnable' => true,
            'dispatch' => 'set_out_locals',
            'params' => [],
        ],
        [
            'id' => 'load_unload',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'after',
            'label' => 'Load / Unload Cars',
            'gui_template' => 'Load/Unload {location} {car_code} {commodity}',
            'description' => 'Complete offline load/unload transitions. Optional filters narrow scope when supported.',
            'runnable' => true,
            'dispatch' => 'load_unload',
            'params' => [
                operational_steps_catalog_location_param(false, 'Location (optional)', true),
                [
                    'key' => 'car_code',
                    'label' => 'Car type (optional)',
                    'type' => 'car_code',
                    'options_from' => 'car_codes',
                    'allow_custom' => true,
                    'required' => false,
                    'default' => '',
                ],
                [
                    'key' => 'commodity',
                    'label' => 'Commodity (optional)',
                    'type' => 'commodity',
                    'options_from' => 'commodities',
                    'allow_custom' => true,
                    'required' => false,
                    'default' => '',
                ],
            ],
        ],
        [
            'id' => 'track_scale',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Track Scale',
            'gui_template' => 'Weigh Cars {job}',
            'description' => 'Run track scale / weigh operations for a job (job-specific logic if configured).',
            'runnable' => true,
            'dispatch' => 'track_scale',
            'params' => [
                operational_steps_catalog_job_param(false),
            ],
        ],
        [
            'id' => 'weigh_ck1',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Weigh Cars CK1',
            'gui_template' => 'Weigh Cars CK1',
            'description' => 'Track scale weigh, reloads, outbound assignments.',
            'runnable' => true,
            'dispatch' => 'weigh_ck1',
            'params' => [],
        ],
        [
            'id' => 'assign_ck1_reload',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Assign CK1 reload/outbound',
            'gui_template' => 'Assign Cars CK1 reload/outbound',
            'description' => 'Assign reload and outbound coke after weigh.',
            'runnable' => true,
            'dispatch' => 'assign_ck1_reload',
            'params' => [],
        ],
        [
            'id' => 'run_job_criterion',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Run Job Criterion Steps',
            'gui_template' => 'Set Out Cars {job} criterion {steps}',
            'description' => 'Run numbered criterion steps defined on a job.',
            'runnable' => true,
            'dispatch' => 'run_job_criterion',
            'params' => [
                operational_steps_catalog_job_param(true),
                operational_steps_catalog_text_param('steps', 'Criterion step #s', '10,15,20', true, 'Comma-separated'),
            ],
        ],
        [
            'id' => 'run_staging_job',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Run Staging Job',
            'gui_template' => 'Run {job}',
            'description' => 'Complete a staging job cycle (assign, pick up, set out).',
            'runnable' => true,
            'dispatch' => 'staging_job',
            'params' => [
                operational_steps_catalog_job_param(true, 'Staging job'),
            ],
        ],
        [
            'id' => 'defer_staging',
            'category' => 'session',
            'adder' => false,
            'label' => 'Defer Staging Job',
            'gui_template' => 'Defer {job} leave backlog {location}',
            'description' => 'Leave cars eligible for a staging job without running it.',
            'runnable' => false,
            'params' => [
                operational_steps_catalog_job_param(false, 'Job'),
                operational_steps_catalog_location_param(false, 'Location', true),
            ],
        ],
        [
            'id' => 'composite_nvl_pre_ck1',
            'category' => 'operations',
            'adder' => false,
            'label' => 'NVL pre-CK1 (composite)',
            'gui_template' => 'NVL pre-CK1 block',
            'description' => 'Assign/pick Scully, set out Demmler on NVL.',
            'runnable' => true,
            'dispatch' => 'composite_nvl_pre_ck1',
            'params' => [],
        ],
        [
            'id' => 'composite_ck1_session',
            'category' => 'operations',
            'adder' => false,
            'label' => 'CK1 session (composite)',
            'gui_template' => 'CK1 session block',
            'description' => 'Full CK1 weigh cycle (Shenango → scale → setouts).',
            'runnable' => true,
            'dispatch' => 'composite_ck1_session',
            'params' => [],
        ],
        [
            'id' => 'composite_nvl_post_ck1',
            'category' => 'operations',
            'adder' => false,
            'label' => 'NVL post-CK1 (composite)',
            'gui_template' => 'NVL post-CK1 block',
            'description' => 'CK1 handoff, island/Shenango/Demmler/Scully setouts.',
            'runnable' => true,
            'dispatch' => 'composite_nvl_post_ck1',
            'params' => [],
        ],
        [
            'id' => 'composite_d749_session_start',
            'category' => 'operations',
            'adder' => false,
            'label' => 'D749 session start (composite)',
            'gui_template' => 'D749 session start Demmler→South',
            'description' => 'Assign Demmler, pick up, set out South Yard.',
            'runnable' => true,
            'dispatch' => 'composite_d749_session_start',
            'params' => [],
        ],
        [
            'id' => 'composite_d749_phased',
            'category' => 'operations',
            'adder' => false,
            'label' => 'D749 phased ops (composite)',
            'gui_template' => 'D749 phased remainder',
            'description' => 'South/Demmler setouts, island→Demmler, clear train.',
            'runnable' => true,
            'dispatch' => 'composite_d749_phased',
            'params' => [],
        ],
        [
            'id' => 'finish_local_jobs',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Finish Open Jobs',
            'gui_template' => 'Finish open local jobs',
            'description' => 'Mop up non-staging jobs still holding cars.',
            'runnable' => true,
            'dispatch' => 'finish_local_jobs',
            'params' => [],
        ],
        [
            'id' => 'secure_d749_demmler',
            'category' => 'session',
            'adder' => false,
            'label' => 'Secure D749 at Demmler',
            'gui_template' => 'Assign/Pick Up Cars D749 Demmler',
            'description' => 'Bookend: D749 on train with Demmler block.',
            'runnable' => true,
            'dispatch' => 'secure_d749_demmler',
            'params' => [],
        ],
        [
            'id' => 'secure_nvl_scully',
            'category' => 'session',
            'adder' => false,
            'label' => 'Secure NVL at Scully',
            'gui_template' => 'Assign/Pick Up/Set Out Cars NVL Scully',
            'description' => 'Bookend: NVL secured at Scully yard.',
            'runnable' => true,
            'dispatch' => 'secure_nvl_scully',
            'params' => [],
        ],
        [
            'id' => 'generate_switchlists',
            'category' => 'switchlists',
            'adder' => true,
            'adder_group' => 'switchlists',
            'label' => 'Generate Switch Lists',
            'gui_template' => 'Generate Switch Lists {jobs}',
            'description' => 'One phase per command. Job = single train (e.g. D749) or all for D749, NVL, CK1.',
            'runnable' => true,
            'dispatch' => 'generate_switchlists',
            'params' => [
                ['key' => 'format', 'label' => 'Format', 'type' => 'select', 'options' => ['phased', 'halfsheet', 'mobile', 'phased-mobile'], 'default' => 'phased'],
                [
                    'key' => 'jobs',
                    'label' => 'Train(s)',
                    'type' => 'text',
                    'default' => 'all',
                    'required' => false,
                    'placeholder' => 'all, D749, or D749,NVL',
                ],
            ],
        ],
        [
            'id' => 'generate_waybills',
            'category' => 'switchlists',
            'adder' => true,
            'adder_group' => 'switchlists',
            'label' => 'Generate Waybill List',
            'gui_template' => 'Generate Waybill List',
            'description' => 'Build browsable waybill HTML for the current phase.',
            'runnable' => true,
            'dispatch' => 'generate_waybills',
            'params' => [],
        ],
        [
            'id' => 'render_switchlists',
            'category' => 'switchlists',
            'adder' => false,
            'label' => 'Render Switch Lists (cache)',
            'gui_template' => 'Render Switch Lists from cache',
            'description' => 'Re-render HTML from saved phase JSON cache (no DB dry-run).',
            'runnable' => true,
            'dispatch' => 'render_switchlists',
            'params' => [
                ['key' => 'format', 'label' => 'Format', 'type' => 'select', 'options' => ['phased', 'halfsheet', 'mobile'], 'default' => 'phased'],
                ['key' => 'jobs', 'label' => 'Jobs', 'type' => 'text', 'default' => 'D749,NVL,CK1', 'required' => false],
                ['key' => 'session', 'label' => 'Session # (optional)', 'type' => 'text', 'default' => '', 'required' => false],
            ],
        ],
        [
            'id' => 'save_switchlist_cache',
            'category' => 'switchlists',
            'label' => 'Save Switch List Cache',
            'gui_template' => 'Save Switch List Cache',
            'description' => 'Dry-run and save phase JSON cache only (no HTML render).',
            'runnable' => true,
            'dispatch' => 'save_switchlist_cache',
            'params' => [
                ['key' => 'jobs', 'label' => 'Jobs', 'type' => 'text', 'default' => 'D749,NVL,CK1', 'required' => false],
            ],
        ],
        [
            'id' => 'rebuild_switchlists_index',
            'category' => 'switchlists',
            'adder' => false,
            'label' => 'Rebuild Switchlists Index',
            'gui_template' => 'Rebuild Switchlists Index',
            'description' => 'Regenerate switchlists/index.html from session folders.',
            'runnable' => true,
            'dispatch' => 'rebuild_switchlists_index',
            'params' => [],
        ],
        [
            'id' => 'build_switchlists_sts',
            'category' => 'switchlists',
            'adder' => true,
            'adder_group' => 'switchlists',
            'label' => 'Build Switch Lists',
            'gui_template' => 'Build Switch Lists',
            'description' => 'STS Operations → Build Switch Lists for operating jobs.',
            'runnable' => false,
            'gui_path' => '/sts/build_switchlists.php',
            'params' => [],
        ],
        [
            'id' => 'display_switchlists_sts',
            'category' => 'switchlists',
            'adder' => true,
            'adder_group' => 'switchlists',
            'label' => 'Display Switch Lists',
            'gui_template' => 'Display Switch Lists',
            'description' => 'Reports → Switch Lists for current job assignments.',
            'runnable' => false,
            'gui_path' => '/sts/display_switchlist.php',
            'params' => [],
        ],
        [
            'id' => 'organize_cars',
            'category' => 'operations',
            'adder' => true,
            'adder_group' => 'during',
            'label' => 'Organize Cars',
            'gui_template' => 'Organize Cars',
            'description' => 'Reorder cars on a job train. GUI: organize_cars.php.',
            'runnable' => false,
            'gui_path' => '/sts/organize_cars.php',
            'params' => [],
        ],
        [
            'id' => 'track_scale_gui',
            'category' => 'operations',
            'adder' => false,
            'label' => 'Track Scale (STS GUI)',
            'gui_template' => 'Track Scale',
            'description' => 'Weigh cars at track scale. GUI: track_scale.php.',
            'runnable' => false,
            'gui_path' => '/sts/track_scale.php',
            'params' => [],
        ],
        [
            'id' => 'report_station_car',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Station Car Report',
            'gui_template' => 'Station Car Report',
            'description' => 'Cars currently at each station.',
            'runnable' => false,
            'gui_path' => '/sts/display_station_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_wheel',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Wheel Report',
            'gui_template' => 'Wheel Report',
            'description' => 'Car cycle and movement status.',
            'runnable' => false,
            'gui_path' => '/sts/wheel_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_waybill_list',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'waybills',
            'label' => 'Waybill List',
            'gui_template' => 'Waybill List',
            'description' => 'Waybills and fulfillment status.',
            'runnable' => false,
            'gui_path' => '/sts/display_waybill.php',
            'params' => [],
        ],
        [
            'id' => 'report_waybill_cars_print',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'waybills',
            'disabled' => true,
            'label' => 'Waybill Sheets for Cars',
            'gui_template' => 'Waybill Sheets for Cars',
            'description' => 'Printable car-card waybill sheets.',
            'runnable' => false,
            'gui_path' => '/sts/printable_ccwaybill2.php',
            'params' => [],
        ],
        [
            'id' => 'report_waybill_shipments_print',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'waybills',
            'disabled' => true,
            'label' => 'Waybill Sheets for Shipments',
            'gui_template' => 'Waybill Sheets for Shipments',
            'description' => 'Printable shipment waybill sheets.',
            'runnable' => false,
            'gui_path' => '/sts/printable_ccwaybill.php',
            'params' => [],
        ],
        [
            'id' => 'report_fleet',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Car Fleet Report',
            'gui_template' => 'Car Fleet Report',
            'description' => 'Summarize the active car fleet.',
            'runnable' => false,
            'gui_path' => '/sts/display_fleet_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_fleet_print',
            'category' => 'reports',
            'label' => 'Printable Fleet Report',
            'gui_template' => 'Printable Fleet Report',
            'description' => 'Printable fleet summary.',
            'runnable' => false,
            'gui_path' => '/sts/printable_fleet_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_shipment_forecast',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Shipment Forecast',
            'gui_template' => 'Shipment Forecast',
            'description' => 'Forecast upcoming shipment demand.',
            'runnable' => false,
            'gui_path' => '/sts/shipment_forecast.php',
            'params' => [],
        ],
        [
            'id' => 'report_car_forecast',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Car Forecast',
            'gui_template' => 'Car Forecast',
            'description' => 'Forecast car requirements and availability.',
            'runnable' => false,
            'gui_path' => '/sts/car_forecast.php',
            'params' => [],
        ],
        [
            'id' => 'report_car_qr',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Car QR Codes',
            'gui_template' => 'Car QR Codes',
            'description' => 'Printable QR sheets for cars.',
            'runnable' => false,
            'gui_path' => '/sts/display_car_qr_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_car_qr_print',
            'category' => 'reports',
            'label' => 'Printable Car QR Report',
            'gui_template' => 'Printable Car QR Report',
            'description' => 'Printable car QR code sheets.',
            'runnable' => false,
            'gui_path' => '/sts/printable_car_qr_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_location_qr',
            'category' => 'reports',
            'adder' => true,
            'adder_group' => 'reports',
            'label' => 'Location QR Codes',
            'gui_template' => 'Location QR Codes',
            'description' => 'Printable QR sheets for stations and locations.',
            'runnable' => false,
            'gui_path' => '/sts/display_station_qr_code_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_location_qr_print',
            'category' => 'reports',
            'label' => 'Printable Location QR Report',
            'gui_template' => 'Printable Location QR Report',
            'description' => 'Printable location QR code sheets.',
            'runnable' => false,
            'gui_path' => '/sts/printable_station_qr_code_report.php',
            'params' => [],
        ],
        [
            'id' => 'report_station_qr_print',
            'category' => 'reports',
            'label' => 'Printable Station QR Code Report',
            'gui_template' => 'Printable Station QR Code Report',
            'description' => 'Alternate printable station QR layout.',
            'runnable' => false,
            'gui_path' => '/sts/printable_station_qr_code_report.php',
            'params' => [],
        ],
    ];
}

function operational_steps_restore_backup($dbc, $backup_name)
{
    $name = basename((string) $backup_name);
    $path = __DIR__ . '/backups/' . $name;
    if (!is_file($path)) {
        return [false, 'Backup not found: ' . $name];
    }
    $sql = explode('#', file_get_contents($path));
    foreach ($sql as $sql_cmd) {
        if (trim($sql_cmd) === '') {
            continue;
        }
        if (!mysqli_query($dbc, $sql_cmd)) {
            if (stripos($sql_cmd, 'drop') === false) {
                return [false, 'SQL error while restoring: ' . mysqli_error($dbc)];
            }
        }
    }
    return [true, $name . ' restored successfully.'];
}

function operational_steps_catalog_by_id()
{
    $map = [];
    foreach (operational_steps_catalog_definitions() as $def) {
        $map[$def['id']] = $def;
    }
    return $map;
}

function operational_steps_catalog_adder_definitions()
{
    $by_id = operational_steps_catalog_by_id();
    $order = operational_steps_catalog_adder_order();
    $ordered = [];
    foreach ($order as $group => $ids) {
        foreach ($ids as $id) {
            if (!isset($by_id[$id])) {
                continue;
            }
            $def = $by_id[$id];
            if (array_key_exists('adder', $def) && $def['adder'] === false) {
                continue;
            }
            $def['adder_group'] = $def['adder_group'] ?? $group;
            if ($group === 'reports' && !isset($def['disabled'])) {
                $def['disabled'] = true;
            }
            $ordered[] = $def;
        }
    }
    return $ordered;
}

function operational_steps_resolve_location_id($dbc, $location_key)
{
    $location_key = trim((string) $location_key);
    if ($location_key === '') {
        return 0;
    }
    if ($location_key === 'remainder') {
        return 0;
    }
    $id = operational_steps_location_station_id($dbc, $location_key);
    if ($id > 0) {
        return $id;
    }
    $code = strtoupper(str_replace(' ', '-', $location_key));
    return warm_start_location_id_by_code($dbc, $code);
}

function operational_steps_location_station_id($dbc, $location_key)
{
    static $map = [
        'Demmler' => 10,
        'South-Yard' => 8,
        'Scully' => 9,
        'Shenango' => 12,
        'South-Scale' => null,
        'Island' => 3,
    ];
    if ($location_key === 'South-Scale') {
        $id = warm_start_location_id_by_code($dbc, 'SOUTH-SCALE');
        return $id > 0 ? $id : warm_start_location_id_by_code($dbc, 'SOUTH');
    }
    if ($location_key === 'Scully-Offline') {
        return 9;
    }
    if (isset($map[$location_key])) {
        $sid = $map[$location_key];
        return $sid === null ? 0 : (int) $sid;
    }
    return 0;
}

function operational_steps_compile_gui(array $def, array $params)
{
    $template = $def['gui_template'] ?? $def['label'];
    $merged = $params;
    if (($def['id'] ?? '') === 'pick_up_cars' && empty($merged['location'])) {
        $merged['location_suffix'] = '';
    } else {
        $merged['location_suffix'] = !empty($merged['location']) ? $merged['location'] : '';
    }
    if (($def['id'] ?? '') === 'auto_assign_locals') {
        $merged['scope'] = $params['scope'] ?? 'locals';
    }
    if (($def['id'] ?? '') === 'track_scale') {
        $job = trim($params['job'] ?? '');
        $merged['job'] = $job !== '' ? $job : 'train';
    }
    if (($def['id'] ?? '') === 'run_staging_job') {
        $merged['job'] = $params['job'] ?? '';
    }
    if (($def['id'] ?? '') === 'defer_staging') {
        $merged['job'] = $params['job'] ?? '';
    }
    return preg_replace_callback('/\{(\w+)\}/', function ($m) use ($merged) {
        $key = $m[1];
        if (!isset($merged[$key]) || $merged[$key] === '') {
            return '';
        }
        return trim((string) $merged[$key]);
    }, $template);
}

function operational_steps_compile_description(array $def, array $params, $custom = '')
{
    if ($custom !== '') {
        return $custom;
    }
    $base = $def['description'] ?? '';
    if (empty($params)) {
        return $base;
    }
    $parts = [];
    foreach ($params as $k => $v) {
        if ($v === '' || $v === null) {
            continue;
        }
        $parts[] = $k . '=' . $v;
    }
    if (empty($parts)) {
        return $base;
    }
    return $base . ' Params: ' . implode(', ', $parts) . '.';
}

function operational_steps_compile_recipe(array $recipe)
{
    $catalog = operational_steps_catalog_by_id();
    $rows = [];
    foreach ($recipe['steps'] ?? [] as $step) {
        if (!is_array($step)) {
            continue;
        }
        $fid = $step['function'] ?? $step['id'] ?? '';
        if ($fid === '' || !isset($catalog[$fid])) {
            $rows[] = [
                'function' => $fid,
                'instruction' => $step['instruction'] ?? '(unknown)',
                'description' => $step['description'] ?? '',
                'params' => $step['params'] ?? [],
            ];
            continue;
        }
        $def = $catalog[$fid];
        $params = is_array($step['params'] ?? null) ? $step['params'] : [];
        $rows[] = [
            'function' => $fid,
            'instruction' => operational_steps_compile_gui($def, $params),
            'description' => operational_steps_compile_description($def, $params, $step['description'] ?? ''),
            'params' => $params,
        ];
    }
    return $rows;
}

function operational_steps_recipe_to_csv(array $recipe)
{
    $compiled = operational_steps_compile_recipe($recipe);
    $lines = ['Step #,STS GUI Instruction,Full Description'];
    $n = 0;
    foreach ($compiled as $row) {
        $n++;
        $lines[] = operational_steps_csv_escape((string) $n)
            . ',' . operational_steps_csv_escape($row['instruction'])
            . ',' . operational_steps_csv_escape($row['description']);
    }
    return implode("\n", $lines) . "\n";
}

function operational_steps_csv_escape($value)
{
    $value = str_replace(["\r\n", "\r", "\n"], ' ', (string) $value);
    if (preg_match('/[",\n\r]/', $value)) {
        return '"' . str_replace('"', '""', $value) . '"';
    }
    return $value;
}

function operational_steps_parse_csv($text)
{
    $rows = [];
    $parsed = [];
    $i = 0;
    $field = '';
    $row = [];
    $inQuotes = false;
    $len = strlen($text);
    while ($i < $len) {
        $c = $text[$i];
        if ($inQuotes) {
            if ($c === '"') {
                if ($i + 1 < $len && $text[$i + 1] === '"') {
                    $field .= '"';
                    $i += 2;
                    continue;
                }
                $inQuotes = false;
                $i++;
                continue;
            }
            $field .= $c;
            $i++;
            continue;
        }
        if ($c === '"') {
            $inQuotes = true;
            $i++;
            continue;
        }
        if ($c === ',') {
            $row[] = $field;
            $field = '';
            $i++;
            continue;
        }
        if ($c === "\r") {
            $i++;
            continue;
        }
        if ($c === "\n") {
            $row[] = $field;
            $field = '';
            if (count($row) > 1 || $row[0] !== '') {
                $parsed[] = $row;
            }
            $row = [];
            $i++;
            continue;
        }
        $field .= $c;
        $i++;
    }
    $row[] = $field;
    if (count($row) > 1 || $row[0] !== '') {
        $parsed[] = $row;
    }
    if (count($parsed) < 2) {
        return [];
    }
    for ($r = 1; $r < count($parsed); $r++) {
        $cols = $parsed[$r];
        $instruction = $cols[1] ?? '';
        $description = $cols[2] ?? '';
        $rows[] = [
            'function' => operational_steps_guess_function($instruction),
            'params' => operational_steps_guess_params($instruction),
            'instruction' => $instruction,
            'description' => $description,
        ];
    }
    $steps = array_map('operational_steps_normalize_step', $rows);
    return $steps;
}

function operational_steps_guess_function($instruction)
{
    $s = trim($instruction);
    if ($s === '') {
        return 'marker';
    }
    if (stripos($s, '[Setup once]') !== false || stripos($s, 'Restore Database') !== false) {
        return 'restore_database';
    }
    if (stripos($s, 'repeat steps') !== false && stripos($s, 'Assign Cars') === false && stripos($s, 'Warm start') !== false) {
        return 'marker';
    }
    if (preg_match('/^\[[^\]]+\]\s*$/', $s)) {
        return 'marker';
    }
    if (preg_match('/^\[(Warm start|Each operating session|Setup once|Session end)/i', $s) && stripos($s, 'Assign Cars') === false && stripos($s, 'Run STG') === false) {
        return 'marker';
    }
    if (stripos($s, 'Warm start end') !== false || (stripos($s, 'Session end') !== false && stripos($s, 'Defer') !== false)) {
        return 'defer_staging';
    }
    if (stripos($s, 'Warm start end') !== false || stripos($s, 'Session end') !== false) {
        return 'defer_stg_scully';
    }
    if (stripos($s, 'Generate Switch Lists') !== false) {
        return 'generate_switchlists';
    }
    if (stripos($s, 'Increment Session') !== false) {
        return 'increment_session';
    }
    if (stripos($s, 'Generate Orders') !== false) {
        return 'generate_orders';
    }
    if (stripos($s, 'Fill Orders') !== false) {
        return 'fill_orders';
    }
    if (stripos($s, 'Reposition Empties') !== false) {
        return 'reposition_empties';
    }
    if (stripos($s, 'Auto-Assign') !== false) {
        return 'auto_assign_locals';
    }
    if (stripos($s, 'Load/Unload') !== false) {
        return 'load_unload';
    }
    if (stripos($s, 'Weigh Cars CK1') !== false) {
        return 'weigh_ck1';
    }
    if (stripos($s, 'reload/outbound') !== false) {
        return 'assign_ck1_reload';
    }
    if (stripos($s, 'Run STG-DEMMLER') !== false) {
        return 'run_stg_demmler';
    }
    if (stripos($s, 'Run STG-SCULLY') !== false) {
        return stripos($s, 'Defer') !== false ? 'defer_stg_scully' : 'run_stg_scully';
    }
    if (stripos($s, 'Defer') !== false && stripos($s, 'backlog') !== false) {
        return 'defer_stg_scully';
    }
    if (preg_match('/^Run (\S+)/i', $s)) {
        return 'run_staging_job';
    }
    if (stripos($s, 'Finish open local') !== false) {
        return 'finish_local_jobs';
    }
    if (stripos($s, 'NVL pre-CK1') !== false) {
        return 'composite_nvl_pre_ck1';
    }
    if (stripos($s, 'CK1 session') !== false) {
        return 'composite_ck1_session';
    }
    if (stripos($s, 'NVL post-CK1') !== false) {
        return 'composite_nvl_post_ck1';
    }
    if (stripos($s, 'D749 session start') !== false) {
        return 'composite_d749_session_start';
    }
    if (stripos($s, 'D749 phased') !== false) {
        return 'composite_d749_phased';
    }
    if (preg_match('/Assign.*D749.*Demmler/i', $s) && preg_match('/Pick Up/i', $s)) {
        return 'secure_d749_demmler';
    }
    if (preg_match('/Assign.*NVL.*Scully/i', $s) && preg_match('/Set Out/i', $s)) {
        return 'secure_nvl_scully';
    }
    if (preg_match('/Assign Cars/i', $s, $m)) {
        return 'assign_cars';
    }
    if (stripos($s, 'Pick Up Cars locals') !== false) {
        return 'pick_up_locals';
    }
    if (stripos($s, 'Set Out Cars locals') !== false) {
        return 'set_out_locals';
    }
    if (stripos($s, 'Pick Up Cars') !== false) {
        return 'pick_up_cars';
    }
    if (stripos($s, 'Set Out Cars') !== false) {
        return 'set_out_cars';
    }
    if (stripos($s, 'criterion') !== false) {
        return 'run_job_criterion';
    }
    return 'marker';
}

function operational_steps_guess_params($instruction)
{
    $params = [];
    $s = trim($instruction);

    if (preg_match('/Restore Database (\S+)/i', $s, $m)) {
        $params['backup'] = $m[1];
    }
    if (preg_match('/^Run (\S+(?:-\S+)?)/i', $s, $m)) {
        $params['job'] = $m[1];
    }
    if (preg_match('/Assign Cars (\S+(?:-\S+)?)\s+(.+)$/i', $s, $m)) {
        $params['job'] = trim($m[1]);
        $params['location'] = trim(preg_replace('/^\[.+?\]\s*/', '', $m[2]));
    } elseif (preg_match('/Assign Cars (\S+(?:-\S+)?)/i', $s, $m)) {
        $params['job'] = $m[1];
    }
    if (preg_match('/Pick Up Cars (\S+(?:-\S+)?)(?:\s+(.+))?$/i', $s, $m)) {
        $params['job'] = trim($m[1]);
        if (!empty(trim($m[2] ?? ''))) {
            $params['location'] = trim($m[2]);
        }
    }
    if (preg_match('/Set Out Cars (\S+(?:-\S+)?)\s+(.+)$/i', $s, $m)) {
        $params['job'] = trim($m[1]);
        $params['location'] = trim($m[2]);
    }
    if (preg_match('/Defer (\S+(?:-\S+)?)(?:\s+leave backlog\s+(.+))?/i', $s, $m)) {
        $params['job'] = trim($m[1]);
        if (!empty(trim($m[2] ?? ''))) {
            $params['location'] = trim($m[2]);
        }
    }
    if (preg_match('/criterion\s+([\d,\s]+)/i', $s, $m)) {
        $params['steps'] = preg_replace('/\s+/', '', $m[1]);
    }
    if (preg_match('/(Demmler|South-Yard|Scully-Offline|Scully|Shenango|South-Scale|Island|CK1-handoff)/i', $s, $m)
        && empty($params['location'])) {
        $params['location'] = $m[1];
    }
    if (preg_match('/^\[(.+)\]$/', $s) || (preg_match('/^\[/', $s) && stripos($s, 'Assign Cars') === false && stripos($s, 'Restore Database') === false)) {
        $params['note'] = $s;
    }
    if (stripos($s, 'locals') !== false && stripos($s, 'Auto-Assign') !== false) {
        $params['scope'] = 'locals';
    }
    if (stripos($s, 'Weigh Cars') !== false && preg_match('/Weigh Cars (\S+)/i', $s, $m)) {
        $params['job'] = $m[1];
    }
    return $params;
}

function operational_steps_normalize_step(array $step)
{
    $catalog = operational_steps_catalog_by_id();
    $fid = $step['function'] ?? '';
    $instruction = trim($step['instruction'] ?? '');
    $description = trim($step['description'] ?? '');

    if ($fid === '' || $fid === 'marker' || $fid === 'section_label' || !isset($catalog[$fid])) {
        if ($instruction !== '') {
            $fid = operational_steps_guess_function($instruction);
        }
    }
    if ($fid === 'marker') {
        if (empty($step['params']['label']) && !empty($step['params']['note'])) {
            $step['params']['label'] = $step['params']['note'];
        }
        $fid = 'section_label';
    }

    if ($fid === 'restore_database' && empty($step['params']['backup'])) {
        $step['params']['backup'] = 'hart_seed';
    }
    if ($fid === 'defer_stg_scully') {
        $fid = 'defer_staging';
        if (empty($step['params']['job'])) {
            $step['params']['job'] = 'STG-SCULLY';
        }
        if (empty($step['params']['location'])) {
            $step['params']['location'] = 'Scully';
        }
    }
    if ($fid === 'run_stg_scully' || $fid === 'run_stg_demmler') {
        if ($fid === 'run_stg_demmler') {
            $step['params']['job'] = 'STG-DEMMLER';
        } elseif (empty($step['params']['job'])) {
            $step['params']['job'] = 'STG-SCULLY';
        }
        $fid = 'run_staging_job';
    }
    if ($fid === 'weigh_ck1') {
        $fid = 'track_scale';
        $step['params']['job'] = 'CK1';
    }
    if (in_array($fid, ['secure_d749_demmler', 'secure_nvl_scully'], true)) {
        // Keep composite ids for legacy dispatch; params filled from instruction if missing
    }

    $params = is_array($step['params'] ?? null) ? $step['params'] : [];
    $guessed = $instruction !== '' ? operational_steps_guess_params($instruction) : [];
    foreach ($guessed as $k => $v) {
        if ($v !== '' && (empty($params[$k]) || $params[$k] === 'note')) {
            $params[$k] = $v;
        }
    }

    if (isset($catalog[$fid])) {
        $allowed = [];
        foreach ($catalog[$fid]['params'] ?? [] as $pdef) {
            if (!empty($pdef['key'])) {
                $allowed[$pdef['key']] = true;
            }
        }
        foreach (array_keys($params) as $key) {
            if (!isset($allowed[$key])) {
                unset($params[$key]);
            }
        }
        foreach ($catalog[$fid]['params'] ?? [] as $pdef) {
            $key = $pdef['key'] ?? '';
            if ($key === '' || isset($params[$key])) {
                continue;
            }
            if (isset($pdef['default']) && $pdef['default'] !== '') {
                $params[$key] = $pdef['default'];
            }
        }
    }

    $normalized = [
        'function' => $fid,
        'params' => $params,
    ];
    if ($description !== '') {
        $normalized['description'] = $description;
    }
    if ($instruction !== '' && ($normalized['function'] ?? '') === 'marker') {
        $normalized['params']['note'] = $instruction;
    }
    return $normalized;
}

function operational_steps_normalize_recipe(array $recipe)
{
    $steps = [];
    foreach ($recipe['steps'] ?? [] as $step) {
        if (!is_array($step)) {
            continue;
        }
        $steps[] = operational_steps_normalize_step($step);
    }
    $recipe['steps'] = $steps;
    if (!isset($recipe['version'])) {
        $recipe['version'] = 1;
    }
    return $recipe;
}

function operational_steps_default_recipe_from_csv_file($path)
{
    if (!is_file($path)) {
        return ['version' => 1, 'name' => 'default', 'steps' => []];
    }
    $text = file_get_contents($path);
    $steps = operational_steps_parse_csv($text);
    return operational_steps_normalize_recipe(['version' => 1, 'name' => 'imported', 'steps' => $steps]);
}

function operational_steps_recipe_paths($switchlists_dir)
{
    return [
        'recipe' => rtrim($switchlists_dir, '/') . '/STS_OPERATIONAL_RECIPE.json',
        'csv' => rtrim($switchlists_dir, '/') . '/STS_OPERATIONAL_STEPS.csv',
    ];
}

function operational_steps_load_recipe($switchlists_dir)
{
    $paths = operational_steps_recipe_paths($switchlists_dir);
    if (is_file($paths['recipe'])) {
        $data = json_decode(file_get_contents($paths['recipe']), true);
        if (is_array($data) && isset($data['steps'])) {
            return operational_steps_normalize_recipe($data);
        }
    }
    $backup = dirname(__DIR__) . '/sts/backups/STS_OPERATIONAL_RECIPE.json';
    if (is_file($backup)) {
        $data = json_decode(file_get_contents($backup), true);
        if (is_array($data) && isset($data['steps'])) {
            return $data;
        }
    }
    if (is_file($paths['csv'])) {
        return operational_steps_default_recipe_from_csv_file($paths['csv']);
    }
    $docs = dirname(__DIR__) . '/docs/STS_OPERATIONAL_STEPS.csv';
    if (is_file($docs)) {
        return operational_steps_default_recipe_from_csv_file($docs);
    }
    return ['version' => 1, 'name' => 'empty', 'steps' => []];
}

function operational_steps_save_recipe($switchlists_dir, array $recipe)
{
    $paths = operational_steps_recipe_paths($switchlists_dir);
    $backup_dir = dirname(__DIR__) . '/sts/backups';
    $json = json_encode($recipe, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
    $csv = operational_steps_recipe_to_csv($recipe);
    $written = [];
    $errors = [];
    foreach ([
        'recipe_switchlists' => $paths['recipe'],
        'csv_switchlists' => $paths['csv'],
        'recipe_backups' => $backup_dir . '/STS_OPERATIONAL_RECIPE.json',
        'csv_backups' => $backup_dir . '/STS_OPERATIONAL_STEPS.csv',
    ] as $label => $path) {
        $dir = dirname($path);
        if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
            $errors[] = "mkdir failed: {$dir}";
            continue;
        }
        $body = strpos($label, 'recipe') !== false ? $json : $csv;
        if (@file_put_contents($path, $body) === false) {
            $errors[] = "write failed: {$path}";
            continue;
        }
        $written[$label] = $path;
    }
    return ['written' => $written, 'errors' => $errors, 'compiled' => operational_steps_compile_recipe($recipe)];
}

function operational_steps_dispatch_step($dbc, array $step, array $config = [])
{
    $catalog = operational_steps_catalog_by_id();
    $fid = $step['function'] ?? '';
    if ($fid === '' || !isset($catalog[$fid])) {
        return ['skipped' => true, 'reason' => 'unknown function'];
    }
    $def = $catalog[$fid];
    if (empty($def['runnable'])) {
        return ['skipped' => true, 'reason' => 'not runnable'];
    }
    $params = is_array($step['params'] ?? null) ? $step['params'] : [];
    $dispatch = $def['dispatch'] ?? $fid;
    $fractions = warm_start_default_fractions($config);
    $result = ['function' => $fid, 'dispatch' => $dispatch];

    switch ($dispatch) {
        case 'staging_job':
            $job = trim($params['job'] ?? $def['dispatch_job'] ?? 'STG-SCULLY');
            if ($job === '') {
                $job = 'STG-SCULLY';
            }
            $stats = warm_start_complete_staging_jobs($dbc, [$job], $config, 1.0);
            $result['stats'] = $stats;
            $result['job'] = $job;
            break;
        case 'generate_orders':
            $shipment = trim($params['shipment'] ?? '');
            if ($shipment !== '') {
                require_once __DIR__ . '/session_helpers.php';
                $result = array_merge($result, session_manual_generate_shipment($dbc, $shipment));
            } else {
                $session = warm_start_get_session($dbc);
                $counter = warm_start_get_next_auto_waybill_counter($dbc, $session);
                $result['generated'] = warm_start_generate_orders($dbc, $session, $counter);
            }
            break;
        case 'increment_session':
            $prev = warm_start_get_session($dbc);
            $result['session'] = warm_start_set_session($dbc, $prev + 1);
            break;
        case 'fill_orders':
            $frac = (float) ($params['fraction'] ?? 1.0);
            $result['filled'] = warm_start_auto_fill($dbc, $frac);
            break;
        case 'reposition_empties':
            $frac = (float) ($params['fraction'] ?? ($config['reposition_fraction'] ?? 0.65));
            $result['repositioned'] = warm_start_create_reposition_orders($dbc, $frac);
            break;
        case 'auto_assign_locals':
            $staging = warm_start_staging_job_names($dbc, $config);
            $scope = $params['scope'] ?? 'locals';
            if ($scope === 'locals') {
                $result['assigned'] = warm_start_auto_assign_all($dbc, 1.0, $staging, true);
            } else {
                $ids = array_keys(auto_assign_eligible_car_ids_for_job($dbc, $scope, true));
                $result['assigned'] = warm_start_assign_cars_to_job($dbc, $scope, $ids);
            }
            break;
        case 'assign_cars':
            $job = $params['job'] ?? 'D749';
            $station = operational_steps_location_station_id($dbc, $params['location'] ?? 'Demmler');
            if ($station > 0) {
                $result['assigned'] = warm_start_assign_all_ordered_cars_at_station($dbc, $job, $station);
            }
            break;
        case 'pick_up_cars':
            $job = $params['job'] ?? 'D749';
            $station = operational_steps_location_station_id($dbc, $params['location'] ?? '');
            if ($station > 0) {
                $result['picked_up'] = warm_start_pickup_job_at_station($dbc, $job, $station);
            } else {
                $result['picked_up'] = warm_start_pickup_job($dbc, $job);
            }
            break;
        case 'set_out_cars':
            $job = $params['job'] ?? 'D749';
            $loc = $params['location'] ?? 'South-Yard';
            if ($loc === 'remainder') {
                $result['set_out'] = warm_start_setout_all_job_train($dbc, $job);
            } elseif ($loc === 'Demmler/Scully') {
                $result['set_out'] = warm_start_setout_job_cars_for_destinations($dbc, $job, [10, 14])
                    + warm_start_setout_job_cars_for_destinations($dbc, $job, [9, 15]);
            } elseif ($loc === 'Island/Shenango') {
                $result['set_out'] = warm_start_setout_job_cars_for_destinations($dbc, $job, [3, 12]);
            } else {
                $loc_id = operational_steps_resolve_location_id($dbc, $loc);
                if ($loc_id > 0) {
                    $result['set_out'] = warm_start_setout_job_at_location($dbc, $job, $loc_id);
                }
            }
            break;
        case 'track_scale':
            $job = strtoupper(trim($params['job'] ?? ''));
            if ($job === '' || $job === 'CK1') {
                $result['weigh'] = warm_start_run_ck1_scale_ops($dbc);
            } else {
                $result['skipped'] = true;
                $result['reason'] = 'No track-scale handler for job ' . $job;
            }
            break;
        case 'pick_up_locals':
            $staging = warm_start_staging_job_names($dbc, $config);
            $result['picked_up'] = warm_start_pickup_cars($dbc, 1.0, $staging, true);
            break;
        case 'set_out_locals':
            $staging = warm_start_staging_job_names($dbc, $config);
            $result['set_out'] = warm_start_setout_cars($dbc, 1.0, $staging, true);
            break;
        case 'load_unload':
            $result['load_unload'] = warm_start_load_unload($dbc, 1.0);
            $result['filters'] = array_filter([
                'location' => $params['location'] ?? '',
                'car_code' => $params['car_code'] ?? '',
                'commodity' => $params['commodity'] ?? '',
            ]);
            break;
        case 'weigh_ck1':
            $result['weigh'] = warm_start_run_ck1_scale_ops($dbc);
            break;
        case 'assign_ck1_reload':
            $result['assigned'] = warm_start_ck1_assign_reload_cars_on_train($dbc)
                + warm_start_ck1_assign_reload_at_south($dbc)
                + warm_start_ck1_assign_outbound_at_south($dbc);
            break;
        case 'run_job_criterion':
            $job = $params['job'] ?? 'D749';
            $steps = array_map('intval', array_filter(array_map('trim', explode(',', $params['steps'] ?? ''))));
            $moves = 0;
            foreach ($steps as $step_nbr) {
                $move = warm_start_run_job_criterion($dbc, $job, $step_nbr);
                $moves += (int) ($move['set_out'] ?? 0) + (int) ($move['picked_up'] ?? 0);
            }
            $result['moves'] = $moves;
            break;
        case 'composite_nvl_pre_ck1':
            $result['stats'] = warm_start_run_nvl_pre_ck1($dbc);
            break;
        case 'composite_ck1_session':
            $result['stats'] = warm_start_run_ck1_session_ops($dbc, $config);
            break;
        case 'composite_nvl_post_ck1':
            $result['stats'] = warm_start_run_nvl_post_ck1($dbc);
            break;
        case 'composite_d749_session_start':
            $result['stats'] = warm_start_run_d749_session_start($dbc);
            break;
        case 'composite_d749_phased':
            $result['stats'] = warm_start_run_d749_phased_ops($dbc);
            break;
        case 'finish_local_jobs':
            warm_start_finish_non_staging_jobs($dbc, $config, $fractions);
            $result['finished'] = true;
            break;
        case 'secure_d749_demmler':
            warm_start_assign_all_ordered_cars_at_station($dbc, 'D749', 10);
            $result['picked_up'] = warm_start_pickup_job_at_station($dbc, 'D749', 10);
            break;
        case 'secure_nvl_scully':
            warm_start_assign_eligible_at_pickup_station($dbc, 'NVL', 9);
            warm_start_pickup_job_at_station($dbc, 'NVL', 9);
            $scl = warm_start_location_id_by_code($dbc, 'SCL');
            $result['set_out'] = $scl > 0 ? warm_start_setout_job_at_location($dbc, 'NVL', $scl) : 0;
            break;
        case 'generate_switchlists':
            require_once __DIR__ . '/session_helpers.php';
            require_once __DIR__ . '/master_switchlist_helpers.php';
            $format = $params['format'] ?? 'phased';
            $jobs = session_resolve_jobs_param($params['jobs'] ?? 'all');
            $session = master_sw_get_setting($dbc, 'session_nbr');
            $root = $config['session_root'] ?? session_web_root();
            $manifest = session_load_manifest($session, $root);
            $phase_num = (int) ($config['phase'] ?? 0);
            if ($phase_num < 1) {
                $phase_num = count($manifest['phases'] ?? []) + 1;
            }
            $phase_dir = session_phase_output_dir($session, $phase_num, $root);
            $result['switchlists'] = master_sw_generate_for_jobs($dbc, $jobs, $phase_dir, $config, [
                'format' => $format,
            ]);
            session_register_phase($manifest, $phase_num, [
                'jobs' => $jobs,
                'format' => $format,
                'output' => $phase_dir,
            ]);
            session_save_manifest($session, $manifest, $root);
            $result['phase'] = $phase_num;
            $result['output'] = $phase_dir;
            break;
        case 'generate_waybills':
            require_once __DIR__ . '/session_helpers.php';
            $session = warm_start_get_session($dbc);
            $root = $config['session_root'] ?? session_web_root();
            $phase_num = (int) ($config['phase'] ?? 0);
            if ($phase_num < 1) {
                $manifest = session_load_manifest($session, $root);
                $phase_num = max(1, count($manifest['phases'] ?? []));
            }
            $result['waybills'] = session_generate_waybills_for_phase($dbc, $session, $phase_num, $root);
            break;
        case 'render_switchlists':
            require_once __DIR__ . '/session_helpers.php';
            require_once __DIR__ . '/master_switchlist_helpers.php';
            $format = $params['format'] ?? 'phased';
            $jobs = array_values(array_filter(array_map('trim', explode(',', $params['jobs'] ?? 'D749,NVL,CK1'))));
            $session = trim($params['session'] ?? '') !== ''
                ? trim($params['session'])
                : master_sw_get_setting($dbc, 'session_nbr');
            $out = session_web_root() . '/session_' . $session;
            $result['switchlists'] = master_sw_generate_for_jobs($dbc, $jobs, $out, $config, [
                'format' => $format,
                'render_only' => true,
                'session_override' => $session,
            ]);
            master_sw_render_switchlists_root_index(session_web_root(), $session);
            break;
        case 'save_switchlist_cache':
            require_once __DIR__ . '/master_switchlist_helpers.php';
            $jobs = array_values(array_filter(array_map('trim', explode(',', $params['jobs'] ?? 'D749,NVL,CK1'))));
            $session = master_sw_get_setting($dbc, 'session_nbr');
            $out = session_web_root() . '/session_' . $session;
            $result['switchlists'] = master_sw_generate_for_jobs($dbc, $jobs, $out, $config, [
                'save_cache_only' => true,
            ]);
            break;
        case 'rebuild_switchlists_index':
            require_once __DIR__ . '/session_helpers.php';
            require_once __DIR__ . '/master_switchlist_helpers.php';
            $session = master_sw_get_setting($dbc, 'session_nbr');
            $result['index'] = master_sw_render_switchlists_root_index(session_web_root(), $session);
            break;
        case 'backup_database':
            $name = preg_replace('/[^a-zA-Z0-9_-]/', '', $params['backup'] ?? 'manual_backup');
            if ($name === '') {
                return ['skipped' => true, 'reason' => 'invalid backup name'];
            }
            $result['path'] = warm_start_backup($dbc, $name);
            break;
        case 'restore_database':
            $name = basename($params['backup'] ?? 'hart_seed');
            list($ok, $msg) = operational_steps_restore_backup($dbc, $name);
            $result['restored'] = $ok;
            $result['message'] = $msg;
            if (!$ok) {
                return ['error' => $msg, 'function' => $fid];
            }
            break;
        case 'warm_start_tracked':
            $overrides = warm_start_tracked_sim_overrides([
                'min_sessions' => (int) ($params['min_sessions'] ?? 3),
                'max_sessions' => (int) ($params['max_sessions'] ?? 12),
            ]);
            $result['summary'] = warm_start_run($dbc, warm_start_merge_config($overrides));
            break;
        case 'begin_operating_session':
            $result['begin'] = warm_start_begin_operating_session($dbc, [
                'run_stg_scully' => ($params['run_stg_scully'] ?? 'yes') !== 'no',
                'config' => $config,
            ]);
            break;
        case 'play_operating_session':
            $result['play'] = warm_start_play_operating_session($dbc, $config);
            break;
        case 'evaluate_session_prep':
            $result['evaluation'] = warm_start_evaluate_session_prep($dbc, $config);
            break;
        default:
            return ['skipped' => true, 'reason' => 'no handler'];
    }
    return $result;
}

function operational_steps_recipe_indices(array $recipe)
{
    $steps = $recipe['steps'] ?? [];
    $total = count($steps);
    $indices = [
        'total' => $total,
        'operating_start' => null,
        'generate_step' => null,
        'session_end' => null,
        'breakpoints' => [],
    ];
    foreach ($steps as $i => $step) {
        $n = $i + 1;
        $fid = $step['function'] ?? '';
        $instr = $step['instruction'] ?? '';
        if (stripos($instr, 'Each operating session') !== false) {
            $indices['operating_start'] = $n;
        }
        if ($indices['operating_start'] === null) {
            $desc = $step['description'] ?? '';
            if (stripos($desc, 'Begin session') !== false || stripos($instr, 'Begin session') !== false) {
                $indices['operating_start'] = $n;
            } elseif ($fid === 'assign_cars'
                && stripos($instr, 'STG-SCULLY') !== false
                && $n >= 40) {
                $indices['operating_start'] = $n;
            }
        }
        if ($fid === 'generate_switchlists') {
            $indices['generate_step'] = $n;
            $indices['breakpoints'][] = [
                'step' => $n,
                'label' => 'Generate Switch Lists (capture)',
                'function' => $fid,
            ];
        } elseif ($fid !== 'section_label' && $fid !== 'marker' && $fid !== 'restore_database') {
            $compiled = operational_steps_compile_recipe(['steps' => [$step]]);
            $label = $compiled[0]['instruction'] ?? $fid;
            $indices['breakpoints'][] = [
                'step' => $n,
                'label' => $label,
                'function' => $fid,
            ];
        }
        if ($fid === 'defer_stg_scully' && stripos($instr, 'Session end') !== false) {
            $indices['session_end'] = $n;
        }
    }
    if ($indices['operating_start'] === null) {
        $indices['operating_start'] = 42;
    }
    if ($indices['generate_step'] === null) {
        $indices['generate_step'] = 50;
    }
    if ($indices['session_end'] === null) {
        $indices['session_end'] = $total;
    }
    return $indices;
}

function operational_steps_run_recipe_steps($dbc, array $recipe, $from_step, $to_step, array $config = [])
{
    $steps = $recipe['steps'] ?? [];
    $from = max(1, (int) $from_step);
    $to = min(count($steps), (int) $to_step);
    $log = [];
    for ($n = $from; $n <= $to; $n++) {
        $step = $steps[$n - 1] ?? null;
        if (!is_array($step)) {
            continue;
        }
        $fid = $step['function'] ?? '';
        if (in_array($fid, ['generate_switchlists', 'section_label', 'marker', 'stop', 'goto', 'if_then', 'generate_waybills'], true)) {
            continue;
        }
        $log[] = array_merge(
            ['step' => $n],
            operational_steps_dispatch_step($dbc, $step, $config)
        );
    }
    return $log;
}

function operational_steps_discover_switchlist_sessions($session_root = null)
{
    require_once __DIR__ . '/session_helpers.php';
    if ($session_root === null) {
        $session_root = session_web_root();
    }
    require_once __DIR__ . '/master_switchlist_helpers.php';
    $dirs = master_sw_discover_session_dirs($session_root);
    $sessions = [];
    foreach ($dirs as $entry) {
        $sessions[] = (int) $entry['number'];
    }
    sort($sessions);
    return $sessions;
}

function operational_steps_run_switchlists_web($dbc, $format = 'phased', array $jobs = ['D749', 'NVL', 'CK1'], array $options = [])
{
    require_once __DIR__ . '/session_helpers.php';
    require_once __DIR__ . '/master_switchlist_helpers.php';
    $config = warm_start_merge_config($options['config'] ?? []);
    $session = isset($options['session_override']) && $options['session_override'] !== ''
        ? (string) $options['session_override']
        : master_sw_get_setting($dbc, 'session_nbr');
    $root = session_web_root();
    $manifest = session_load_manifest($session, $root);
    $phase_num = count($manifest['phases'] ?? []) + 1;
    $out = session_phase_output_dir($session, $phase_num, $root);
    $gen_opts = [
        'format' => $format,
        'session_override' => $session,
    ];
    if (!empty($options['render_only'])) {
        $gen_opts['render_only'] = true;
    }
    $written = master_sw_generate_for_jobs($dbc, $jobs, $out, $config, $gen_opts);
    session_register_phase($manifest, $phase_num, ['jobs' => $jobs, 'format' => $format, 'output' => $out]);
    session_save_manifest($session, $manifest, $root);
    return [
        'session' => $session,
        'phase' => $phase_num,
        'written' => $written,
        'output' => $out,
    ];
}

function operational_steps_run_generator_web($dbc, array $options = [])
{
    require_once __DIR__ . '/session_helpers.php';
    $recipe = $options['recipe'] ?? ['steps' => []];
    $format = $options['format'] ?? 'phased';
    $jobs = $options['jobs'] ?? ['D749', 'NVL', 'CK1'];
    $mode = $options['mode'] ?? 'current';
    $breakpoint = (int) ($options['breakpoint_step'] ?? 0);
    $session_count = max(1, (int) ($options['session_count'] ?? 1));
    $run_prep = array_key_exists('run_prep', $options) ? (bool) $options['run_prep'] : true;
    $play_after = !array_key_exists('play_after', $options) || (bool) $options['play_after'];
    $render_sessions = $options['render_sessions'] ?? [];
    $config = warm_start_merge_config($options['config'] ?? []);
    $config['session_root'] = session_web_root();
    $indices = operational_steps_recipe_indices($recipe);
    $total_steps = count($recipe['steps'] ?? []);

    if ($breakpoint <= 0) {
        $breakpoint = (int) ($indices['session_end'] ?: $total_steps);
    }

    $start_step = (int) ($options['start_step'] ?? 0);
    $stop_step = (int) ($options['stop_step'] ?? 0);
    if ($stop_step <= 0) {
        $stop_step = $breakpoint;
    }
    if ($start_step <= 0) {
        $start_step = (int) ($indices['operating_start'] ?: 1);
    }
    $from_step = max(1, min($start_step, $total_steps));
    $to_step = max($from_step, min($stop_step, $total_steps));
    $breakpoint = $to_step;

    $cycles = [];
    $warnings = [];

    if ($mode === 'rerender' && count($render_sessions) > 0) {
        foreach ($render_sessions as $sess) {
            $sess = (int) $sess;
            if ($sess <= 0) {
                continue;
            }
            $manifest = session_load_manifest($sess, session_web_root());
            foreach ($manifest['phases'] ?? [] as $phase) {
                $phase_jobs = $phase['jobs'] ?? $jobs;
                $gen = operational_steps_run_switchlists_web($dbc, $phase['format'] ?? $format, $phase_jobs, [
                    'render_only' => true,
                    'session_override' => (string) $sess,
                    'config' => $config,
                ]);
                $cycles[] = [
                    'cycle' => count($cycles) + 1,
                    'session' => $gen['session'],
                    'mode' => 'rerender',
                    'phase' => $gen['phase'] ?? null,
                    'written' => $gen['written'],
                ];
            }
        }
        return [
            'mode' => 'rerender',
            'breakpoint_step' => $breakpoint,
            'cycles' => $cycles,
            'warnings' => $warnings,
            'sessions' => array_values(array_unique(array_column($cycles, 'session'))),
        ];
    }

    $op_start = (int) $indices['operating_start'];
    $session_end = (int) $indices['session_end'];
    $loops = max(1, $session_count);
    if ($mode === 'current' && $loops > 1) {
        $mode = 'simulate';
    }

    for ($cycle = 0; $cycle < $loops; $cycle++) {
        if ($mode === 'simulate' && $cycle > 0) {
            $warnings[] = 'Cycle ' . ($cycle + 1) . ': steps ' . $from_step . '–' . $to_step . '.';
        }

        $run_result = session_run_recipe($dbc, $recipe, [
            'from_step' => $from_step,
            'to_step' => $to_step,
            'format' => $format,
            'config' => $config,
        ]);

        $written = [];
        foreach ($run_result['log'] ?? [] as $entry) {
            if (!empty($entry['written']) && is_array($entry['written'])) {
                $written = array_merge($written, $entry['written']);
            }
        }

        $cycle_result = [
            'cycle' => $cycle + 1,
            'session' => $run_result['session'],
            'mode' => $mode,
            'breakpoint_step' => $breakpoint,
            'start_step' => $from_step,
            'stop_step' => $to_step,
            'prep_range' => [$from_step, $to_step],
            'phases' => $run_result['phases'] ?? 0,
            'written' => $written,
            'log' => $run_result['log'] ?? [],
            'stopped' => $run_result['stopped'] ?? false,
        ];

        if ($play_after && $cycle < $loops - 1) {
            $play_start = $to_step + 1;
            if ($play_start <= $session_end) {
                $cycle_result['play'] = operational_steps_run_recipe_steps(
                    $dbc,
                    $recipe,
                    $play_start,
                    $session_end,
                    $config
                );
            } else {
                $cycle_result['play'] = warm_start_play_operating_session($dbc, $config);
            }
        }

        $cycles[] = $cycle_result;
    }

    return [
        'mode' => $mode,
        'breakpoint_step' => $breakpoint,
        'start_step' => $from_step,
        'stop_step' => $to_step,
        'session_count' => $loops,
        'cycles' => $cycles,
        'warnings' => $warnings,
        'sessions' => array_column($cycles, 'session'),
        'indices' => $indices,
    ];
}
