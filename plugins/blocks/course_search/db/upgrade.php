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
 * Upgrade steps for the course search block.
 *
 * @package   block_course_search
 * @copyright 2025 Your Name
 * @license   http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

/**
 * Upgrade the block_course_search plugin.
 *
 * @param int $oldversion The old version of the plugin.
 * @return bool
 */
function xmldb_block_course_search_upgrade($oldversion) {
    global $DB;

    if ($oldversion < 2025070901) {
        // Update existing block instances so they appear on all pages within the course,
        // not just the course main page.
        $DB->set_field(
            'block_instances',
            'pagetypepattern',
            '*',
            ['blockname' => 'course_search', 'pagetypepattern' => 'course-view-*']
        );

        upgrade_block_savepoint(true, 2025070901, 'course_search');
    }

    if ($oldversion < 2025070902) {
        // Enable showinsubcontexts so the block appears on activity pages
        // (child contexts of the course context).
        $DB->set_field(
            'block_instances',
            'showinsubcontexts',
            1,
            ['blockname' => 'course_search']
        );

        upgrade_block_savepoint(true, 2025070902, 'course_search');
    }

    return true;
}
