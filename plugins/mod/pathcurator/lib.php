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
 * Library of interface functions and constants for module pathcurator
 *
 * @package     mod_pathcurator
 * @copyright   2025 Your Name <you@example.com>
 * @license     http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

/**
 * Add a pathcurator instance.
 * @param stdClass $pathcurator
 * @return int The instance id of the new pathcurator
 */
function pathcurator_add_instance($pathcurator) {
    global $DB, $USER;

    $pathcurator->timemodified = time();
    
    // Handle pathway data source.
    $hasFile = false;
    if (!empty($pathcurator->jsonfile)) {
        // Check if a file was actually uploaded.
        $draftitemid = $pathcurator->jsonfile;
        $usercontext = context_user::instance($USER->id);
        $fs = get_file_storage();
        $files = $fs->get_area_files($usercontext->id, 'user', 'draft', $draftitemid, 'id', false);
        
        if ($files) {
            $hasFile = true;
            $file = reset($files);
            $content = $file->get_content();
            $pathcurator->jsondata = $content;
            // Clear URL if using file.
            $pathcurator->jsonurl = null;
        }
    }
    
    if (!$hasFile && !empty($pathcurator->jsonurl)) {
        // Clear jsondata if using URL.
        $pathcurator->jsondata = null;
    }
    
    // Remove the jsonfile field as it's not a database field.
    unset($pathcurator->jsonfile);
    
    $pathcurator->id = $DB->insert_record('pathcurator', $pathcurator);

    return $pathcurator->id;
}

/**
 * Update a pathcurator instance.
 * @param stdClass $pathcurator
 * @return bool
 */
function pathcurator_update_instance($pathcurator) {
    global $DB, $USER;

    $pathcurator->timemodified = time();
    $pathcurator->id = $pathcurator->instance;
    
    // Handle pathway data source.
    $hasFile = false;
    if (!empty($pathcurator->jsonfile)) {
        // Check if a file was actually uploaded.
        $draftitemid = $pathcurator->jsonfile;
        $usercontext = context_user::instance($USER->id);
        $fs = get_file_storage();
        $files = $fs->get_area_files($usercontext->id, 'user', 'draft', $draftitemid, 'id', false);
        
        if ($files) {
            $hasFile = true;
            $file = reset($files);
            $content = $file->get_content();
            $pathcurator->jsondata = $content;
            // Clear URL if using file.
            $pathcurator->jsonurl = null;
        }
    }
    
    if (!$hasFile && !empty($pathcurator->jsonurl)) {
        // Clear jsondata if using URL.
        $pathcurator->jsondata = null;
    }
    
    // Remove the jsonfile field as it's not a database field.
    unset($pathcurator->jsonfile);

    return $DB->update_record('pathcurator', $pathcurator);
}

/**
 * Delete a pathcurator instance.
 * @param int $id
 * @return bool
 */
function pathcurator_delete_instance($id) {
    global $DB;

    if (!$pathcurator = $DB->get_record('pathcurator', array('id' => $id))) {
        return false;
    }

    $DB->delete_records('pathcurator', array('id' => $pathcurator->id));

    return true;
}

/**
 * @param string $feature FEATURE_xx constant for requested feature
 * @return bool True if module supports feature, false if not, null if doesn't know
 */
function pathcurator_supports($feature) {
    switch($feature) {
        case FEATURE_MOD_INTRO:
            return true;
        case FEATURE_SHOW_DESCRIPTION:
            return true;
        case FEATURE_BACKUP_MOODLE2:
            return true;
        case FEATURE_COMPLETION_TRACKS_VIEWS:
            return true;
        case FEATURE_GRADE_HAS_GRADE:
            return false;
        default:
            return null;
    }
}

/**
 * @param stdClass $pathcurator
 * @param stdClass $cm
 * @param stdClass $context
 * @param string $filearea
 * @param array $args
 * @param bool $forcedownload
 * @param array $options
 * @return bool false if file not found, does not return if found - just sends the file
 */
function pathcurator_pluginfile($course, $cm, $context, $filearea, $args, $forcedownload, array $options=array()) {
    if ($context->contextlevel != CONTEXT_MODULE) {
        return false;
    }

    require_login($course, true, $cm);

    if ($filearea !== 'jsonfile') {
        return false;
    }

    $fs = get_file_storage();
    $filename = array_pop($args);
    $filepath = '/';

    if (!$file = $fs->get_file($context->id, 'mod_pathcurator', 'jsonfile', 0, $filepath, $filename)) {
        return false;
    }

    send_stored_file($file, 0, 0, $forcedownload, $options);
}

/**
 * Mark the activity completed (if required) and trigger the course_module_viewed event.
 *
 * @param stdClass $pathcurator pathcurator object
 * @param stdClass $course course object
 * @param stdClass $cm course module object
 * @param stdClass $context context object
 */
function pathcurator_view($pathcurator, $course, $cm, $context) {
    $params = array(
        'context' => $context,
        'objectid' => $pathcurator->id
    );

    $event = \mod_pathcurator\event\course_module_viewed::create($params);
    $event->add_record_snapshot('course_modules', $cm);
    $event->add_record_snapshot('course', $course);
    $event->add_record_snapshot('pathcurator', $pathcurator);
    $event->trigger();

    // Completion
    $completion = new completion_info($course);
    $completion->set_module_viewed($cm);
}