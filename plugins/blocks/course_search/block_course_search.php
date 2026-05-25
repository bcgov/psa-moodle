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
 * Course search block.
 *
 * @package   block_course_search
 * @copyright 2025 Your Name
 * @license   http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

require_once($CFG->dirroot . '/blocks/moodleblock.class.php');

/**
 * Course search block class.
 *
 * @package   block_course_search
 * @copyright 2025 Your Name
 * @license   http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
class block_course_search extends block_base {
    /**
     * Initialize the block.
     */
    public function init() {
        $this->title = get_string('pluginname', 'block_course_search');
    }

    /**
     * Get the block content.
     *
     * @return stdClass The block content.
     */
    public function get_content() {
        if ($this->content !== null) {
            return $this->content;
        }

        $this->content = new stdClass();
        $this->content->text = '';
        $this->content->footer = '';

        // Only show within a course (course pages and activity pages).
        $courseid = $this->page->course->id;
        if (empty($courseid) || $courseid == SITEID) {
            return $this->content;
        }

        // Build the search form.
        $searchurl = new moodle_url('/blocks/course_search/search.php', ['courseid' => $courseid]);

        $this->content->text = html_writer::start_tag('form', [
            'method' => 'get',
            'action' => $searchurl->out(),
            'role' => 'search',
        ]);

        $this->content->text .= html_writer::start_tag('div', ['class' => 'course-search-form']);

        $this->content->text .= html_writer::tag(
            'label',
            get_string('searchcourse', 'block_course_search'),
            ['for' => 'course-search-input', 'class' => 'sr-only']
        );

        $this->content->text .= html_writer::empty_tag('input', [
            'type' => 'text',
            'name' => 'q',
            'id' => 'course-search-input',
            'placeholder' => get_string('searchcourse', 'block_course_search'),
            'class' => 'form-control',
            'required' => 'required',
        ]);

        $this->content->text .= html_writer::empty_tag('input', [
            'type' => 'hidden',
            'name' => 'courseid',
            'value' => $courseid,
        ]);

        $this->content->text .= html_writer::tag(
            'button',
            get_string('search', 'block_course_search'),
            ['type' => 'submit', 'class' => 'btn btn-primary mt-2']
        );

        $this->content->text .= html_writer::end_tag('div');
        $this->content->text .= html_writer::end_tag('form');

        return $this->content;
    }

    /**
     * Define where the block can be added.
     *
     * @return array
     */
    public function applicable_formats() {
        return [
            'course-view' => true,
            'mod' => true,
            'all' => false,
        ];
    }

    /**
     * After a new instance is created, set pagetypepattern to '*' so
     * the block appears on all pages within the course (activities, search results, etc.)
     * rather than only on the course main page.
     *
     * @return bool
     */
    public function instance_create() {
        global $DB;
        $DB->update_record('block_instances', (object) [
            'id' => $this->instance->id,
            'pagetypepattern' => '*',
            'showinsubcontexts' => 1,
        ]);
        return true;
    }

    /**
     * Allow multiple instances of this block per page.
     *
     * @return bool
     */
    public function instance_allow_multiple() {
        return false;
    }
}
