# HearNow - Speech to Text Application

A cross-platform speech-to-text application using **Deepgram Nova 3** with WebSocket integration. Built with **Flutter** for the frontend (Windows, Android, Linux, macOS, iOS) and **Node.js** for the backend.

## Project Structure

```
hearnow/
├── backend/              # Node.js server
│   ├── src/
│   │   └── server.js    # WebSocket server and Deepgram integration
│   ├── .env.example     # Environment variables template
│   ├── package.json     # Backend dependencies
│   └── README.md        # Backend documentation
├── lib/                 # Flutter app source code
│   ├── main.dart       # App entry point
│   ├── screens/        # App screens
│   ├── providers/      # State management
│   └── services/       # Business logic
├── android/            # Android-specific files
├── ios/               # iOS-specific files
├── macos/             # macOS-specific files
├── linux/             # Linux-specific files
├── windows/           # Windows-specific files
└── pubspec.yaml       # Flutter dependencies
```

## Features

- **Real-time transcription** using Deepgram Nova 3
- **WebSocket communication** between frontend and backend
- **Cross-platform support**: Windows, Android, Linux, macOS, iOS
- **Audio streaming** with PCM 16-bit format
- **Interim and final results** display
- **Confidence scores** for transcriptions
- **Error handling** and status indicators

## Prerequisites

### Backend Requirements
- Node.js (v18 or higher)
- Deepgram API key (sign up at https://deepgram.com)

### Frontend Requirements
- Flutter SDK (latest stable)
- Platform-specific SDKs:
  - **Android**: Android SDK (API 21+)
  - **iOS**: Xcode (iOS 11+)
  - **macOS**: Xcode (macOS 10.13+)
  - **Windows**: Visual Studio or Visual Studio Build Tools
  - **Linux**: GCC, Make, GTK 3.0 or higher

## Backend Setup

1. Navigate to the backend directory:
```bash
cd backend
```

2. Install dependencies:
```bash
npm install
```

3. Create a `.env` file from the template:
```bash
cp .env.example .env
```

4. Add your Deepgram API key to `.env`:
```
DEEPGRAM_API_KEY=your_actual_api_key_here
PORT=3000
```

5. Start the server:
```bash
npm run dev  # Development mode with auto-reload
# or
npm start   # Production mode
```

The backend will start on `ws://localhost:3000/listen`

## Frontend Setup

1. Navigate to the frontend directory:
```bash
cd .
```

2. Install Flutter dependencies:
```bash
flutter pub get
```

3. Configure the server URL (default: `ws://localhost:3000/listen`)

The frontend reads the WebSocket URL from a compile-time define:

- Override at run time:
  - `flutter run -d windows --dart-define=HEARNOW_SERVER_URL=ws://localhost:3000/listen`
- Override at build time:
  - `flutter build windows --dart-define=HEARNOW_SERVER_URL=ws://localhost:3000/listen`

Optional: use a file instead of putting the URL on the command line:

- Create `env.json`:
  - `{ "HEARNOW_SERVER_URL": "ws://localhost:3000/listen" }`
- Then run/build:
  - `flutter run -d windows --dart-define-from-file=env.json`
  - `flutter build windows --dart-define-from-file=env.json`

### Running on Different Platforms

**Android:**
```bash
flutter run -d <device-id>
```

**iOS:**
```bash
flutter run -d <device-id>
```

**macOS:**
```bash
flutter run -d macos
```

**Linux:**
```bash
flutter run -d linux
```

**Windows:**
```bash
flutter run -d windows
```

**Web (Browser):**
```bash
flutter run -d chrome
```

## WebSocket Protocol

### Client to Server Messages

**Start recording:**
```json
{
  "type": "start"
}
```

**Send audio data:**
```json
{
  "type": "audio",
  "audio": "<base64-encoded-audio-chunk>"
}
```

**Stop recording:**
```json
{
  "type": "stop"
}
```

### Server to Client Messages

**Status updates:**
```json
{
  "type": "status",
  "message": "ready" | "stopped"
}
```

**Transcription results:**
```json
{
  "type": "transcript",
  "text": "transcribed text",
  "is_final": true | false,
  "confidence": 0.95
}
```

**Error messages:**
```json
{
  "type": "error",
  "message": "error description"
}
```

## Configuration

### Environment Variables (Backend)

- `DEEPGRAM_API_KEY` - Your Deepgram API key (required)
- `PORT` - Server port (default: 3000)

### Flutter Configuration

Platform-specific permissions are automatically configured:
- **Android**: `RECORD_AUDIO`, `INTERNET` permissions in `android/app/src/main/AndroidManifest.xml`
- **iOS**: Microphone usage description in `ios/Runner/Info.plist`
- **macOS**: Audio input entitlements in `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`

## Troubleshooting

### Backend Issues

**Connection refused:**
- Ensure Node.js is installed: `node --version`
- Check if port 3000 is not in use: `lsof -i :3000`
- Verify Deepgram API key is valid

**API errors:**
- Check Deepgram API key in `.env`
- Verify API key has correct permissions
- Check Deepgram service status

### Frontend Issues

**Microphone permission denied:**
- Grant microphone permissions in device settings
- On Android 6+, permissions are requested at runtime

**Can't connect to server:**
- Ensure backend is running: `http://localhost:3000/health`
- Verify WebSocket URL in app settings
- Check firewall settings

**Audio not streaming:**
- Verify microphone is working
- Check device audio settings
- Ensure app has microphone permissions

## Development

### Backend Development

The backend uses:
- `express` - HTTP server framework
- `ws` - WebSocket implementation
- `@deepgram/sdk` - Deepgram API client
- `cors` - CORS middleware
- `dotenv` - Environment variable management

### Frontend Development

The app uses:
- `provider` - State management
- `web_socket_channel` - WebSocket client
- `record` - Audio recording
- `permission_handler` - Permission management

## Dependencies

### Backend (`package.json`)
- @deepgram/sdk: ^3.5.1
- express: ^4.18.2
- ws: ^8.16.0
- dotenv: ^16.4.5
- cors: ^2.8.5

### Frontend (`pubspec.yaml`)
- web_socket_channel: ^3.0.1
- record: ^5.1.2
- permission_handler: ^11.3.1
- provider: ^6.1.2

## License

ISC

## Support

For issues or questions:
1. Check the backend README for backend-specific issues
2. Review [Flutter documentation](https://flutter.dev/docs)
3. Consult [Deepgram documentation](https://developers.deepgram.com)
