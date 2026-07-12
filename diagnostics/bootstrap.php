<?php
/**
 * Bootstrap for CLI diagnostics under sts-docker-helpers/diagnostics/.
 * Resolves the STS PHP runtime (sts-docker/sts) whether run on the host or copied into the container.
 */
function diagnostics_sts_runtime(): string
{
    static $root = null;
    if ($root !== null) {
        return $root;
    }
    $candidates = [
        dirname(__DIR__, 2) . '/sts-docker/sts',
        dirname(__DIR__) . '/../sts-docker/sts',
        '/var/www/html/sts',
    ];
    foreach ($candidates as $path) {
        if (is_file($path . '/open_db.php')) {
            $root = realpath($path) ?: $path;
            return $root;
        }
    }
    fwrite(STDERR, "Cannot find STS runtime (open_db.php). Expected sts-docker/sts.\n");
    exit(1);
}

function diagnostics_bootstrap(): string
{
    $root = diagnostics_sts_runtime();
    chdir($root);
    return $root;
}

/** Resolve STS runtime when executed from diagnostics/ or from a hot-copy in sts/. */
function diagnostics_resolve_runtime(): string
{
    if (is_file(__DIR__ . '/open_db.php')) {
        chdir(__DIR__);
        return __DIR__;
    }
    $root = diagnostics_sts_runtime();
    chdir($root);
    return $root;
}
