<?php
// version-compare.php (runbook S7; review V1013): do the database and the code agree on EVERY version, before anything
// writes to the database? Reads the source database directly (mysqli, the SRC_DB* environment of migrate-config.php)
// and parses each version.php under the code root, without booting Moodle (which may refuse to start while a plugin
// that E7 will remove is still installed).
//
//   php version-compare.php <code root> [<plugin allowed in the database but not in the code> ...]
//
// Stops (exit 1) on: a core version that differs; a plugin whose version differs; a plugin in the code but not in the
// database (it would be installed); a plugin in the database but not in the code, unless named as allowed (only
// local_githubsync, while E7 is still to run). Prints component names and versions only.
$root = rtrim($argv[1] ?? '', '/');
if ($root === '' || !is_file("$root/version.php")) {
    fwrite(STDERR, "usage: php version-compare.php <code root> [allowed-extra-plugin ...]\n");
    exit(2);
}
$allowed = array_slice($argv, 2);
$prefix = getenv('SRC_PREFIX') ?: '';

// Code: core, then every plugin's version.php (each declares $plugin->component).
$code = [];
$src = file_get_contents("$root/version.php");
if (!preg_match('/^\s*\$version\s*=\s*([0-9.]+)/m', $src, $m)) {
    fwrite(STDERR, "cannot read core \$version\n");
    exit(2);
}
$corecode = $m[1];
$it = new RecursiveIteratorIterator(new RecursiveCallbackFilterIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
    function ($f) {
        $n = $f->getFilename();
        return !in_array($n, ['vendor', 'node_modules', 'tests', 'fixtures', '.git'], true);
    }
));
foreach ($it as $f) {
    if ($f->getFilename() !== 'version.php' || $f->getPathname() === "$root/version.php") {
        continue;
    }
    $s = file_get_contents($f->getPathname());
    if (preg_match('/\$plugin->component\s*=\s*[\'"]([a-z0-9_]+)[\'"]/', $s, $c)
            && preg_match('/\$plugin->version\s*=\s*([0-9.]+)/', $s, $v)) {
        $code[$c[1]] = $v[1];
    }
}

// Database.
$db = mysqli_init();
if (!@$db->real_connect(getenv('SRC_DBHOST'), getenv('SRC_DBUSER'), getenv('SRC_DBPASS'), getenv('SRC_DBNAME') ?: 'moodle')) {
    fwrite(STDERR, "cannot connect to the source database\n");
    exit(2);
}
$coredb = $db->query("SELECT value FROM {$prefix}config WHERE name = 'version'")->fetch_row()[0] ?? null;
$dbv = [];
$r = $db->query("SELECT plugin, value FROM {$prefix}config_plugins WHERE name = 'version'");
while ($row = $r->fetch_row()) {
    $dbv[$row[0]] = $row[1];
}

$bad = [];
if ((string)$coredb !== (string)$corecode) {
    $bad[] = "core: database $coredb, code $corecode";
}
foreach ($code as $comp => $v) {
    if (!array_key_exists($comp, $dbv)) {
        $bad[] = "$comp: in the code ($v) but not in the database (would be installed)";
    } else if ((string)$dbv[$comp] !== (string)$v) {
        $bad[] = "$comp: database {$dbv[$comp]}, code $v";
    }
}
foreach ($dbv as $comp => $v) {
    if (!array_key_exists($comp, $code) && !in_array($comp, $allowed, true)) {
        $bad[] = "$comp: in the database ($v) but not in the code";
    }
}
printf("core %s; %d plugins in the code, %d in the database%s\n", $corecode, count($code), count($dbv),
    $allowed ? '; allowed extra: ' . implode(',', $allowed) : '');
if ($bad) {
    echo "VERSION MISMATCH, nothing has been changed:\n  " . implode("\n  ", $bad) . "\n";
    exit(1);
}
echo "every version matches\n";
