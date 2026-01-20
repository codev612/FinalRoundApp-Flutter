import express from 'express';
import { WebSocketServer } from 'ws';
import { createClient, LiveTranscriptionEvents } from '@deepgram/sdk';
import dotenv from 'dotenv';
import cors from 'cors';
import { createServer } from 'http';

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', message: 'HearNow backend is running' });
});

// Create HTTP server
const server = createServer(app);

// Create WebSocket server
const wss = new WebSocketServer({ server, path: '/listen' });

// Deepgram client
const deepgram = createClient(process.env.DEEPGRAM_API_KEY);

wss.on('connection', (ws) => {
  console.log('Client connected');

  let deepgramMic = null;
  let deepgramSystem = null;

  const startDeepgram = (source) => {
    const live = deepgram.listen.live({
      model: 'nova-3',
      language: 'en',
      smart_format: true,
      punctuate: true,
      interim_results: true,
      encoding: 'linear16',
      sample_rate: 16000,
    });

    live.on(LiveTranscriptionEvents.Open, () => {
      console.log(`Deepgram connection opened (${source})`);
      ws.send(JSON.stringify({ type: 'status', message: `ready:${source}` }));
    });

    live.on(LiveTranscriptionEvents.Transcript, (data) => {
      const transcript = data.channel.alternatives[0]?.transcript;
      if (transcript) {
        const isFinal = data.is_final === true;
        const isInterim = data.is_final === false;
        ws.send(
          JSON.stringify({
            type: 'transcript',
            source,
            text: transcript,
            is_final: isFinal,
            is_interim: isInterim,
            confidence: data.channel.alternatives[0].confidence || 0,
          }),
        );
      }
    });

    live.on(LiveTranscriptionEvents.Error, (error) => {
      console.error(`Deepgram error (${source}):`, error);
      ws.send(
        JSON.stringify({
          type: 'error',
          message: error.message || `Deepgram error (${source})`,
        }),
      );
    });

    live.on(LiveTranscriptionEvents.Close, () => {
      console.log(`Deepgram connection closed (${source})`);
      if (source === 'mic') deepgramMic = null;
      if (source === 'system') deepgramSystem = null;
    });

    return live;
  };

  // Handle incoming messages from client
  ws.on('message', async (message) => {
    try {
      // Try to parse as JSON first, otherwise treat as binary audio data
      let data;
      try {
        data = JSON.parse(message);
      } catch (e) {
        // Not JSON, might be binary audio data
        if (deepgramLive) {
          deepgramLive.send(message);
        }
        return;
      }

      if (data.type === 'start') {
        // Check if API key is set
        if (!process.env.DEEPGRAM_API_KEY) {
          console.error('Deepgram API key not configured');
          ws.send(JSON.stringify({ 
            type: 'error', 
            message: 'Server error: Deepgram API key not configured. Please set DEEPGRAM_API_KEY in .env file' 
          }));
          return;
        }

        // Initialize Deepgram live connections (mic + system)
        console.log('Starting Deepgram connections (mic + system)...');
        
        try {
          if (deepgramMic) {
            deepgramMic.finish();
            deepgramMic = null;
          }
          if (deepgramSystem) {
            deepgramSystem.finish();
            deepgramSystem = null;
          }

          deepgramMic = startDeepgram('mic');
          deepgramSystem = startDeepgram('system');
        } catch (error) {
          console.error('Failed to start Deepgram connection:', error);
          ws.send(JSON.stringify({ type: 'error', message: 'Failed to connect to Deepgram: ' + error.message }));
          deepgramMic = null;
          deepgramSystem = null;
        }

      } else if (data.type === 'audio') {
        const source = data.source === 'system' ? 'system' : 'mic';
        const target = source === 'system' ? deepgramSystem : deepgramMic;
        if (!target) return;

        // Forward audio data to Deepgram (per-source session)
        try {
          const audioBuffer = Buffer.from(data.audio, 'base64');
          target.send(audioBuffer);
        } catch (error) {
          console.error('Error sending audio to Deepgram:', error);
          ws.send(JSON.stringify({ type: 'error', message: 'Error processing audio' }));
        }
      } else if (data.type === 'stop') {
        // Close Deepgram connections
        console.log('Stopping transcription (mic + system)...');
        if (deepgramMic) {
          deepgramMic.finish();
          deepgramMic = null;
        }
        if (deepgramSystem) {
          deepgramSystem.finish();
          deepgramSystem = null;
        }
        ws.send(JSON.stringify({ type: 'status', message: 'stopped' }));
      }
    } catch (error) {
      console.error('Error processing message:', error);
      ws.send(JSON.stringify({ type: 'error', message: error.message }));
    }
  });

  ws.on('close', () => {
    console.log('Client disconnected');
    if (deepgramMic) deepgramMic.finish();
    if (deepgramSystem) deepgramSystem.finish();
  });

  ws.on('error', (error) => {
    console.error('WebSocket error:', error);
  });
});

server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`WebSocket endpoint: ws://localhost:${PORT}/listen`);
  if (!process.env.DEEPGRAM_API_KEY) {
    console.warn('WARNING: DEEPGRAM_API_KEY environment variable not set!');
  }
});

