# HearNow Backend

Node.js backend server for the HearNow speech-to-text application using Deepgram Nova 3 and WebSocket.

## Prerequisites

- Node.js (v18 or higher)
- Deepgram API key (get one at https://deepgram.com)

## Setup

1. Install dependencies:
```bash
npm install
```

2. Create a `.env` file from the example:
```bash
cp .env.example .env
```

3. Add your Deepgram API key to the `.env` file:
```
DEEPGRAM_API_KEY=your_actual_api_key_here
```

4. (Optional) Enable AI responses by adding your OpenAI API key:
```
OPENAI_API_KEY=your_actual_api_key_here
# Optional
# OPENAI_MODEL=gpt-4o-mini
```

## AI usage limits (per plan)

The backend enforces **Cursor-like usage limits** per authenticated user. Limits are evaluated **before** calling OpenAI.

### Billing period

- **Window**: monthly (UTC), from the 1st of the month to the 1st of next month
- **Meter**: tokens (from OpenAI `usage.total_tokens`) + request count
- **Source of truth**: MongoDB collection `api_usage`

### What happens when users hit limits

- **Monthly token cap reached**: request is blocked with HTTP **402** (or WS `ai_error.status=402`)
- **Monthly request cap reached**: request is blocked with HTTP **402** (or WS `ai_error.status=402`)
- **Rate limit / concurrency limit hit**: request is blocked with HTTP **429** (or WS `ai_error.status=429`)

### Default limits

These defaults are configured in `server/src/server.ts`:

- **Monthly quotas**: `planEntitlements()`
- **Per-minute rate + concurrency**: `aiRateLimitsForPlan()`

#### Free

- **Monthly AI tokens**: 50,000
- **Monthly AI requests**: 200
- **Max concurrent AI requests**: 1
- **Rate limit**: 10 requests/minute
- **Allowed models**: `gpt-4.1-mini`, `gpt-4.1`
- **Per-model token caps**:
  - `gpt-4.1-mini`: 40,000
  - `gpt-4.1`: 10,000

#### Pro

- **Monthly AI tokens**: 500,000
- **Monthly AI requests**: 5,000
- **Max concurrent AI requests**: 1
- **Rate limit**: 60 requests/minute
- **Allowed models**: `gpt-5`, `gpt-5.1`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4o`, `gpt-4o-mini`
- **Per-model token caps**:
  - `gpt-5`: 200,000
  - `gpt-5.1`: 100,000
  - `gpt-4.1`: 75,000
  - `gpt-4.1-mini`: 75,000
  - `gpt-4o`: 25,000
  - `gpt-4o-mini`: 25,000

#### Pro Plus

- **Monthly AI tokens**: 2,000,000
- **Monthly AI requests**: 20,000
- **Max concurrent AI requests**: 1
- **Rate limit**: 120 requests/minute
- **Allowed models**: `gpt-5.2`, `gpt-5`, `gpt-5.1`, `gpt-4.1`, `gpt-4.1-mini`, `gpt-4o`, `gpt-4o-mini`
- **Per-model token caps**:
  - `gpt-5.2`: 600,000
  - `gpt-5`: 500,000
  - `gpt-5.1`: 300,000
  - `gpt-4.1`: 250,000
  - `gpt-4.1-mini`: 200,000
  - `gpt-4o`: 75,000
  - `gpt-4o-mini`: 75,000

### Usage visibility endpoints

- `GET /api/billing/me`: current plan + current-month AI usage totals + `ai.byModel` breakdown
- `GET /api/usage`: current-month totals (tokens, byModel, byMode)
- `GET /api/usage/details`: raw usage rows (includes model + tokens)

> Note: rate-limit + concurrency tracking is **in-memory** and resets when the backend restarts.

## Running the Server

Development mode (with auto-reload):
```bash
npm run dev
```

Production mode:
```bash
npm start
```

The server will start on port 3000 by default.

## API Endpoints

- **GET /health** - Health check endpoint
- **WebSocket /listen** - WebSocket endpoint for audio streaming
- **POST /ai/respond** - Generate an AI reply from transcript turns

### POST /ai/respond

Request body:
```json
{
  "mode": "reply",
  "turns": [
    {"source": "mic", "text": "Hello"},
    {"source": "system", "text": "Hi there"}
  ]
}
```

Response:
```json
{ "text": "..." }
```

## WebSocket Protocol

### Client to Server Messages

1. Start streaming:
```json
{
  "type": "start"
}
```

2. Send audio data:
```json
{
  "type": "audio",
  "audio": "<base64-encoded-audio>"
}
```

3. Stop streaming:
```json
{
  "type": "stop"
}
```

### Server to Client Messages

1. Status updates:
```json
{
  "type": "status",
  "message": "ready|stopped"
}
```

2. Transcription results:
```json
{
  "type": "transcript",
  "text": "transcribed text",
  "is_final": true|false,
  "confidence": 0.95
}
```

3. Error messages:
```json
{
  "type": "error",
  "message": "error description"
}
```
