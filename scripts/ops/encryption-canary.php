<?php
// encryption-canary.php (runbook S12, §13.2, §8.3; review V1012): proves that a dataroot's encryption key belongs to
// a database. Kept after Phase 5: every paired restore uses it.
//
//   php encryption-canary.php create   once, on the new stack after the database is loaded (§13.2) or installed: stores
//                                      a constant encrypted with THIS dataroot's key in core config
//                                      rp_encryption_canary. If one exists, it must already decrypt (idempotent).
//   php encryption-canary.php check    after a restore: the stored value must decrypt, with the restored key, to the
//                                      constant. A wrong or regenerated key fails (sodium authentication).
// Run as the php user, from Moodle's root or with MOODLE_ROOT=/var/www/html. The canary is the only encrypted value on prod and test today (§5.3), so it
// is what makes the key check meaningful. Exit 0 on success, 1 on failure; prints no secret.
define('CLI_SCRIPT', true);
// From Moodle's root, or anywhere with MOODLE_ROOT set (e.g. copied into /tmp in a pod).
require((getenv('MOODLE_ROOT') ?: __DIR__) . '/config.php');
const RP_CANARY = 'psa-moodle encryption canary v1';
$mode = $argv[1] ?? '';
// Read the database directly, not get_config(): a restored dataroot may carry a stale config cache.
$read = function () use ($DB) { return $DB->get_field('config', 'value', ['name' => 'rp_encryption_canary']); };
$stored = $read();
$decrypts = function ($v) {
    try {
        return \core\encryption::decrypt($v) === RP_CANARY;
    } catch (\Throwable $e) {
        return false;
    }
};
if ($mode === 'create') {
    if ($stored !== false && $stored !== '') {
        if (!$decrypts($stored)) {
            echo "canary present but does NOT decrypt with this dataroot's key\n";
            exit(1);
        }
        echo "canary already present and decrypts\n";
        exit(0);
    }
    set_config('rp_encryption_canary', \core\encryption::encrypt(RP_CANARY));
    echo $decrypts($read()) ? "canary created\n" : "canary created but does not decrypt\n";
    exit(0);
}
if ($mode === 'check') {
    if ($stored === false || $stored === '') {
        echo "no canary in this database (create it at load time, §13.2)\n";
        exit(1);
    }
    $ok = $decrypts($stored);
    echo $ok ? "canary decrypts with this dataroot's key\n" : "canary does NOT decrypt: the key and the database are not a pair\n";
    exit($ok ? 0 : 1);
}
fwrite(STDERR, "usage: php encryption-canary.php create|check\n");
exit(2);
