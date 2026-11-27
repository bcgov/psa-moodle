<?php
// Print which database this Moodle pod actually uses, and prove it connects (replatform runbook V506, DR01).
// Feed it to php on stdin so nothing is written to the code volume:
//   oc exec -i -n <ns> <pod> -c php -- php < which-db.php
//   cron at 0, a probe pod: oc debug does NOT pass stdin to a command, so which-db.sh passes this file as php -r code
// Output: dbname=<name> dbhost=<host> connected=yes version=<site version>
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
global $CFG, $DB;
printf("dbname=%s dbhost=%s connected=%s version=%s\n", $CFG->dbname, $CFG->dbhost,
    $DB->get_field('config', 'value', ['name' => 'version']) ? 'yes' : 'no',
    $DB->get_field('config', 'value', ['name' => 'version']));
