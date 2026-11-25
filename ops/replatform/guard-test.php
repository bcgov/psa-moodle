<?php
// Outbound guard test (replatform runbook §8.4 step 4, R2, RB11): complete a SYNTHETIC course as SYNTHETIC users with
// the guard on, and show where local_psaelmsync tried to send the completion.
//
//   php guard-test.php --run        create the synthetic records, complete the course, report
//   php guard-test.php --cleanup    delete every record this test created
//
// Run from the Moodle code root, guard on (MOODLE_OUTBOUND not "on"). Every record is marked rp-synthetic-guard.
// Two paths are exercised:
//   A  a learner with no ELM enrolment record: the observer tries to email an alert (notificationemails, empty under
//      the guard) and stops;
//   B  a learner with a synthetic ELM enrolment record: the observer POSTs to completion_apiurl (the dead address under
//      the guard) and logs the attempt.
define('CLI_SCRIPT', true);
require(getcwd() . '/config.php');
require_once($CFG->libdir . '/clilib.php');
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/user/lib.php');
require_once($CFG->libdir . '/completionlib.php');
require_once($CFG->dirroot . '/completion/completion_completion.php');

[$opt] = cli_get_params(['run' => false, 'cleanup' => false]);
const RP_MARK = 'rp-synthetic-guard';
const RP_DEAD = 'http://127.0.0.1:9/outbound-disabled';
global $DB;
\core\session\manager::set_user(get_admin());

function rp_cleanup() {
    global $DB;
    if ($course = $DB->get_record('course', ['shortname' => RP_MARK])) {
        $DB->delete_records('local_psaelmsync_logs', ['course_id' => $course->id]);
        delete_course($course, false);
    }
    foreach ($DB->get_records_select('user', $DB->sql_like('username', ':u'), ['u' => RP_MARK . '%']) as $u) {
        $DB->delete_records('local_psaelmsync_logs', ['user_id' => $u->id]);
        delete_user($u);
        $DB->delete_records('user', ['id' => $u->id]);   // a synthetic account leaves no trace
    }
    echo "cleanup done\n";
}

if ($opt['cleanup']) {
    rp_cleanup();
    exit(0);
}
if (!$opt['run']) {
    cli_error('--run or --cleanup');
}
if (get_config('local_psaelmsync', 'completion_apiurl') !== RP_DEAD || !empty($CFG->noemailever) === false) {
    cli_error('The outbound guard is not on: refusing to complete anything.');
}
rp_cleanup();

$field = $DB->get_record('customfield_field', ['shortname' => 'completion_opt_in'], '*', MUST_EXIST);
$course = create_course((object)['fullname' => 'RP synthetic guard test', 'shortname' => RP_MARK,
    'idnumber' => '999999001', 'category' => $DB->get_field_select('course_categories', 'MIN(id)', '1=1'),
    'enablecompletion' => 1]);
$data = \core_customfield\data_controller::create(0, null, \core_customfield\field_controller::create($field->id));
$data->set('instanceid', $course->id);
$data->set('contextid', context_course::instance($course->id)->id);
$data->set($data->datafield(), 1);
$data->set('value', 1);
$data->save();

$manual = enrol_get_plugin('manual');
$instance = $DB->get_record('enrol', ['courseid' => $course->id, 'enrol' => 'manual'], '*', MUST_EXIST);
$learners = [];
foreach (['a', 'b'] as $k) {
    $id = user_create_user((object)['username' => RP_MARK . "-$k", 'password' => random_string(24) . 'A1!',
        'auth' => 'manual', 'firstname' => 'Synthetic', 'lastname' => strtoupper($k), 'confirmed' => 1,
        'email' => RP_MARK . "-$k@example.invalid", 'idnumber' => RP_MARK . "-$k",
        'mnethostid' => $CFG->mnet_localhost_id], true, false);
    $manual->enrol_user($instance, $id);
    $learners[$k] = $id;
}
// Path B only: a synthetic ELM enrolment record, which is what makes the observer POST.
$DB->insert_record('local_psaelmsync_logs', (object)['sha256hash' => hash('sha256', RP_MARK), 'record_id' => 1,
    'record_date_created' => date('Y-m-d h:i:s'), 'course_id' => $course->id, 'elm_course_id' => 999999001,
    'course_name' => $course->fullname, 'class_code' => RP_MARK, 'user_id' => $learners['b'],
    'user_firstname' => 'Synthetic', 'user_lastname' => 'B', 'user_guid' => RP_MARK . '-b',
    'user_email' => RP_MARK . '-b@example.invalid', 'oprid' => RP_MARK, 'person_id' => 0, 'activity_id' => 0,
    'elm_enrolment_id' => 999999001, 'action' => 'Enrol', 'status' => 'Success', 'timestamp' => time()]);

foreach ($learners as $k => $id) {
    (new completion_completion(['userid' => $id, 'course' => $course->id]))->mark_complete();
}

printf("guard: completion_apiurl=%s, notificationemails=%s, noemailever=%s\n",
    get_config('local_psaelmsync', 'completion_apiurl'),
    get_config('local_psaelmsync', 'notificationemails') === '' ? '(empty)' : '(set)', var_export(!empty($CFG->noemailever), true));
foreach ($learners as $k => $id) {
    $rows = $DB->get_records('local_psaelmsync_logs', ['user_id' => $id, 'action' => 'Complete'], 'id DESC');
    $row = reset($rows);
    printf("path %s: %s\n", strtoupper($k), $row
        ? "completion logged, status={$row->status}" . (isset($row->notes) ? ", notes={$row->notes}" : '')
        : 'no completion logged (lookup failure; its alert email has no recipients under the guard)');
}
echo "now run: php guard-test.php --cleanup\n";
