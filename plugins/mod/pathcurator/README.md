# PathCurator for Moodle

A comprehensive Moodle LMS plugin that transforms JSON pathway data into interactive, trackable learning activities. Perfect for creating guided learning paths with required and bonus content, progress tracking, and responsive design.

## Overview

PathCurator enables educators to create structured learning pathways by importing JSON files or connecting to external JSON data sources. The plugin displays content as collapsible steps with bookmarks, tracks student progress, and provides search functionality for easy navigation.

## Features

### 🎯 **Structured Learning Paths**
- **Multi-step pathways** with collapsible sections
- **Required and bonus content** separation with visual distinction
- **Progress tracking** showing completion percentage
- **Header images** support for branded pathway presentations

### 🔍 **Advanced Search & Navigation**
- **Real-time search** through pathway content with highlighting
- **Smart filtering** that hides empty sections during search
- **Expand/collapse all** controls for easy navigation
- **Scroll to top** functionality for long pathways

### 📊 **Progress Monitoring**
- **Cookie-based tracking** of launched links
- **Visual progress bar** showing completion status
- **Step-level badges** indicating required, bonus, and launched counts
- **Persistent state** maintained across sessions

### 🎨 **Modern UI/UX**
- **Bootstrap 5.3+ compatible** with dark mode support
- **Responsive design** works on all screen sizes
- **Accessibility focused** with semantic HTML and ARIA support
- **Visual indicators** with color-coded borders (blue for required, grey for bonus)

### 🔌 **Flexible Content Sources**
- **JSON file upload** for static content
- **Public URL sourcing** for dynamic content updates
- **Backup and restore** capabilities for instructors

## Installation

### Requirements
- Moodle 4.0 or higher
- PHP 7.4 or higher
- Bootstrap 5.3+ theme (recommended)

### Installation Steps

1. **Download the plugin** files to your Moodle installation:
   ```
   /path/to/moodle/mod/pathcurator/
   ```

2. **Log in as administrator** and navigate to:
   ```
   Site Administration → Notifications
   ```

3. **Follow the installation prompts** to complete the database setup.

4. **Verify installation** by checking that "PathCurator" appears in:
   ```
   Site Administration → Plugins → Activity modules
   ```

## Usage Guide

### Setting Up a Course

The PathCurator plugin works exceptionally well with Moodle's **single-activity course format**:

1. **Create a new course**
2. **Go to Course Settings**
3. **Set Course Format to**: `Single activity format`
4. **Set Activity type to**: `PathCurator`
5. **Configure your PathCurator activity** (see below)

### Creating a PathCurator Activity

1. **Add PathCurator Activity**:
   - In your course, click "Turn editing on"
   - Add activity → PathCurator

2. **Configure Basic Settings**:
   - **Activity name**: Choose a descriptive title
   - **Description**: Optional introductory text
   - **Display description on course page**: Recommended for single-activity format

3. **Choose Content Source**:

   **Option A: Upload JSON File**
   - Click "Choose files" under "JSON Data File"
   - Upload your pathway JSON file
   - The file will be validated upon save

   **Option B: Link to Public JSON**
   - Enter the public URL in "JSON Data URL"
   - Content will be fetched dynamically
   - Useful for pathways that update frequently

4. **Save and Return to Course**

### JSON File Structure

PathCurator uses a specific JSON structure to define learning pathways:

```json
[
  {
    "name": "Your Pathway Title",
    "description": "Brief description of the learning path",
    "headerImage": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB...",
    "contentWarning": "Optional warning text shown in collapsible section",
    "steps": [
      {
        "name": "Step 1: Getting Started",
        "objective": "What students will accomplish in this step",
        "bookmarks": [
          {
            "title": "Required Reading",
            "url": "https://example.com/reading",
            "description": "Essential content description",
            "type": "Required",
            "contentType": "Article",
            "context": "Additional context information"
          },
          {
            "title": "Bonus Video",
            "url": "https://example.com/video",
            "description": "Optional supplementary content",
            "type": "Bonus",
            "contentType": "Video"
          }
        ],
        "pauseAndReflect": "Optional reflection prompt",
        "acknowledgments": "Optional acknowledgments text"
      }
    ],
    "acknowledgments": "Pathway-level acknowledgments"
  }
]
```

### JSON Field Reference

#### Pathway Level
- `name` (required): Pathway title
- `description` (optional): Introductory description
- `headerImage` (optional): Base64 encoded image or data URI
- `contentWarning` (optional): Warning text in collapsible section
- `steps` (required): Array of step objects
- `acknowledgments` (optional): Credits and acknowledgments

#### Step Level
- `name` (required): Step title
- `objective` (optional): Learning objective description
- `why` (optional): Alternative to objective
- `bookmarks` (required): Array of bookmark objects
- `pauseAndReflect` (optional): Reflection prompt
- `acknowledgments` (optional): Step-specific acknowledgments

#### Bookmark Level
- `title` (required): Link title
- `url` (required): Target URL
- `description` (optional): Link description
- `type` (optional): "Required" or "Bonus" (backwards compatibility)
- `required` (optional): Boolean - true for required, false for bonus
- `contentType` (optional): Content type badge (e.g., "Video", "Article")
- `context` (optional): Additional context information

### Content Types and Behaviors

#### Required Links
- **Visual**: Blue left border, "Required" badge
- **Progress**: Counted toward completion percentage
- **Default**: Links without type/required field default to required

#### Bonus Links
- **Visual**: Grey left border, "Bonus" badge, separate section
- **Progress**: Not counted toward completion
- **Section**: Appears below required links with dashed separator

### Student Experience

#### Navigation
- **Steps are collapsible** - click to expand/collapse
- **Search functionality** - real-time filtering with highlighting
- **Progress tracking** - visual progress bar and step badges
- **Launch tracking** - clicked links remain marked as launched

#### Progress System
- **Automatic tracking** via cookies (365-day expiration)
- **Visual feedback** with success styling for launched links
- **Progress bar** showing percentage of required links launched
- **Step badges** showing required, bonus, and launched counts

### Best Practices

#### Course Design
- Use **single-activity course format** for immersive experience
- Include **course introduction** in activity description
- Consider **sequential release** if using multiple PathCurator activities

#### Content Creation
- **Structure content logically** with clear step progression
- **Balance required and bonus** content appropriately
- **Use descriptive titles** and descriptions for accessibility
- **Include context** for external links when helpful

#### JSON Management
- **Validate JSON** before uploading (use online validators)
- **Use public URLs** for content that updates frequently
- **Backup JSON files** regularly
- **Test with sample data** before full deployment

### Troubleshooting

#### Common Issues

**"Invalid JSON" Error**
- Validate JSON syntax using online tools
- Check for missing commas, brackets, or quotes
- Ensure all required fields are present

**Images Not Displaying**
- Verify base64 encoding is correct
- Include proper data URI prefix: `data:image/png;base64,`
- Keep images reasonably sized (< 1MB recommended)

**Links Not Tracking**
- Check that URLs are accessible
- Verify cookies are enabled in browser
- Ensure links have unique URLs

**Search Not Working**
- Clear browser cache and cookies
- Check for JavaScript errors in browser console
- Verify search terms match content exactly

### Customization

#### Styling
The plugin includes CSS classes for customization:
- `.pathcurator-header-image` - Header image styling
- `.pathcurator-step` - Step container
- `.pathcurator-bonus-section` - Bonus links section
- `.card.border-primary` - Required link cards
- `.card.border-secondary` - Bonus link cards

#### Language Strings
All text can be customized through Moodle's language customization:
```
Site Administration → Language → Language customisation
```

## Support and Development

### Version Information
- **Current Version**: 2025.1
- **Moodle Compatibility**: 4.0+
- **PHP Requirement**: 7.4+

### Contributing
This plugin follows Moodle coding standards and accessibility guidelines. Contributions welcome through standard Moodle development processes.

### License
This plugin is licensed under the GNU GPL v3 or later, consistent with Moodle's licensing.
