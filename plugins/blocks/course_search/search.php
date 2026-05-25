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
 * Course search results page.
 *
 * @package   block_course_search
 * @copyright 2025 Your Name
 * @license   http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

require_once('../../config.php');
require_once($CFG->dirroot . '/blocks/course_search/lib.php');

$courseid = required_param('courseid', PARAM_INT);
$query = optional_param('q', '', PARAM_TEXT);

$course = $DB->get_record('course', ['id' => $courseid], '*', MUST_EXIST);
$context = context_course::instance($courseid);

require_login($course);

$PAGE->set_url('/blocks/course_search/search.php', ['courseid' => $courseid, 'q' => $query]);
$PAGE->set_context($context);
$PAGE->set_title(get_string('searchresults', 'block_course_search', format_string($query)));
$PAGE->set_heading($course->fullname);
$PAGE->set_pagelayout('incourse');

echo $OUTPUT->header();

if (empty($query)) {
    echo $OUTPUT->heading(get_string('searchcourse', 'block_course_search'));
    echo html_writer::tag('p', get_string('noresults', 'block_course_search', ''));
} else {
    echo $OUTPUT->heading(get_string('searchresults', 'block_course_search', format_string($query)));

    // Perform the search.
    $results = block_course_search_perform_search($query, $courseid);

    if (empty($results)) {
        echo html_writer::tag('p', get_string('noresults', 'block_course_search', format_string($query)));
    } else {
        $resultcount = count($results);
        echo html_writer::tag(
            'p',
            get_string('resultsfound', 'block_course_search', $resultcount),
            ['class' => 'search-results-count']
        );

        echo html_writer::start_tag('div', ['class' => 'search-results']);

        foreach ($results as $result) {
            echo html_writer::start_tag('div', ['class' => 'search-result-item']);

            // Activity/resource title as link.
            $link = html_writer::link(
                $result->url,
                format_string($result->title),
                ['class' => 'search-result-title']
            );
            echo html_writer::tag('h3', $link);

            // Activity type.
            if (!empty($result->type)) {
                echo html_writer::tag('div', $result->type, ['class' => 'search-result-type']);
            }

            // Content preview.
            if (!empty($result->content)) {
                $preview = shorten_text(strip_tags($result->content), 200);
                echo html_writer::tag('div', $preview, ['class' => 'search-result-preview']);
            }

            echo html_writer::end_tag('div');
        }

        echo html_writer::end_tag('div');
    }
}

// Add search form at the bottom.
echo html_writer::start_tag('div', ['class' => 'search-form-bottom']);
echo html_writer::start_tag('form', [
    'method' => 'get',
    'action' => new moodle_url('/blocks/course_search/search.php'),
    'role' => 'search',
]);

echo html_writer::tag(
    'label',
    get_string('searchcourse', 'block_course_search'),
    ['for' => 'course-search-input-bottom', 'class' => 'sr-only']
);

echo html_writer::empty_tag('input', [
    'type' => 'text',
    'name' => 'q',
    'id' => 'course-search-input-bottom',
    'placeholder' => get_string('searchcourse', 'block_course_search'),
    'class' => 'form-control',
    'value' => s($query),
    'required' => 'required',
]);

echo html_writer::empty_tag('input', [
    'type' => 'hidden',
    'name' => 'courseid',
    'value' => $courseid,
]);

echo html_writer::tag(
    'button',
    get_string('search', 'block_course_search'),
    ['type' => 'submit', 'class' => 'btn btn-primary mt-2']
);

echo html_writer::end_tag('form');
echo html_writer::end_tag('div');

echo $OUTPUT->footer();
