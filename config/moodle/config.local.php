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

// --- Sessions: in Postgres, as on OpenShift (config.openshift.php); Valkey is the application cache only ---
$CFG->session_handler_class = '\core\session\database';
$CFG->session_database_acquire_lock_timeout = 120;

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
