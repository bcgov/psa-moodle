<?php
// config.php for conversion runs (runbook §8.3, C14). It points Moodle at the SOURCE database of a
// tool_dbtransfer run and at a scratch dataroot. It holds no secrets: everything comes from the
// environment, which local-pipeline.sh sets from an owner-only file.
//
//   forward (legacy -> new):  SRC_DBTYPE=mariadb SRC_PREFIX=''      (target: pgsql, prefix mdl_)
//   reverse (new -> legacy):  SRC_DBTYPE=pgsql   SRC_PREFIX='mdl_'  (target: mariadb, prefix '')
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = getenv('SRC_DBTYPE') ?: 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('SRC_DBHOST');
$CFG->dbname    = getenv('SRC_DBNAME') ?: 'moodle';
$CFG->dbuser    = getenv('SRC_DBUSER');
$CFG->dbpass    = getenv('SRC_DBPASS');
$CFG->prefix    = getenv('SRC_PREFIX') === false ? '' : getenv('SRC_PREFIX');
$CFG->dboptions = ['dbpersist' => 0, 'dbport' => '', 'dbsocket' => ''];
if ($CFG->dbtype === 'mariadb') {
    $CFG->dboptions['dbcollation'] = 'utf8mb4_unicode_ci';
}

$CFG->wwwroot   = 'http://convert.invalid';
$CFG->dataroot  = getenv('SCRATCH_DATAROOT') ?: '/data/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02770;

// A conversion run must never reach anything outside its own containers.
$CFG->noemailever = true;
$CFG->enablewebservices = 0;

// RP_DEBUG=1 shows the database's own error messages (they can include row data: keep logs private).
if (getenv('RP_DEBUG')) {
    $CFG->debug = E_ALL;
    $CFG->debugdisplay = 1;
}

require_once(__DIR__ . '/lib/setup.php');
