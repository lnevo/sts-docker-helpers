<?php
/**
 * Direct on-disk cleanup of stale special-instruction wording under the session
 * output tree. Replaces every earlier variant with the current text in caches
 * (*_master.json), waybill stores (waybills.json), and all rendered HTML. Pure
 * string substitution — no re-render dependency — so it fixes files regardless
 * of how they were generated.
 *
 *   docker exec -u www-data <web> php /tmp/cleanup_special_instructions.php
 */
error_reporting(E_ERROR | E_PARSE);

require_once __DIR__ . '/bootstrap.php';
$sts = diagnostics_resolve_runtime();
require_once $sts . '/session_helpers.php';

$root = session_web_root();

$NEW = 'Outgoing: weigh at scale; record gross wt.';
$OLD = [
    'Outbound coke: weigh at South Yard scale; record certified gross weight on waybill.',
    'Outbound coke: weigh at scale; record certified gross wt.',
];

$scanned = 0;
$changed = 0;
$failed = [];

$it = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)
);
foreach ($it as $file) {
    if (!$file->isFile()) {
        continue;
    }
    $path = $file->getPathname();
    $ext = strtolower($file->getExtension());
    if ($ext !== 'html' && $ext !== 'json') {
        continue;
    }
    $scanned++;
    $raw = (string) file_get_contents($path);
    $new = str_replace($OLD, $NEW, $raw);
    if ($new === $raw) {
        continue;
    }
    $ok = file_put_contents($path, $new);
    if ($ok === false) {
        $failed[] = $path;
        continue;
    }
    // Confirm the write actually persisted the new text.
    clearstatcache(true, $path);
    $verify = (string) file_get_contents($path);
    $stale = false;
    foreach ($OLD as $o) {
        if (strpos($verify, $o) !== false) {
            $stale = true;
            break;
        }
    }
    if ($stale) {
        $failed[] = $path;
    } else {
        $changed++;
    }
}

echo "scanned: {$scanned}\n";
echo "changed: {$changed}\n";
echo 'failed: ' . count($failed) . "\n";
foreach (array_slice($failed, 0, 20) as $f) {
    echo "  FAIL {$f}\n";
}
echo "done\n";
