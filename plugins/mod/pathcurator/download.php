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
 * Download JSON source file for PathCurator instance
 *
 * @package     mod_pathcurator
 * @copyright   2025 Your Name <you@example.com>
 * @license     http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

require_once(__DIR__ . '/../../config.php');

// Course module id.
$id = required_param('id', PARAM_INT);

$cm = get_coursemodule_from_id('pathcurator', $id, 0, false, MUST_EXIST);
$course = $DB->get_record('course', array('id' => $cm->course), '*', MUST_EXIST);
$pathcurator = $DB->get_record('pathcurator', array('id' => $cm->instance), '*', MUST_EXIST);

require_login($course, true, $cm);

$modulecontext = context_module::instance($cm->id);

// Check permissions - only teachers/admins can download
if (!has_capability('mod/pathcurator:addinstance', $modulecontext) && !is_siteadmin()) {
    throw new moodle_exception('nopermissions', 'error', '', 'download JSON source');
}

// Check if JSON data exists
if (empty($pathcurator->jsondata)) {
    throw new moodle_exception('No JSON data available for download', 'mod_pathcurator');
}

// Prepare the filename
$filename = clean_filename($pathcurator->name) . '_source.json';

// Set headers for download
header('Content-Type: application/json');
header('Content-Disposition: attachment; filename="' . $filename . '"');
header('Content-Length: ' . strlen($pathcurator->jsondata));
header('Cache-Control: private');

// Output the JSON data
echo $pathcurator->jsondata;
exit;