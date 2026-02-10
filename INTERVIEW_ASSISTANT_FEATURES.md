# Interview Assistant Features

This document describes the interview assistant tools that have been added to the HearNow project.

## Overview

The interview assistant extends the existing speech-to-text functionality with comprehensive interview management, AI-powered analysis, and productivity features designed specifically for conducting and managing interviews.

## New Features

### 1. Interview Session Management

- **Save/Load Sessions**: Save interview transcripts with metadata (title, timestamps, duration)
- **Session List**: View and manage all saved interview sessions
- **Session Metadata**: Each session tracks:
  - Title (editable)
  - Creation and update timestamps
  - Duration
  - Full transcript
  - AI-generated summary and insights

### 2. AI-Powered Analysis

#### Summary Generation
- Automatically generates concise summaries of interview conversations
- Includes key topics discussed, candidate responses, and notable points
- Action items and follow-ups are listed separately

#### Insights Generation
- Analyzes interview transcripts to provide key insights about candidates
- Focuses on:
  - Strengths and areas of concern
  - Communication style
  - Technical knowledge
  - Cultural fit
  - Overall assessment

#### Question Suggestions
- AI-generated follow-up questions based on the conversation
- Considers what has been discussed and identifies gaps
- Helps make better hiring decisions

### 3. Question Templates

Pre-built question templates organized by category:
- **General Questions**: Standard interview questions
- **Technical Questions**: Technology and skills-focused questions
- **Behavioral Questions**: Situation-based questions (STAR method)
- **Culture Fit Questions**: Values and work environment questions

### 4. Export Functionality

- **Text Export**: Export complete interview sessions as formatted text files
- **Clipboard Export**: Quick copy-to-clipboard for sharing
- Export includes:
  - Session metadata
  - Summary (if generated)
  - Insights (if generated)
  - Full transcript with speaker labels

### 5. Enhanced UI Features

- **Session Title Editor**: Edit session titles inline
- **Quick Actions**: Save, export, and manage sessions from the interview page
- **Collapsible Sections**: Summary, insights, and question suggestions can be shown/hidden
- **Session Browser**: Dedicated page for viewing and managing all sessions

## Technical Implementation

### New Files Created

1. **Models**
   - `lib/models/interview_session.dart` - Interview session data model

2. **Services**
   - `lib/services/interview_storage_service.dart` - File-based session storage
   - `lib/services/interview_question_service.dart` - Question template management

3. **Providers**
   - `lib/providers/interview_provider.dart` - State management for interview sessions

4. **Screens**
   - `lib/screens/interview_page_enhanced.dart` - Enhanced interview page with all new features

### Backend Enhancements

The backend AI endpoint (`/ai/respond`) now supports three new modes:
- `summary` - Generate interview summaries
- `insights` - Generate candidate insights
- `questions` - Generate follow-up questions

### Dependencies Added

- `path_provider: ^2.1.4` - For file system access
- `path: ^1.9.0` - For path manipulation

## Usage Guide

### Starting a New Interview

1. Navigate to the Interview tab
2. A new session is automatically created
3. Optionally edit the session title
4. Click "Record" to start transcribing

### Using Question Templates

1. Click the question mark icon next to the "Ask AI" field
2. Select a category (General, Technical, Behavioral, Culture Fit)
3. Choose a question from the list
4. The question is automatically inserted into the "Ask AI" field

### Generating AI Analysis

After recording some conversation:

1. **Summary**: Click "Summary" button to generate a concise summary
2. **Insights**: Click "Insights" button to analyze candidate characteristics
3. **Questions**: Click "Questions" button to get AI-suggested follow-up questions

### Saving Sessions

1. Edit the session title if needed
2. Click the save icon (💾) in the top bar
3. Session is saved to local storage

### Managing Sessions

1. Click the menu icon (⋮) in the top bar
2. Select "Manage Sessions"
3. View all saved sessions
4. Click a session to load it
5. Use export/delete buttons as needed

### Exporting Sessions

1. Click the export icon (📥) in the top bar, OR
2. Go to "Manage Sessions" and click export on a specific session
3. Session is copied to clipboard as formatted text

## File Storage

Sessions are stored locally in the application's documents directory:
- **Windows**: `%APPDATA%\FinalRound\interview_sessions\`
- **macOS**: `~/Library/Application Support/FinalRound/interview_sessions/`
- **Linux**: `~/.local/share/FinalRound/interview_sessions/`
- **Android**: App-specific storage
- **iOS**: App-specific storage

Each session is saved as a JSON file named with the session ID.

## Future Enhancements

Potential future features:
- PDF export
- Search functionality across sessions
- Tags and categories for sessions
- Interview analytics dashboard
- Integration with ATS (Applicant Tracking Systems)
- Multi-language support
- Voice notes and annotations
- Collaborative features (share sessions)

## Notes

- Sessions are stored locally on the device
- AI features require an OpenAI API key configured in the backend
- All transcript data remains on-device unless explicitly exported
- The enhanced interview page replaces the original interview page in the app shell
