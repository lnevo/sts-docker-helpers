<?php
$session = (int) ($_GET['session'] ?? 0);
$job = trim($_GET['job'] ?? '');
if ($session <= 0 || $job === '') {
    header('Location: index.php');
    exit;
}

$sts_dir = dirname(__DIR__) . '/sts';
if (!is_dir($sts_dir)) {
    $sts_dir = __DIR__ . '/../sts';
}
require_once $sts_dir . '/session_helpers.php';

$root = session_web_root();
$manifest = session_load_manifest($session, $root);
$job_meta = $manifest['jobs'][$job] ?? ['phases' => []];
$phase_nums = $job_meta['phases'] ?? [];
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?php echo htmlspecialchars($job); ?> — session <?php echo (int) $session; ?></title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #f4f6f8; }
    .nav { background: #1f4d2e; padding: 12px 16px; }
    .nav a { color: #fff; text-decoration: none; margin-right: 12px; }
    main { max-width: 960px; margin: 0 auto; padding: 16px; }
    .card { background: #fff; border: 1px solid #d8dee4; border-radius: 10px; padding: 14px; margin-bottom: 12px; }
    h1 { margin: 0 0 8px; }
    ul { padding-left: 18px; }
    a { color: #1f4d2e; }
  </style>
</head>
<body>
  <nav class="nav">
    <a href="index.php">← All sessions</a>
    <a href="session_<?php echo (int) $session; ?>/index.php">Session <?php echo (int) $session; ?></a>
  </nav>
  <main>
    <h1><?php echo htmlspecialchars($job); ?> — session <?php echo (int) $session; ?></h1>

    <div class="card">
      <h2 style="margin:0 0 8px;font-size:16px;">Switch lists</h2>
      <?php if (count($phase_nums)): ?>
        <ul>
          <?php foreach ($phase_nums as $p): ?>
            <?php
              $phase_dir = 'session_' . $session . '/phase_' . str_pad((int) $p, 2, '0', STR_PAD_LEFT) . '/' . rawurlencode($job);
              $index = $phase_dir . '/index.html';
            ?>
            <li>Phase <?php echo (int) $p; ?> — <a href="<?php echo htmlspecialchars($index); ?>">open switch list</a></li>
          <?php endforeach; ?>
        </ul>
      <?php else: ?>
        <p>No switch-list phases for this train.</p>
      <?php endif; ?>
    </div>

    <div class="card">
      <h2 style="margin:0 0 8px;font-size:16px;">Waybills</h2>
      <ul>
        <?php foreach ($phase_nums as $p): ?>
          <?php $wb = 'session_' . $session . '/phase_' . str_pad((int) $p, 2, '0', STR_PAD_LEFT) . '/waybills/index.html'; ?>
          <li>Phase <?php echo (int) $p; ?> — <a href="<?php echo htmlspecialchars($wb); ?>">waybill list</a></li>
        <?php endforeach; ?>
        <?php if (!count($phase_nums)): ?>
          <li>No waybills yet — add a <em>Generate Waybill List</em> step after switch lists.</li>
        <?php endif; ?>
      </ul>
    </div>
  </main>
</body>
</html>
