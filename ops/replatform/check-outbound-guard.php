<?php
// Print the outbound guard's effective values (replatform runbook §8.2, C5) and check them.
//
//   php check-outbound-guard.php --expect=on    guard must be in force (every checkpoint before S11)
//   php check-outbound-guard.php --expect=off   after the commit point: the database's own settings apply
//
// Run from the Moodle code root (copy it there, or run with the code root as working directory). Exit 1 on any mismatch.
// It prints setting values that are URLs or flags, never tokens: a token is shown only as set or empty.
define('CLI_SCRIPT', true);
require(getcwd() . '/config.php');
require_once($CFG->libdir . '/clilib.php');

[$opt] = cli_get_params(['expect' => null]);
if (!in_array($opt['expect'], ['on', 'off'], true)) {
    cli_error('--expect=on|off is required');
}
$on = $opt['expect'] === 'on';
$dead = 'http://127.0.0.1:9/outbound-disabled';
$bad = 0;

function rp_row($name, $value, $ok) {
    global $bad;
    printf("%-4s %-42s %s\n", $ok ? 'ok' : 'FAIL', $name, $value);
    $bad += $ok ? 0 : 1;
}

$elm = get_config('local_psaelmsync');
$tasks = [];
foreach (['\local_psaelmsync\task\sync_task', '\local_psaelmsync\task\process_course_completion'] as $class) {
    $task = \core\task\manager::get_scheduled_task($class);
    $tasks[$class] = $task ? ($task->get_disabled() ? 'disabled' : 'enabled') : 'absent';
}

echo "MOODLE_OUTBOUND=" . var_export(getenv('MOODLE_OUTBOUND'), true) . ", expecting the guard " . $opt['expect'] . "\n";
rp_row('noemailever', var_export(!empty($CFG->noemailever), true), !$on || !empty($CFG->noemailever));
rp_row('enablewebservices', var_export((int)$CFG->enablewebservices, true), !$on || empty($CFG->enablewebservices));
foreach (['apiurl', 'completion_apiurl'] as $k) {
    $v = $elm->$k ?? '';
    rp_row("local_psaelmsync/$k", $v, $on ? $v === $dead : $v !== $dead);
}
foreach (['apitoken', 'completion_apitoken', 'notificationemails'] as $k) {
    $v = $elm->$k ?? '';
    rp_row("local_psaelmsync/$k", $v === '' ? '(empty)' : '(set)', !$on || $v === '');
}
rp_row('local_psaelmsync/enabled', var_export($elm->enabled ?? null, true), !$on || empty($elm->enabled));
foreach ($tasks as $class => $state) {
    rp_row("task $class", $state, !$on || $state !== 'enabled');
}
rp_row('siteadmins', $CFG->siteadmins === '' ? '(none)' : $CFG->siteadmins, true);
rp_row('nokeygeneration', var_export(!empty($CFG->nokeygeneration), true), true);
rp_row('local_githubsync installed', var_export(core_component::get_component_directory('local_githubsync') !== null, true),
    core_component::get_component_directory('local_githubsync') === null);

echo $bad ? "$bad check(s) FAILED\n" : "all checks passed\n";
exit($bad ? 1 : 0);
