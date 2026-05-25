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
 * Plugin strings are defined here.
 *
 * @package     mod_pathcurator
 * @category    string
 * @copyright   2025 Your Name <you@example.com>
 * @license     http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

defined('MOODLE_INTERNAL') || die();

$string['modulename'] = 'PathCurator';
$string['modulenameplural'] = 'PathCurators';
$string['modulename_help'] = 'The PathCurator activity module enables a teacher to create learning pathways from uploaded JSON files. Each pathway consists of steps containing bookmarks with links to resources.';
$string['pluginadministration'] = 'PathCurator administration';
$string['pluginname'] = 'PathCurator';
$string['pathcurator'] = 'PathCurator';
$string['pathcurator:addinstance'] = 'Add a new PathCurator';
$string['pathcurator:view'] = 'View PathCurator';
$string['pathcuratorname'] = 'PathCurator name';
$string['pathcuratorname_help'] = 'This is the name of your learning pathway that will be displayed to students.';
$string['jsonfile'] = 'JSON pathway file';
$string['jsonfile_help'] = 'Upload a JSON file containing the pathway definition including steps and bookmarks.';
$string['required'] = 'Required';
$string['bonus'] = 'Bonus';
$string['launchlink'] = 'Launch';
$string['launched'] = 'Launched';
$string['expandall'] = 'Expand all';
$string['collapseall'] = 'Collapse all';
$string['step'] = 'Step {$a}';
$string['objective'] = 'Objective: {$a}';
$string['contentwarning'] = 'Content Warning';
$string['beforeyoubegin'] = 'Before you begin...';
$string['description'] = 'Description';
$string['resourcetype'] = 'Resource Type';
$string['context'] = 'Context';
$string['nopathwaydata'] = 'No pathway data available. Please upload a valid JSON file.';
$string['invalidjson'] = 'Invalid JSON file. Please upload a valid pathway JSON file.';
$string['eventlistviewed'] = 'PathCurator list viewed';
$string['unavailable'] = 'Unavailable';
$string['missingfields'] = 'Some bookmarks are missing required fields and will not be displayed';
$string['nosteps'] = 'No steps found in this pathway';
$string['nobookmarks'] = 'No bookmarks found in this step';
$string['searchpathway'] = 'Search pathway';
$string['searchplaceholder'] = 'Search steps and bookmarks...';
$string['clearsearch'] = 'Clear search';
$string['acknowledgments'] = 'Acknowledgments';
$string['pausereflect'] = 'Pause and Reflect';
$string['progresstitle'] = 'Learning Progress';
$string['bonuslinks'] = 'Bonus Links';
$string['bonuslinksdesc'] = 'Launching these links does not count towards your overall progress on this path.';
$string['scrolltotop'] = 'Scroll to top';
$string['pathwaydata'] = 'Pathway Data Source';
$string['dataoptionsdesc'] = 'You can provide pathway data either by uploading a JSON file or by providing a URL to a JSON file. Choose one option only.';
$string['jsonurl'] = 'JSON URL';
$string['jsonurl_help'] = 'Enter the URL of a JSON file containing the pathway definition. The URL must be publicly accessible.';
$string['mustsupplydata'] = 'You must provide either a JSON file or a JSON URL.';
$string['onlyonedata'] = 'Please provide either a JSON file or a JSON URL, not both.';
$string['invalidurl'] = 'Please enter a valid URL.';
$string['errorloadingurl'] = 'Error loading pathway data from URL. Please check the URL is correct and accessible.';
$string['nosteps'] = 'No steps found in this pathway.';