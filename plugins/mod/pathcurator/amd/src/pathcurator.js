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
 * PathCurator JavaScript module
 *
 * @module     mod_pathcurator/pathcurator
 * @copyright  2025 Your Name <you@example.com>
 * @license    http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
define(['jquery'], function($) {
    return {
        init: function() {
            // Handle expand all button
            $('#pathcurator-expand-all').on('click', function() {
                $('.pathcurator-step').attr('open', 'open');
            });
            
            // Handle collapse all button
            $('#pathcurator-collapse-all').on('click', function() {
                $('.pathcurator-step').removeAttr('open');
            });
            
            // Track launched links in localStorage
            $('.pathcurator-launch-btn').on('click', function() {
                var url = $(this).data('bookmark-url');
                if (url) {
                    var launchedLinks = JSON.parse(localStorage.getItem('pathcurator_launched') || '[]');
                    if (!launchedLinks.includes(url)) {
                        launchedLinks.push(url);
                        localStorage.setItem('pathcurator_launched', JSON.stringify(launchedLinks));
                    }
                    
                    // Add launched class
                    $(this).addClass('btn-success').removeClass('btn-primary');
                }
            });
            
            // Check for previously launched links
            var launchedLinks = JSON.parse(localStorage.getItem('pathcurator_launched') || '[]');
            $('.pathcurator-launch-btn').each(function() {
                var url = $(this).data('bookmark-url');
                if (url && launchedLinks.includes(url)) {
                    $(this).addClass('btn-success').removeClass('btn-primary');
                }
            });
        }
    };
});