<?php
// Moodle config for local Podman compose development.
// Code is baked into the image; this file is COPYed in at build time.
// All credentials here are LOCAL DEV ONLY — never used in OpenShift.

unset($CFG);
global $CFG;
$CFG = new stdClass();

// --- Database (Postgres, matches Crunchy Postgres operator in OpenShift) ---
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('DB_HOST')     ?: 'db';
$CFG->dbname    = getenv('DB_NAME')     ?: 'moodle';
$CFG->dbuser    = getenv('DB_USER')     ?: 'moodle';
$CFG->dbpass    = getenv('DB_PASSWORD') ?: 'moodle';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => (int)(getenv('DB_PORT') ?: 5432),
    'dbhandlesoptions' => false,
    'dbcollation' => 'utf8mb4_unicode_ci',
];

// --- Site URLs and paths ---
$CFG->wwwroot   = getenv('MOODLE_WWWROOT') ?: 'http://localhost:8080';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;

// --- Session storage: Valkey (Redis wire-compatible) ---
// Single-node in local dev; matches the dev/test target in OpenShift.
// HA via Sentinel is added later only if measured need (see plan Phase 4).
$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host    = getenv('CACHE_HOST') ?: 'cache';
$CFG->session_redis_port    = (int)(getenv('CACHE_PORT') ?: 6379);
$CFG->session_redis_database = 0;
$CFG->session_redis_auth     = getenv('CACHE_PASSWORD') ?: '';
$CFG->session_redis_prefix   = 'mdl_sess_';
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;
$CFG->session_redis_serializer_use_igbinary = false;

// --- Fast local cache areas (mirror OpenShift emptyDir pattern) ---
$CFG->localcachedir = '/var/local-cache';

// --- Dev-only debug toggles. Off by default; flip via env. ---
if (getenv('MOODLE_DEBUG') === '1') {
    $CFG->debug = (E_ALL | E_STRICT);
    $CFG->debugdisplay = 1;
    $CFG->debugsmtp = 1;
    $CFG->perfdebug = 15;
    $CFG->debugpageinfo = 1;
}

// --- Proxy/SSL trust (local: no proxy). OpenShift overrides via env. ---
if (getenv('MOODLE_BEHIND_PROXY') === '1') {
    $CFG->sslproxy = true;
    $CFG->reverseproxy = true;
}

require_once(__DIR__ . '/lib/setup.php');
