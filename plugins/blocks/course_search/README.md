# Course Search Block

A comprehensive Moodle block plugin that provides powerful course-specific content search functionality across all major activity types.

## Features

- Simple, intuitive search form within the block
- Comprehensive search across all major activity types in the current course
- Displays search results with content previews and direct links
- Accessible design with proper ARIA roles and semantic HTML
- Responsive layout that works on desktop and mobile devices
- Modular architecture for easy extension

## Comprehensive Search Coverage

The plugin provides deep content search across all major Moodle activity types:

### **Core Activities & Resources**
- Activity and resource names and descriptions (all modules)
- Assignment titles and descriptions
- Page content
- Label content
- URL and File resource descriptions

### **Interactive Content**
- **Forum Content**: Posts, discussions, and topics with direct links to discussions
- **Book Content**: Chapter titles and full chapter content with links to specific chapters
- **Wiki Content**: Wiki page titles and content with links to specific pages
- **Glossary Content**: Terms (concepts) and definitions with links to specific entries

### **Assessment & Learning**
- **Quiz Content**: Question names, question text, and feedback from the question bank
- **Lesson Content**: Lesson page titles and content
- **Workshop Content**: Submission titles and content
- **Feedback Content**: Feedback items and presentation text

### **Data & Collaboration**
- **Database Content**: Data module records and field content with links to specific records

## Advanced Features

- **Smart Content Detection**: Automatically detects which modules are installed and searches accordingly
- **Contextual Results**: Shows activity type, parent activity name, and content preview
- **Direct Navigation**: Results link directly to specific content (chapters, posts, entries, etc.)
- **Permission Aware**: Respects course module visibility and user permissions
- **Performance Optimized**: Efficient database queries with proper indexing

## Installation

1. Copy the plugin files to `/blocks/course_search/` in your Moodle installation
2. Visit the admin notifications page to complete the installation
3. The block will be available to add to course pages

## Usage

1. Add the "Course Search" block to a course page
2. Enter search terms in the search form
3. Click "Search" to view comprehensive results
4. Results are displayed with:
   - Activity title and parent activity name
   - Activity type (e.g., "Book - Chapter", "Forum - Post")
   - Content preview with highlighted search terms
   - Direct links to specific content locations

## Search Examples

- **"synchronously"** - Finds the term in book chapters, forum posts, quiz questions, lesson pages, etc.
- **"assignment"** - Finds assignment titles, descriptions, and any content mentioning assignments
- **"discussion"** - Finds forum discussions, posts, and any related content
- **"quiz"** - Finds quiz questions, feedback, and quiz-related content across all activities

## Accessibility

- Proper semantic HTML structure
- ARIA labels for screen readers
- Keyboard navigation support
- High contrast styling
- Responsive design for all devices

## Privacy

This plugin does not store any personal data. It only searches existing course content that users already have access to.

## Technical Details

- **Compatibility**: Moodle 4.0+ (backwards compatible with 3.9+)
- **Database**: Uses core Moodle APIs for secure database access
- **Standards**: Follows Moodle coding standards and best practices
- **Security**: Includes proper capability checks and SQL injection protection
- **Styling**: Responsive Bootstrap-compatible styling with custom CSS
- **Architecture**: Modular design with separate search functions for each activity type
- **Performance**: Optimized database queries with conditional module loading

## Extensibility

The plugin is designed for easy extension. To add support for additional activity types:

1. Create a new search function following the pattern: `block_course_search_search_[module]_content()`
2. Add the function call to the main search function
3. Follow the existing patterns for database queries and result formatting

## Database Tables Searched

The plugin searches the following core Moodle tables:
- `course_modules` - Activity instances
- `forum_posts`, `forum_discussions` - Forum content
- `book_chapters` - Book content
- `question`, `quiz_slots` - Quiz questions
- `lesson_pages` - Lesson content
- `wiki_pages` - Wiki content
- `glossary_entries` - Glossary terms
- `workshop_submissions` - Workshop content
- `feedback_item` - Feedback content
- `data_content`, `data_records` - Database module content
- Plus module-specific tables for each activity type

## Author

BC Public Service Agency.

## License

Coming soon but open.
