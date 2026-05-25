<?php
// This file is part of Moodle - http://moodle.org/
//
// Moodle is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Moodle is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Moodle.  If not, see <http://www.gnu.org/licenses/>.

/**
 * Display information about all the mod_pathcurator modules in the requested course.
 *
 * @package     mod_pathcurator
 * @copyright   2025 Your Name <you@example.com>
 * @license     http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

require_once(__DIR__ . '/../../config.php');
require_once(__DIR__ . '/lib.php');

$id = required_param('id', PARAM_INT);

$course = $DB->get_record('course', array('id' => $id), '*', MUST_EXIST);
require_course_login($course);

$coursecontext = context_course::instance($course->id);

$event = \mod_pathcurator\event\course_module_instance_list_viewed::create(array(
    'context' => $coursecontext
));
$event->add_record_snapshot('course', $course);
$event->trigger();

$PAGE->set_url('/mod/pathcurator/index.php', array('id' => $id));
$PAGE->set_title(format_string($course->fullname));
$PAGE->set_heading(format_string($course->fullname));
$PAGE->set_context($coursecontext);

echo $OUTPUT->header();

$modulenameplural = get_string('modulenameplural', 'pathcurator');
echo $OUTPUT->heading($modulenameplural);

$pathcurators = get_all_instances_in_course('pathcurator', $course);

if (empty($pathcurators)) {
    notice(get_string('thereareno', 'moodle', $modulenameplural), new moodle_url('/course/view.php', array('id' => $course->id)));
}

$table = new html_table();
$table->attributes['class'] = 'generaltable mod_index';

$table->head = array();
$table->align = array();

$table->head[] = get_string('name');
$table->align[] = 'left';

foreach ($pathcurators as $pathcurator) {
    $cm = get_coursemodule_from_instance('pathcurator', $pathcurator->id, $course->id, false, MUST_EXIST);
    
    $row = array();
    
    $link = html_writer::link(
        new moodle_url('/mod/pathcurator/view.php', array('id' => $cm->id)),
        format_string($pathcurator->name, true)
    );
    
    if (!$pathcurator->visible) {
        $link = html_writer::tag('span', $link, array('class' => 'dimmed'));
    }
    
    $row[] = $link;
    $table->data[] = $row;
}

echo html_writer::table($table);

echo $OUTPUT->footer();