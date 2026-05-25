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
 * View a PathCurator instance
 *
 * @package     mod_pathcurator
 * @copyright   2025 Your Name <you@example.com>
 * @license     http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */

require_once(__DIR__ . '/../../config.php');
require_once(__DIR__ . '/lib.php');

// Course module id.
$id = optional_param('id', 0, PARAM_INT);

// Activity instance id.
$p = optional_param('p', 0, PARAM_INT);

if ($id) {
    $cm = get_coursemodule_from_id('pathcurator', $id, 0, false, MUST_EXIST);
    $course = $DB->get_record('course', array('id' => $cm->course), '*', MUST_EXIST);
    $pathcurator = $DB->get_record('pathcurator', array('id' => $cm->instance), '*', MUST_EXIST);
} else {
    $pathcurator = $DB->get_record('pathcurator', array('id' => $p), '*', MUST_EXIST);
    $course = $DB->get_record('course', array('id' => $pathcurator->course), '*', MUST_EXIST);
    $cm = get_coursemodule_from_instance('pathcurator', $pathcurator->id, $course->id, false, MUST_EXIST);
}

require_login($course, true, $cm);

$modulecontext = context_module::instance($cm->id);

$event = \mod_pathcurator\event\course_module_viewed::create(array(
    'objectid' => $pathcurator->id,
    'context' => $modulecontext
));
$event->add_record_snapshot('course', $course);
$event->add_record_snapshot('course_modules', $cm);
$event->add_record_snapshot('pathcurator', $pathcurator);
$event->trigger();

// Mark viewed if required.
$completion = new completion_info($course);
$completion->set_module_viewed($cm);

$PAGE->set_url('/mod/pathcurator/view.php', array('id' => $cm->id));
$PAGE->set_title(format_string($pathcurator->name));
$PAGE->set_heading(format_string($course->fullname));
$PAGE->set_context($modulecontext);

// Add CSS.
$PAGE->requires->css(new moodle_url('/mod/pathcurator/styles.css'));

// Add JavaScript for interactivity.
$PAGE->requires->jquery();
$PAGE->requires->js_amd_inline("
require(['jquery'], function($) {
    $(document).ready(function() {
        // Handle expand all button
        $('#pathcurator-expand-all').on('click', function() {
            $('.pathcurator-step').attr('open', 'open');
        });
        
        // Handle collapse all button
        $('#pathcurator-collapse-all').on('click', function() {
            $('.pathcurator-step').removeAttr('open');
        });
        
        // Handle clear search button
        $('#pathcurator-clear-search').on('click', function() {
            $('#pathcurator-search').val('');
            searchPathway();
        });
        
        // Handle search input
        $('#pathcurator-search').on('input', function() {
            searchPathway();
        });
        
        // Search functionality
        function searchPathway() {
            var searchTerm = $('#pathcurator-search').val().toLowerCase().trim();
            var matchCount = 0;
            var totalSteps = $('.pathcurator-step').length;
            
            if (searchTerm === '') {
                // Show all steps and bookmarks
                $('.pathcurator-step').show();
                $('.card.mb-3').show();
                $('.pathcurator-bonus-section').show();
                $('.search-highlight').each(function() {
                    var text = $(this).text();
                    $(this).replaceWith(text);
                });
                $('#pathcurator-search-results').text('');
                $('#pathcurator-clear-search').hide();
                return;
            }
            
            // Show clear search button when search is active
            $('#pathcurator-clear-search').show();
            
            // Search through each step
            $('.pathcurator-step').each(function() {
                var stepElement = $(this);
                var stepHasMatch = false;
                var stepName = stepElement.find('summary').text().toLowerCase();
                
                // Check if step name matches
                if (stepName.indexOf(searchTerm) !== -1) {
                    stepHasMatch = true;
                }
                
                // Search through bookmarks in this step
                stepElement.find('.card.mb-3').each(function() {
                    var bookmarkElement = $(this);
                    var bookmarkHasMatch = false;
                    
                    // Get all text content from bookmark
                    var title = bookmarkElement.find('.card-title').text().toLowerCase();
                    var description = bookmarkElement.find('.card-text').text().toLowerCase();
                    var context = bookmarkElement.find('small').text().toLowerCase();
                    var allText = title + ' ' + description + ' ' + context;
                    
                    // Check for matches
                    if (allText.indexOf(searchTerm) !== -1) {
                        bookmarkHasMatch = true;
                        stepHasMatch = true;
                    }
                    
                    // Show/hide bookmark based on match
                    if (bookmarkHasMatch) {
                        bookmarkElement.show();
                        highlightText(bookmarkElement, searchTerm);
                    } else {
                        bookmarkElement.hide();
                    }
                });
                
                // Check if bonus section should be visible
                var bonusSection = stepElement.find('.pathcurator-bonus-section');
                if (bonusSection.length > 0) {
                    var visibleBonusLinks = bonusSection.find('.card.mb-3:visible').length;
                    if (visibleBonusLinks > 0) {
                        bonusSection.show();
                    } else {
                        bonusSection.hide();
                    }
                }
                
                // Show/hide step based on match
                if (stepHasMatch) {
                    stepElement.show();
                    stepElement.attr('open', 'open'); // Expand matching steps
                    matchCount++;
                    highlightText(stepElement.find('summary'), searchTerm);
                } else {
                    stepElement.hide();
                }
            });
            
            // Update search results
            var resultsText = '';
            if (matchCount === 0) {
                resultsText = 'No results found for \"' + $('#pathcurator-search').val() + '\"';
            } else {
                resultsText = 'Found ' + matchCount + ' of ' + totalSteps + ' steps matching \"' + $('#pathcurator-search').val() + '\"';
            }
            $('#pathcurator-search-results').text(resultsText);
        }
        
        // Highlight matching text
        function highlightText(element, searchTerm) {
            if (searchTerm === '') return;
            
            // Store original text content before any highlighting
            if (!element.data('original-html')) {
                element.data('original-html', element.html());
            }
            
            // Restore original content to remove all previous highlights
            element.html(element.data('original-html'));
            
            // Only highlight if search term is 3+ characters to avoid breaking HTML
            if (searchTerm.length < 3) {
                return;
            }
            
            // Walk through text nodes only to avoid breaking HTML structure
            element.find('*').addBack().contents().filter(function() {
                return this.nodeType === 3; // Text nodes only
            }).each(function() {
                var textNode = this;
                var text = textNode.nodeValue;
                var lowerText = text.toLowerCase();
                var lowerSearchTerm = searchTerm.toLowerCase();
                
                if (lowerText.indexOf(lowerSearchTerm) !== -1) {
                    var parent = $(textNode.parentNode);
                    if (!parent.hasClass('search-highlight')) {
                        var highlightedText = text.replace(new RegExp(searchTerm, 'gi'), '<span class=\"search-highlight\">$&</span>');
                        $(textNode).replaceWith(highlightedText);
                    }
                }
            });
        }
        
        // Cookie helper functions
        function setCookie(name, value, days) {
            var expires = '';
            if (days) {
                var date = new Date();
                date.setTime(date.getTime() + (days * 24 * 60 * 60 * 1000));
                expires = '; expires=' + date.toUTCString();
            }
            document.cookie = name + '=' + (value || '') + expires + '; path=/; SameSite=Lax';
        }
        
        function getCookie(name) {
            var nameEQ = name + '=';
            var ca = document.cookie.split(';');
            for (var i = 0; i < ca.length; i++) {
                var c = ca[i];
                while (c.charAt(0) === ' ') c = c.substring(1, c.length);
                if (c.indexOf(nameEQ) === 0) return c.substring(nameEQ.length, c.length);
            }
            return null;
        }
        
        function getLaunchedLinks() {
            var cookieData = getCookie('pathcurator_launched');
            try {
                return cookieData ? JSON.parse(decodeURIComponent(cookieData)) : [];
            } catch (e) {
                return [];
            }
        }
        
        function saveLaunchedLinks(links) {
            setCookie('pathcurator_launched', encodeURIComponent(JSON.stringify(links)), 365); // 1 year expiry
        }
        
        // Progress tracking functions
        function updateProgress() {
            var totalRequiredLinks = 0;
            var launchedLinks = getLaunchedLinks();
            var requiredPageLinks = [];
            
            $('.pathcurator-launch-btn').each(function() {
                var url = $(this).data('bookmark-url');
                var requiredAttr = $(this).data('bookmark-required');
                // Handle both string 'true'/'false' and boolean true/false
                var isRequired = requiredAttr === 'true' || requiredAttr === true;
                if (url && isRequired) {
                    requiredPageLinks.push(url);
                    totalRequiredLinks++;
                }
            });
            
            var launchedRequiredCount = 0;
            requiredPageLinks.forEach(function(url) {
                if (launchedLinks.includes(url)) {
                    launchedRequiredCount++;
                }
            });
            
            var percentage = totalRequiredLinks > 0 ? Math.round((launchedRequiredCount / totalRequiredLinks) * 100) : 0;
            
            $('#pathcurator-progress-bar').css('width', percentage + '%').attr('aria-valuenow', percentage);
            $('#pathcurator-progress-text').text(launchedRequiredCount + ' of ' + totalRequiredLinks + ' required links launched (' + percentage + '%)');
        }
        
        // Function to update step badges
        function updateStepBadges() {
            var launchedLinks = getLaunchedLinks();
            
            // Update each step's launched badge
            $('.pathcurator-step').each(function(stepIndex) {
                var launchedInStep = 0;
                
                // Count launched links in this step
                $(this).find('.pathcurator-launch-btn').each(function() {
                    var url = $(this).data('bookmark-url');
                    if (url && launchedLinks.includes(url)) {
                        launchedInStep++;
                    }
                });
                
                // Update the badge for this step
                $('.step-launched-badge[data-step-index=\"' + stepIndex + '\"]').text('Launched ' + launchedInStep);
            });
        }
        
        // Track launched links in cookies
        $('.pathcurator-launch-btn').on('click', function() {
            var url = $(this).data('bookmark-url');
            if (url) {
                var launchedLinks = getLaunchedLinks();
                if (!launchedLinks.includes(url)) {
                    launchedLinks.push(url);
                    saveLaunchedLinks(launchedLinks);
                }
                
                // Add launched class
                $(this).addClass('btn-success').removeClass('btn-primary');
                
                // Update progress
                updateProgress();
                
                // Update step badges
                updateStepBadges();
            }
        });
        
        // Check for previously launched links and update progress
        var launchedLinks = getLaunchedLinks();
        $('.pathcurator-launch-btn').each(function() {
            var url = $(this).data('bookmark-url');
            if (url && launchedLinks.includes(url)) {
                $(this).addClass('btn-success').removeClass('btn-primary');
            }
        });
        
        // Update step badges on page load
        updateStepBadges();
        
        // Scroll to top functionality
        $(document).on('click', '#pathcurator-scroll-top', function(e) {
            e.preventDefault();
            e.stopPropagation();
            console.log('Scroll to top clicked');
            
            // Method 1: Scroll to the top of the page header
            var pageHeader = $('#page-header');
            if (pageHeader.length) {
                pageHeader[0].scrollIntoView({ behavior: 'smooth', block: 'start' });
                return false;
            }
            
            // Method 2: Scroll to top of the PathCurator content
            var pathcuratorIntro = $('#pathcuratorintro');
            if (pathcuratorIntro.length) {
                pathcuratorIntro[0].scrollIntoView({ behavior: 'smooth', block: 'start' });
                return false;
            }
            
            // Method 3: Force scroll all possible containers
            $('html, body').scrollTop(0);
            $('#page-wrapper').scrollTop(0);
            $('#page').scrollTop(0);
            $('#region-main').scrollTop(0);
            $('.main-inner').scrollTop(0);
            document.documentElement.scrollTop = 0;
            document.body.scrollTop = 0;
            window.scrollTo(0, 0);
            
            // Method 4: As a last resort, reload the page with anchor
            // window.location.href = '#';
            
            return false;
        });
        
        // Scroll to top button is always visible
        
        // Initialize progress display
        updateProgress();
        
        // Initialize step badges
        updateStepBadges();
    });
});
");

echo $OUTPUT->header();

// Start content container to wrap all activity content
echo html_writer::start_div('container-fluid');
echo html_writer::start_div('row justify-content-center');
echo html_writer::start_div('col-xl-8 col-lg-10');

// Display JSON file info for teachers/admins
if (has_capability('mod/pathcurator:addinstance', $modulecontext) || is_siteadmin()) {
    if (!empty($pathcurator->jsondata)) {
        echo html_writer::start_div('alert alert-info mb-3');
        echo html_writer::tag('h6', 'Source JSON File', array('class' => 'alert-heading mb-2'));
        echo html_writer::tag('p', 'This pathway was created using <a href="https://pathcurator.com" target="_blank">PathCurator</a>. As an instructor, you can download the source file for backup or editing purposes. Import the JSON file into PathCurator, make your edits, export to JSON, and then import here.', array('class' => 'mb-2'));
        
        // Create download link
        $downloadurl = new moodle_url('/mod/pathcurator/download.php', array('id' => $cm->id));
        echo html_writer::link($downloadurl, 
            html_writer::tag('i', '', array('class' => 'fa fa-download')) . ' Download JSON Source',
            array('class' => 'btn btn-sm btn-outline-primary')
        );
        echo html_writer::end_div();
    }
}


// Display the activity intro.
if ($pathcurator->intro) {
    echo $OUTPUT->box(format_module_intro('pathcurator', $pathcurator, $cm->id), 'generalbox mod_introbox', 'pathcuratorintro');
}

// Parse and display the pathway data.
$jsonContent = null;

// Check if we need to fetch from URL.
if (!empty($pathcurator->jsonurl)) {
    // Fetch JSON from URL.
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $pathcurator->jsonurl);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_TIMEOUT, 30);
    
    $jsonContent = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    
    if ($httpCode !== 200 || empty($jsonContent)) {
        echo html_writer::div(
            get_string('errorloadingurl', 'pathcurator'),
            'alert alert-danger'
        );
        echo $OUTPUT->footer();
        exit;
    }
} else if (!empty($pathcurator->jsondata)) {
    // Use stored JSON data.
    $jsonContent = $pathcurator->jsondata;
}

if (!empty($jsonContent)) {
    $pathwaydata = json_decode($jsonContent, true);
    
    if (json_last_error() === JSON_ERROR_NONE && !empty($pathwaydata)) {
        $pathway = reset($pathwaydata); // Get first pathway object
        
        // Display header image if present
        if (!empty($pathway['headerImage'])) {
            // Check if the image data includes data URI prefix
            $imageData = $pathway['headerImage'];
            if (strpos($imageData, 'data:image/') !== 0) {
                // Assume it's base64 encoded image data without prefix, add common image prefix
                $imageData = 'data:image/png;base64,' . $imageData;
            }
            
            echo html_writer::div(
                html_writer::img($imageData, 'Pathway Header Image', array(
                    'class' => 'pathcurator-header-image img-fluid',
                    'style' => 'max-height: 300px; width: 100%; object-fit: cover; border-radius: 8px;'
                )),
                'pathcurator-header-container mb-4'
            );
        }
        
        // Display content warning if present.
        if (!empty($pathway['contentWarning'])) {
            echo html_writer::tag('details',
                html_writer::tag('summary', get_string('beforeyoubegin', 'pathcurator'), array('class' => 'alert alert-warning mb-0')) .
                html_writer::div(
                    format_text($pathway['contentWarning'], FORMAT_MARKDOWN),
                    'alert alert-warning mt-0 mb-4'
                ),
                array('class' => 'pathcurator-content-warning mb-3')
            );
        }
        
        // Display pathway description if present.
        if (!empty($pathway['description'])) {
            echo html_writer::div(
                html_writer::div(format_text($pathway['description']), ''),
                'card card-body bg-light mb-4'
            );
        }
        
        // Sticky control bar
        echo html_writer::start_div('sticky-top bg-white shadow-sm mb-4', array('style' => 'z-index: 1020; padding: 15px 0;'));
        echo html_writer::start_div('container-fluid');
        echo html_writer::start_div('row justify-content-center');
        echo html_writer::start_div('col');
        
        // Progress bar section
        echo html_writer::start_div('mb-3');
        echo html_writer::start_div('row align-items-center');
        echo html_writer::start_div('col-md-8');
        echo html_writer::start_div('progress', array('style' => 'height: 25px;'));
        echo html_writer::div('', 'progress-bar progress-bar-striped bg-success', array(
            'id' => 'pathcurator-progress-bar',
            'role' => 'progressbar',
            'style' => 'width: 0%',
            'aria-valuenow' => '0',
            'aria-valuemin' => '0',
            'aria-valuemax' => '100'
        ));
        echo html_writer::end_div(); // progress
        echo html_writer::end_div(); // col-md-8
        echo html_writer::start_div('col-md-4 text-right');
        echo html_writer::tag('span', '', array(
            'id' => 'pathcurator-progress-text',
            'class' => 'font-weight-bold small'
        ));
        echo html_writer::end_div(); // col-md-4
        echo html_writer::end_div(); // row
        echo html_writer::end_div(); // mb-3
        
        // Search and controls section
        echo html_writer::start_div('row align-items-center');
        
        // Search field with clear button
        echo html_writer::start_div('col-md-6 mb-2');
        echo html_writer::tag('label', get_string('searchpathway', 'pathcurator'), 
            array('for' => 'pathcurator-search', 'class' => 'sr-only'));
        echo html_writer::start_div('input-group input-group-sm');
        echo html_writer::tag('input', '', array(
            'type' => 'text',
            'id' => 'pathcurator-search',
            'class' => 'form-control',
            'placeholder' => get_string('searchplaceholder', 'pathcurator')
        ));
        echo html_writer::start_div('input-group-append');
        echo html_writer::tag('button', '×', array(
            'class' => 'btn btn-outline-secondary',
            'type' => 'button',
            'id' => 'pathcurator-clear-search',
            'style' => 'display: none;',
            'title' => get_string('clearsearch', 'pathcurator')
        ));
        echo html_writer::end_div(); // input-group-append
        echo html_writer::end_div(); // input-group
        // Search results text below search input
        echo html_writer::tag('small', '', array('id' => 'pathcurator-search-results', 'class' => 'text-muted d-block mt-1'));
        echo html_writer::end_div(); // col-md-6
        
        // Controls and search results
        echo html_writer::start_div('col-md-6 mb-2');
        echo html_writer::start_div('d-flex justify-content-between align-items-center');
        
        // Control buttons
        echo html_writer::start_div('btn-group btn-group-sm', array('role' => 'group'));
        echo html_writer::tag('button', get_string('expandall', 'pathcurator'), 
            array('class' => 'btn btn-outline-primary btn-sm', 'id' => 'pathcurator-expand-all'));
        echo html_writer::tag('button', get_string('collapseall', 'pathcurator'), 
            array('class' => 'btn btn-outline-secondary btn-sm', 'id' => 'pathcurator-collapse-all'));
        echo html_writer::tag('button', 
            html_writer::tag('i', '', array('class' => 'fa fa-arrow-up')), 
            array(
                'class' => 'btn btn-outline-dark btn-sm',
                'id' => 'pathcurator-scroll-top',
                'title' => get_string('scrolltotop', 'pathcurator')
            )
        );
        echo html_writer::end_div(); // btn-group
        
        echo html_writer::end_div(); // d-flex
        echo html_writer::end_div(); // col-md-6
        echo html_writer::end_div(); // row
        
        echo html_writer::end_div(); // col
        echo html_writer::end_div(); // row
        echo html_writer::end_div(); // container-fluid
        echo html_writer::end_div(); // sticky-top
        
        // Display steps.
        if (!empty($pathway['steps'])) {
            echo html_writer::start_div('pathcurator-steps');
            
            $stepnum = 1;
            foreach ($pathway['steps'] as $stepIndex => $step) {
                $stephtml = '';
                
                // Count required and bonus bookmarks for this step
                $requiredCount = 0;
                $bonusCount = 0;
                if (!empty($step['bookmarks'])) {
                    foreach ($step['bookmarks'] as $bookmark) {
                        if (empty($bookmark['title']) || empty($bookmark['url'])) {
                            continue;
                        }
                        // Check both 'required' field and 'type' field for backward compatibility
                        // If type is "Bonus", it's not required
                        // Otherwise, default to true if 'required' field is not present
                        if (isset($bookmark['type']) && strtolower($bookmark['type']) === 'bonus') {
                            $isRequired = false;
                        } else {
                            $isRequired = !isset($bookmark['required']) || $bookmark['required'] === true;
                        }
                        if ($isRequired) {
                            $requiredCount++;
                        } else {
                            $bonusCount++;
                        }
                    }
                }
                
                // Step header with objective.
                $stepheader = html_writer::start_span('pathcurator-step-header-content');
                $stepheader .= html_writer::tag('span', get_string('step', 'pathcurator', $stepnum) . ': ' . $step['name'], array('class' => 'step-title', 'style' => 'font-size: 18px'));
                
                // Add badges
                $stepheader .= html_writer::start_span('step-badges ml-3');
                $stepheader .= html_writer::tag('span', get_string('required', 'pathcurator') . ' ' . $requiredCount, 
                    array('class' => 'badge badge-primary mr-1'));
                $stepheader .= html_writer::tag('span', get_string('bonus', 'pathcurator') . ' ' . $bonusCount, 
                    array('class' => 'badge badge-secondary mr-1'));
                $stepheader .= html_writer::tag('span', get_string('launched', 'pathcurator') . ' 0', 
                    array('class' => 'badge badge-success step-launched-badge', 'data-step-index' => $stepIndex));
                $stepheader .= html_writer::end_span(); // step-badges
                $stepheader .= html_writer::end_span(); // pathcurator-step-header-content
                
                // Add objective or why as a separate block outside the flex container
                $stepObjective = !empty($step['objective']) ? $step['objective'] : (!empty($step['why']) ? $step['why'] : '');
                if (!empty($stepObjective)) {
                    $stepheader .= html_writer::tag('span', 
                        format_text($stepObjective, FORMAT_MARKDOWN),
                        array('class' => 'd-block h6 mt-2 pr-5 text-dark pathcurator-step-objective')
                    );
                }
                
                // Step content.
                $stepcontent = '';
                
                // Add bookmarks.
                if (!empty($step['bookmarks'])) {
                    // Separate required and bonus bookmarks
                    $requiredBookmarks = array();
                    $bonusBookmarks = array();
                    
                    foreach ($step['bookmarks'] as $bookmark) {
                        // Skip bookmarks missing essential fields
                        if (empty($bookmark['title']) || empty($bookmark['url'])) {
                            continue;
                        }
                        
                        // Check both 'required' field and 'type' field for backward compatibility
                        // If type is "Bonus", it's not required
                        // Otherwise, default to true if 'required' field is not present
                        if (isset($bookmark['type']) && strtolower($bookmark['type']) === 'bonus') {
                            $isRequired = false;
                        } else {
                            $isRequired = !isset($bookmark['required']) || $bookmark['required'] === true;
                        }
                        if ($isRequired) {
                            $requiredBookmarks[] = $bookmark;
                        } else {
                            $bonusBookmarks[] = $bookmark;
                        }
                    }
                    
                    $bookmarkshtml = '';
                    
                    // Function to render a bookmark
                    $renderBookmark = function($bookmark) use ($stepIndex) {
                        // Check both 'required' field and 'type' field for backward compatibility
                        // If type is "Bonus", it's not required
                        // Otherwise, default to true if 'required' field is not present
                        if (isset($bookmark['type']) && strtolower($bookmark['type']) === 'bonus') {
                            $isRequired = false;
                        } else {
                            $isRequired = !isset($bookmark['required']) || $bookmark['required'] === true;
                        }
                        $borderclass = $isRequired ? 'border-primary' : 'border-secondary';
                        
                        $bookmarkhtml = html_writer::start_div('card mb-3 ' . $borderclass);
                        $bookmarkhtml .= html_writer::start_div('card-body bg-light');
                        
                        // Badges at the top.
                        $badges = html_writer::start_div('mb-2');
                        
                        // Required/Bonus badge.
                        $typebadgeclass = 'badge badge-' . ($isRequired ? 'primary' : 'secondary');
                        $typeLabel = $isRequired ? get_string('required', 'pathcurator') : get_string('bonus', 'pathcurator');
                        $badges .= html_writer::tag('span', $typeLabel, 
                            array('class' => $typebadgeclass));
                        
                        // Content type badge if present.
                        if (!empty($bookmark['contentType'])) {
                            $badges .= ' ' . html_writer::tag('span', ucwords($bookmark['contentType']), 
                                array('class' => 'badge badge-dark ml-1'));
                        }
                        
                        $badges .= html_writer::end_div();
                        $bookmarkhtml .= $badges;
                        
                        // Title below badges.
                        $bookmarkhtml .= html_writer::tag('h5', $bookmark['title'], 
                            array('class' => 'card-title mb-2'));
                        
                        // Description.
                        if (!empty($bookmark['description'])) {
                            $bookmarkhtml .= html_writer::tag('p', $bookmark['description'], 
                                array('class' => 'card-text'));
                        }
                        
                        // Context.
                        if (!empty($bookmark['context'])) {
                            $bookmarkhtml .= html_writer::div(
                                html_writer::tag('small', 
                                    html_writer::tag('strong', get_string('context', 'pathcurator') . ': ') . 
                                    $bookmark['context']
                                ),
                                'alert alert-light py-2 px-3 mb-3'
                            );
                        }
                        
                        // Launch button - always functional.
                        if (!empty($bookmark['url'])) {
                            $bookmarkhtml .= html_writer::tag('a', get_string('launchlink', 'pathcurator'), 
                                array(
                                    'href' => $bookmark['url'],
                                    'target' => '_blank',
                                    'class' => 'btn btn-primary pathcurator-launch-btn',
                                    'data-bookmark-url' => $bookmark['url'],
                                    'data-bookmark-required' => $isRequired ? 'true' : 'false',
                                    'data-step-index' => $stepIndex
                                )
                            );
                        }
                        
                        $bookmarkhtml .= html_writer::end_div(); // card-body
                        $bookmarkhtml .= html_writer::end_div(); // card
                        return $bookmarkhtml;
                    };
                    
                    // Render required bookmarks first
                    foreach ($requiredBookmarks as $bookmark) {
                        $bookmarkshtml .= $renderBookmark($bookmark);
                    }
                    
                    // Add bonus section header and render bonus bookmarks
                    if (!empty($bonusBookmarks)) {
                        $bookmarkshtml .= html_writer::start_div('pathcurator-bonus-section');
                        $bookmarkshtml .= html_writer::tag('h4', get_string('bonuslinks', 'pathcurator'), 
                            array('class' => 'mb-2'));
                        $bookmarkshtml .= html_writer::tag('p', get_string('bonuslinksdesc', 'pathcurator'), 
                            array('class' => 'text-muted mb-3'));
                        
                        foreach ($bonusBookmarks as $bookmark) {
                            $bookmarkshtml .= $renderBookmark($bookmark);
                        }
                        $bookmarkshtml .= html_writer::end_div();
                    }
                    
                    if (!empty($bookmarkshtml)) {
                        $stepcontent .= html_writer::div($bookmarkshtml, 'pathcurator-bookmarks');
                    } else {
                        $stepcontent .= html_writer::div(
                            html_writer::tag('p', get_string('nobookmarks', 'pathcurator'), array('class' => 'text-muted')),
                            'alert alert-info'
                        );
                    }
                } else {
                    $stepcontent .= html_writer::div(
                        html_writer::tag('p', get_string('nobookmarks', 'pathcurator'), array('class' => 'text-muted')),
                        'alert alert-info'
                    );
                }
                
                // Add acknowledgments if present (check multiple possible field names).
                $acknowledgmentText = '';
                if (!empty($step['acknowledgments'])) {
                    $acknowledgmentText = $step['acknowledgments'];
                } elseif (!empty($step['acknowledgements'])) {
                    $acknowledgmentText = $step['acknowledgements'];
                } elseif (!empty($step['acknowledgment'])) {
                    $acknowledgmentText = $step['acknowledgment'];
                } elseif (!empty($step['acknowledge'])) {
                    $acknowledgmentText = $step['acknowledge'];
                }
                
                if (!empty($acknowledgmentText)) {
                    $stepcontent .= html_writer::div(
                        html_writer::tag('h5', get_string('acknowledgments', 'pathcurator'), array('class' => 'mb-2')) .
                        html_writer::div(format_text($acknowledgmentText, FORMAT_MARKDOWN)),
                        'card card-body bg-light mb-3'
                    );
                }
                
                // Add pause and reflect if present.
                if (!empty($step['pauseAndReflect'])) {
                    $stepcontent .= html_writer::div(
                        html_writer::tag('h5', get_string('pausereflect', 'pathcurator'), array('class' => 'mb-2')) .
                        html_writer::div(format_text($step['pauseAndReflect'], FORMAT_MARKDOWN)),
                        'card card-body pathcurator-pause-reflect mb-3'
                    );
                }
                
                // Create collapsible step using details/summary.
                $stephtml = html_writer::tag('details',
                    html_writer::tag('summary', $stepheader, array('class' => 'pathcurator-step-header')) .
                    html_writer::div($stepcontent, 'pathcurator-step-content'),
                    array('class' => 'pathcurator-step')
                );
                
                echo $stephtml;
                $stepnum++;
            }
            
            echo html_writer::end_div();
        } else {
            echo $OUTPUT->notification(get_string('nosteps', 'pathcurator'), 'info');
        }
        
        // Add pathway-level acknowledgments if present (check multiple possible field names).
        $acknowledgmentText = '';
        if (!empty($pathway['acknowledgments'])) {
            $acknowledgmentText = $pathway['acknowledgments'];
        } elseif (!empty($pathway['acknowledgements'])) {
            $acknowledgmentText = $pathway['acknowledgements'];
        } elseif (!empty($pathway['acknowledgment'])) {
            $acknowledgmentText = $pathway['acknowledgment'];
        } elseif (!empty($pathway['acknowledge'])) {
            $acknowledgmentText = $pathway['acknowledge'];
        }
        
        if (!empty($acknowledgmentText)) {
            echo html_writer::div(
                html_writer::tag('h4', get_string('acknowledgments', 'pathcurator'), array('class' => 'mb-3')) .
                html_writer::div(format_text($acknowledgmentText, FORMAT_MARKDOWN)),
                'card card-body bg-light mt-4'
            );
        }
        
    } else {
        echo $OUTPUT->notification(get_string('invalidjson', 'pathcurator'), 'error');
    }
} else {
    echo $OUTPUT->notification(get_string('nopathwaydata', 'pathcurator'), 'info');
}

// End content container
echo html_writer::end_div(); // col
echo html_writer::end_div(); // row
echo html_writer::end_div(); // container-fluid

echo $OUTPUT->footer();