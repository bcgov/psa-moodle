<?php
// Moodle config for OpenShift deployment (dev/test).
// All values come from environment variables injected by the Helm chart
// from Kubernetes Secrets and ConfigMaps. Never hardcode credentials here.

unset($CFG);
global $CFG;
$CFG = new stdClass();

// --- Database (Crunchy Postgres operator: PostgresCluster CR) ---
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('DB_HOST');         // <release>-pgcluster-primary
$CFG->dbname    = getenv('DB_NAME');         // moodle
$CFG->dbuser    = getenv('DB_USER');
$CFG->dbpass    = getenv('DB_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = [
    'dbpersist'        => false,
    'dbsocket'         => false,
    'dbport'           => (int)(getenv('DB_PORT') ?: 5432),
    'dbhandlesoptions' => false,
    'dbcollation'      => 'utf8mb4_unicode_ci',
    // Crunchy ships TLS certs in /etc/db-tls; mount path is set by the chart.
    'connect_timeout'  => 5,
];

// --- Site URLs and paths ---
$CFG->wwwroot  = getenv('MOODLE_WWWROOT');    // https://psa-moodle-dev.apps.silver.devops.gov.bc.ca
$CFG->dataroot = '/var/www/moodledata';       // RWX PVC, netapp-file-standard
$CFG->admin    = 'admin';
$CFG->directorypermissions = 02777;

// --- Session storage: Valkey via Service DNS ---
// In dev/test this is a single Valkey pod; Sentinel topology will be added in
// values-prod.yaml only if measured need (see plan Phase 4).
$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host    = getenv('CACHE_HOST');     // <release>-valkey
$CFG->session_redis_port    = (int)(getenv('CACHE_PORT') ?: 6379);
$CFG->session_redis_database = 0;
$CFG->session_redis_auth     = getenv('CACHE_PASSWORD') ?: '';
$CFG->session_redis_prefix   = 'mdl_sess_';
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;
$CFG->session_redis_serializer_use_igbinary = false;

// --- Fast local cache areas (emptyDir, memory-backed via Helm) ---
$CFG->localcachedir = '/mnt/ramdisk/localcache';

// --- We're behind the OpenShift Router, which terminates TLS. ---
// sslproxy: TLS is terminated upstream, so treat the connection as HTTPS.
// reverseproxy MUST be false: the Router forwards the SAME public hostname
// (wwwroot) to nginx, so Moodle's reverseproxy "direct access" guard
// (setuplib.php: reverseproxyabused) fires on every request when it's true.
$CFG->sslproxy    = true;
$CFG->reverseproxy = false;

// --- Cron, CLI, paths ---
$CFG->pathtophp = '/usr/local/bin/php';

// --- Encryption key (replatform runbook §8.2, V602) ---
// A migrated site brings its key from legacy's secret/. If that key is missing, fail loudly (encryption_nokey) instead
// of letting Moodle generate a new one that can't read the values encrypted with the old key.
if (getenv('MOODLE_INSTALL_ENABLED') === 'false') {
    $CFG->nokeygeneration = true;
}

// --- Outbound guard (replatform runbook §8.2, C5, S11) ---
// Until the commit point, a copy of real data must reach nobody: no email, no ELM, no web services, and site
// administration limited to the named reviewers (G2). The chart sets MOODLE_OUTBOUND=on only at the commit point;
// anything else, including unset, keeps the guard on. ops/replatform/check-outbound-guard.php prints the effect.
if (getenv('MOODLE_OUTBOUND') !== 'on') {
    $CFG->noemailever = true;
    $CFG->enablewebservices = 0;
    // local_psaelmsync's completion observer POSTs straight to completion_apiurl and doesn't check `enabled`, so the
    // dead address is what stops it; `enabled` stops the sync task, and the task override below stops both tasks.
    $CFG->forced_plugin_settings['local_psaelmsync'] = [
        'apiurl'              => 'http://127.0.0.1:9/outbound-disabled',
        'completion_apiurl'   => 'http://127.0.0.1:9/outbound-disabled',
        'apitoken'            => '',
        'completion_apitoken' => '',
        'enabled'             => 0,
        'notificationemails'  => '',
    ];
    $CFG->scheduled_tasks = [
        '\local_psaelmsync\*' => ['schedule' => '* * * * *', 'disabled' => 1],
    ];
    // Reviewer-only administration: only these user ids are site admins while the guard is on. Unset means none.
    $CFG->siteadmins = implode(',', array_filter(array_map('intval',
        explode(',', (string)getenv('MOODLE_REVIEWER_ADMINS')))));
}

require_once(__DIR__ . '/lib/setup.php');
