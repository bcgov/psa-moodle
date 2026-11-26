<?php
// Moodle cache (MUC) configuration for psa-moodle (runbook §0.11; owner decision 2026-11-26; review V1201).
//
// Application caches go to Valkey (Moodle's own cachestore_redis); session caches stay in Moodle's session store,
// which now lives in Postgres with the session itself; request caches stay static. Only Valkey is mapped for the
// application mode, deliberately without a file store behind it: when Valkey can't be reached at a request's start,
// Moodle marks the store not ready and runs that request uncached (core_cache\factory's dummy store), which is slower
// but correct. A second store would keep serving entries that a missed invalidation left stale (V1201).
//
// Regenerated from the release's environment, never copied: legacy's muc/config.php is excluded from every copy, and
// this runs at every php container start and at the end of the installer, so a fresh dataroot, a restored copy and a
// cutover all get the same configuration. Idempotent: it writes muc/config.php only when the result would differ.
//
//   php configure-cache.php            apply; exits 0 without changing anything if Moodle isn't installed yet
//   php configure-cache.php --check    print the mapping; exit 1 unless it is the one below
//
// Environment: CACHE_HOST, CACHE_PORT (6379), CACHE_PASSWORD, CACHE_CONNECT_TIMEOUT (seconds, default 1: an unreachable
// Valkey costs each request at most this long before it runs uncached), MOODLE_ROOT (/var/www/html).

define('CLI_SCRIPT', true);
$check = in_array('--check', $argv, true);
require((getenv('MOODLE_ROOT') ?: '/var/www/html') . '/config.php');

const PSA_STORE = 'psa-valkey';

if (empty($CFG->version)) {
    echo "[cache-config] Moodle is not installed yet: nothing to configure\n";
    exit($check ? 1 : 0);
}
$host = getenv('CACHE_HOST');
if (!$host) {
    fwrite(STDERR, "[cache-config] CACHE_HOST is not set\n");
    exit(1);
}

$wantstore = [
    'server' => $host . ':' . ((int)(getenv('CACHE_PORT') ?: 6379)),
    'prefix' => 'muc_',
    'password' => (string)(getenv('CACHE_PASSWORD') ?: ''),
    'serializer' => 1,              // Redis::SERIALIZER_PHP (the images' phpredis has no igbinary)
    'compressor' => 0,              // none
    'connectiontimeout' => (int)(getenv('CACHE_CONNECT_TIMEOUT') ?: 1),
    'encryption' => false,
    'cafile' => '',
    'clustermode' => false,
];
$wantmappings = [
    \core_cache\store::MODE_APPLICATION => [PSA_STORE],
    \core_cache\store::MODE_SESSION => ['default_session'],
    \core_cache\store::MODE_REQUEST => ['default_request'],
];

// The mapping as it stands: store names per mode, in order.
function psa_mappings(\core_cache\config $config): array {
    $out = [\core_cache\store::MODE_APPLICATION => [], \core_cache\store::MODE_SESSION => [],
            \core_cache\store::MODE_REQUEST => []];
    $rows = $config->get_mode_mappings();
    usort($rows, fn($a, $b) => [$a['mode'], $a['sort']] <=> [$b['mode'], $b['sort']]);
    foreach ($rows as $row) {
        $out[$row['mode']][] = $row['store'];
    }
    return $out;
}

$config = \core_cache\config::instance();
$stores = $config->get_all_stores();
$havestore = $stores[PSA_STORE] ?? null;
$storeok = $havestore !== null && $havestore['plugin'] === 'redis' && ($havestore['configuration'] ?? []) == $wantstore;
$mapok = psa_mappings($config) == $wantmappings;

$describe = function (array $m): string {
    return sprintf('application=%s session=%s request=%s', implode(',', $m[\core_cache\store::MODE_APPLICATION]),
        implode(',', $m[\core_cache\store::MODE_SESSION]), implode(',', $m[\core_cache\store::MODE_REQUEST]));
};

if ($check) {
    printf("[cache-config] store %s: %s; mapping: %s\n", PSA_STORE,
        $havestore === null ? 'ABSENT' : ($storeok ? 'as configured' : 'DIFFERENT'), $describe(psa_mappings($config)));
    exit($storeok && $mapok ? 0 : 1);
}

if ($storeok && $mapok) {
    printf("[cache-config] unchanged: %s on %s\n", $describe($wantmappings), $wantstore['server']);
    exit(0);
}

$writer = \core_cache\config_writer::instance();
if ($havestore === null) {
    $writer->add_store_instance(PSA_STORE, 'redis', $wantstore);
} else if (!$storeok) {
    $writer->edit_store_instance(PSA_STORE, 'redis', $wantstore);
}
$writer->set_mode_mappings($wantmappings);
// The stores' contents describe the old mapping; start the new one clean.
\core_cache\helper::purge_all(true);

$after = psa_mappings(\core_cache\config_writer::instance());
if ($after != $wantmappings) {
    fwrite(STDERR, "[cache-config] the mapping did not take: " . $describe($after) . "\n");
    exit(1);
}
printf("[cache-config] applied: %s on %s (connection timeout %ds)\n", $describe($wantmappings), $wantstore['server'],
    $wantstore['connectiontimeout']);
