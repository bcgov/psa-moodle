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
$CFG->sslproxy    = true;
$CFG->reverseproxy = true;

// --- Cron, CLI, paths ---
$CFG->pathtophp = '/usr/local/bin/php';

require_once(__DIR__ . '/lib/setup.php');
