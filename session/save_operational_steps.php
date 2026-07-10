<?php
/**
 * Save STS operational steps CSV from the browser editor.
 * Writes to switchlists/ and sts/backups/ (host-mounted sts-backups).
 */

header('Content-Type: application/json; charset=utf-8');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'error' => 'POST required']);
    exit;
}

$raw = file_get_contents('php://input');
$payload = json_decode($raw, true);
if (!is_array($payload) || !isset($payload['rows']) || !is_array($payload['rows'])) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'Invalid JSON: expected { rows: [...] }']);
    exit;
}

function operational_steps_csv_field($value)
{
    $value = str_replace(["\r\n", "\r", "\n"], ' ', (string) $value);
    if (preg_match('/[",\n\r]/', $value)) {
        return '"' . str_replace('"', '""', $value) . '"';
    }
    return $value;
}

$lines = ['Step #,STS GUI Instruction,Full Description'];
$row_num = 0;
foreach ($payload['rows'] as $row) {
    if (!is_array($row)) {
        continue;
    }
    $row_num++;
    $instruction = $row['instruction'] ?? '';
    $description = $row['description'] ?? '';
    $lines[] = operational_steps_csv_field((string) $row_num)
        . ',' . operational_steps_csv_field($instruction)
        . ',' . operational_steps_csv_field($description);
}

$csv = implode("\n", $lines) . "\n";

$switchlists_dir = dirname(__FILE__);
$backup_dir = dirname(__DIR__) . '/sts/backups';

$targets = [
    'switchlists' => $switchlists_dir . '/STS_OPERATIONAL_STEPS.csv',
    'sts_backups' => $backup_dir . '/STS_OPERATIONAL_STEPS.csv',
];

$written = [];
$errors = [];
foreach ($targets as $label => $path) {
    $dir = dirname($path);
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        $errors[] = "Could not create directory: {$dir}";
        continue;
    }
    if (@file_put_contents($path, $csv) === false) {
        $errors[] = "Could not write: {$path}";
        continue;
    }
    $written[$label] = $path;
}

if (count($written) === 0) {
    http_response_code(500);
    echo json_encode(['ok' => false, 'error' => implode('; ', $errors)]);
    exit;
}

echo json_encode([
    'ok' => true,
    'rows' => $row_num,
    'written' => $written,
    'warnings' => $errors,
]);
