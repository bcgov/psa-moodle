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
 * Library functions for course search block.
 *
 * @package   block_course_search
 * @copyright 2025 Your Name
 * @license   http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

/**
 * Perform search across course content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_perform_search($query, $courseid) {
    global $DB;

    if (empty($query)) {
        return [];
    }

    $results = [];

    // Search in course modules (activities and resources) - basic info.
    $results = array_merge($results, block_course_search_search_modules($query, $courseid));

    // Search in specific module content.
    $results = array_merge($results, block_course_search_search_forum_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_book_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_quiz_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_lesson_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_wiki_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_glossary_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_workshop_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_feedback_content($query, $courseid));
    $results = array_merge($results, block_course_search_search_data_content($query, $courseid));

    return $results;
}

/**
 * Search in course modules (activities and resources).
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_modules($query, $courseid) {
    global $DB;

    $results = [];

    // Search in course module names and descriptions.
    $titlecoalesce = 'COALESCE(a.name, r.name, f.name, p.name, q.name, w.name, l.name, b.name)';
    $introcoalesce = 'COALESCE(a.intro, r.intro, f.intro, p.intro, q.intro, w.intro, l.intro, b.intro)';
    $sql = "SELECT cm.id, cm.module, cm.instance, m.name as modulename,
                   $titlecoalesce as title,
                   $introcoalesce as intro
            FROM {course_modules} cm
            JOIN {modules} m ON cm.module = m.id
            LEFT JOIN {assign} a ON cm.module = (SELECT id FROM {modules} WHERE name = 'assign') AND cm.instance = a.id
            LEFT JOIN {resource} r ON cm.module = (SELECT id FROM {modules} WHERE name = 'resource') AND cm.instance = r.id
            LEFT JOIN {forum} f ON cm.module = (SELECT id FROM {modules} WHERE name = 'forum') AND cm.instance = f.id
            LEFT JOIN {page} p ON cm.module = (SELECT id FROM {modules} WHERE name = 'page') AND cm.instance = p.id
            LEFT JOIN {quiz} q ON cm.module = (SELECT id FROM {modules} WHERE name = 'quiz') AND cm.instance = q.id
            LEFT JOIN {workshop} w ON cm.module = (SELECT id FROM {modules} WHERE name = 'workshop') AND cm.instance = w.id
            LEFT JOIN {label} l ON cm.module = (SELECT id FROM {modules} WHERE name = 'label') AND cm.instance = l.id
            LEFT JOIN {book} b ON cm.module = (SELECT id FROM {modules} WHERE name = 'book') AND cm.instance = b.id
            WHERE cm.course = ? AND cm.visible = 1 AND cm.deletioninprogress = 0
            AND (" . $DB->sql_like($titlecoalesce, '?', false) . "
            OR " . $DB->sql_like($introcoalesce, '?', false) . ")
            ORDER BY $titlecoalesce";

    $searchterm = '%' . $query . '%';
    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->id])) {
            $cm = $modinfo->cms[$record->id];

            $result = new stdClass();
            $result->title = $record->title;
            $result->type = get_string('modulename', $record->modulename);
            $result->content = $record->intro;
            $result->url = $cm->url;
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in forum content (discussions and posts).
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_forum_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if forum module exists.
    if (!$DB->record_exists('modules', ['name' => 'forum'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in forum posts.
    $sql = "SELECT fp.id, fp.subject, fp.message, fd.name as discussionname,
                   f.name as forumname, cm.id as cmid, fd.id as discussionid
            FROM {forum_posts} fp
            JOIN {forum_discussions} fd ON fp.discussion = fd.id
            JOIN {forum} f ON fd.forum = f.id
            JOIN {course_modules} cm ON f.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE f.course = ? AND cm.visible = 1 AND m.name = 'forum'
            AND (" . $DB->sql_like('fp.subject', '?', false) . " OR " . $DB->sql_like('fp.message', '?', false) . ")
            ORDER BY fp.subject";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->subject . ' (' . $record->forumname . ')';
            $result->type = get_string('modulename', 'forum') . ' - ' . get_string('post', 'forum');
            $result->content = $record->message;
            $result->url = new moodle_url('/mod/forum/discuss.php', ['d' => $record->discussionid]);
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in book content (chapters).
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_book_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if book module exists.
    if (!$DB->record_exists('modules', ['name' => 'book'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in book chapters.
    $sql = "SELECT bc.id, bc.title, bc.content, b.name as bookname, cm.id as cmid, bc.pagenum
            FROM {book_chapters} bc
            JOIN {book} b ON bc.bookid = b.id
            JOIN {course_modules} cm ON b.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE b.course = ? AND cm.visible = 1 AND m.name = 'book' AND bc.hidden = 0
            AND (" . $DB->sql_like('bc.title', '?', false) . " OR " . $DB->sql_like('bc.content', '?', false) . ")
            ORDER BY b.name, bc.pagenum";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->title . ' (' . $record->bookname . ')';
            $result->type = get_string('modulename', 'book') . ' - ' . get_string('chapter', 'block_course_search');
            $result->content = $record->content;
            $result->url = new moodle_url('/mod/book/view.php', ['id' => $cm->id, 'chapterid' => $record->id]);
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in quiz questions and feedback.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_quiz_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if quiz module exists.
    if (!$DB->record_exists('modules', ['name' => 'quiz'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in quiz feedback.
    $sql = "SELECT qf.id, qf.feedbacktext, qf.mingrade, qf.maxgrade, qz.name as quizname, cm.id as cmid
            FROM {quiz_feedback} qf
            JOIN {quiz} qz ON qf.quizid = qz.id
            JOIN {course_modules} cm ON qz.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE qz.course = ? AND cm.visible = 1 AND m.name = 'quiz'
            AND " . $DB->sql_like('qf.feedbacktext', '?', false) . "
            ORDER BY qz.name";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = get_string('feedback', 'quiz') . ' (' . $record->quizname . ')';
            $result->type = get_string('modulename', 'quiz') . ' - ' . get_string('feedback', 'quiz');
            $result->content = $record->feedbacktext;
            $result->url = $cm->url;
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in lesson content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_lesson_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if lesson module exists.
    if (!$DB->record_exists('modules', ['name' => 'lesson'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in lesson pages.
    $sql = "SELECT lp.id, lp.title, lp.contents, l.name as lessonname, cm.id as cmid
            FROM {lesson_pages} lp
            JOIN {lesson} l ON lp.lessonid = l.id
            JOIN {course_modules} cm ON l.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE l.course = ? AND cm.visible = 1 AND m.name = 'lesson'
            AND (" . $DB->sql_like('lp.title', '?', false) . " OR " . $DB->sql_like('lp.contents', '?', false) . ")
            ORDER BY l.name, lp.title";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->title . ' (' . $record->lessonname . ')';
            $result->type = get_string('modulename', 'lesson') . ' - ' . get_string('page', 'lesson');
            $result->content = $record->contents;
            $result->url = $cm->url;
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in wiki content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_wiki_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if wiki module exists.
    if (!$DB->record_exists('modules', ['name' => 'wiki'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in wiki pages.
    $sql = "SELECT wp.id, wp.title, wp.cachedcontent, w.name as wikiname, cm.id as cmid
            FROM {wiki_pages} wp
            JOIN {wiki_subwikis} ws ON wp.subwikiid = ws.id
            JOIN {wiki} w ON ws.wikiid = w.id
            JOIN {course_modules} cm ON w.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE w.course = ? AND cm.visible = 1 AND m.name = 'wiki'
            AND (" . $DB->sql_like('wp.title', '?', false) . " OR " . $DB->sql_like('wp.cachedcontent', '?', false) . ")
            ORDER BY w.name, wp.title";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->title . ' (' . $record->wikiname . ')';
            $result->type = get_string('modulename', 'wiki') . ' - ' . get_string('page', 'wiki');
            $result->content = $record->cachedcontent;
            $result->url = new moodle_url('/mod/wiki/view.php', ['pageid' => $record->id]);
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in glossary content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_glossary_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if glossary module exists.
    if (!$DB->record_exists('modules', ['name' => 'glossary'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in glossary entries.
    $sql = "SELECT ge.id, ge.concept, ge.definition, g.name as glossaryname, cm.id as cmid
            FROM {glossary_entries} ge
            JOIN {glossary} g ON ge.glossaryid = g.id
            JOIN {course_modules} cm ON g.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE g.course = ? AND cm.visible = 1 AND m.name = 'glossary'
            AND (" . $DB->sql_like('ge.concept', '?', false) . " OR " . $DB->sql_like('ge.definition', '?', false) . ")
            ORDER BY g.name, ge.concept";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->concept . ' (' . $record->glossaryname . ')';
            $result->type = get_string('modulename', 'glossary') . ' - ' . get_string('entry', 'glossary');
            $result->content = $record->definition;
            $result->url = new moodle_url('/mod/glossary/showentry.php', ['eid' => $record->id]);
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in workshop content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_workshop_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if workshop module exists.
    if (!$DB->record_exists('modules', ['name' => 'workshop'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in workshop submissions.
    $sql = "SELECT ws.id, ws.title, ws.content, w.name as workshopname, cm.id as cmid
            FROM {workshop_submissions} ws
            JOIN {workshop} w ON ws.workshopid = w.id
            JOIN {course_modules} cm ON w.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE w.course = ? AND cm.visible = 1 AND m.name = 'workshop'
            AND (" . $DB->sql_like('ws.title', '?', false) . " OR " . $DB->sql_like('ws.content', '?', false) . ")
            ORDER BY w.name, ws.title";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->title . ' (' . $record->workshopname . ')';
            $result->type = get_string('modulename', 'workshop') . ' - ' . get_string('submission', 'workshop');
            $result->content = $record->content;
            $result->url = new moodle_url('/mod/workshop/submission.php', ['id' => $record->id]);
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in feedback content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_feedback_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if feedback module exists.
    if (!$DB->record_exists('modules', ['name' => 'feedback'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in feedback items.
    $sql = "SELECT fi.id, fi.name, fi.presentation, f.name as feedbackname, cm.id as cmid
            FROM {feedback_item} fi
            JOIN {feedback} f ON fi.feedback = f.id
            JOIN {course_modules} cm ON f.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE f.course = ? AND cm.visible = 1 AND m.name = 'feedback'
            AND (" . $DB->sql_like('fi.name', '?', false) . " OR " . $DB->sql_like('fi.presentation', '?', false) . ")
            ORDER BY f.name, fi.name";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = $record->name . ' (' . $record->feedbackname . ')';
            $result->type = get_string('modulename', 'feedback') . ' - ' . get_string('item', 'feedback');
            $result->content = $record->presentation;
            $result->url = $cm->url;
            $results[] = $result;
        }
    }

    return $results;
}

/**
 * Search in database (data module) content.
 *
 * @param string $query The search query
 * @param int $courseid The course ID
 * @return array Array of search results
 */
function block_course_search_search_data_content($query, $courseid) {
    global $DB;

    $results = [];

    // Check if data module exists.
    if (!$DB->record_exists('modules', ['name' => 'data'])) {
        return $results;
    }

    $searchterm = '%' . $query . '%';

    // Search in database content.
    $sql = "SELECT dc.id, dc.content, d.name as dataname, cm.id as cmid, dr.id as recordid
            FROM {data_content} dc
            JOIN {data_records} dr ON dc.recordid = dr.id
            JOIN {data} d ON dr.dataid = d.id
            JOIN {course_modules} cm ON d.id = cm.instance
            JOIN {modules} m ON cm.module = m.id
            WHERE d.course = ? AND cm.visible = 1 AND m.name = 'data'
            AND " . $DB->sql_like('dc.content', '?', false) . "
            ORDER BY d.name, dc.content";

    $records = $DB->get_records_sql($sql, [$courseid, $searchterm]);

    foreach ($records as $record) {
        $modinfo = get_fast_modinfo($courseid);
        if (isset($modinfo->cms[$record->cmid])) {
            $cm = $modinfo->cms[$record->cmid];

            $result = new stdClass();
            $result->title = shorten_text(strip_tags($record->content), 50) . ' (' . $record->dataname . ')';
            $result->type = get_string('modulename', 'data') . ' - ' . get_string('record', 'data');
            $result->content = $record->content;
            $result->url = new moodle_url('/mod/data/view.php', ['id' => $cm->id, 'rid' => $record->recordid]);
            $results[] = $result;
        }
    }

    return $results;
}
