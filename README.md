# Speechmatics Real-Time Speech-to-Text Server

This is a FastAPI server that provides real-time speech-to-text transcription using the Speechmatics API.

## Features

- Real-time audio streaming via WebSocket
- Speechmatics integration for high-quality transcription
- Support for both partial and final transcripts
- Configurable audio settings (16kHz PCM s16le)
- CORS enabled for browser integration

## Setup

1. **Install Dependencies**

   ```bash
   pip install -r requirements.txt
   ```

2. **Set Environment Variable**

   ```bash
   export SPEECHMATICS_API_TOKEN="your_api_token_here"
   ```

   Get your API token from the [Speechmatics Portal](https://portal.speechmatics.com/manage-access/)

3. **Run the Server**

   ```bash
   python server.py
   ```

   The server will start on `http://localhost:8000`

## Configuration

### Audio Settings

- **Sample Rate**: 16,000 Hz
- **Encoding**: PCM signed 16-bit little-endian
- **Chunk Size**: 8,192 bytes
- **Latency**: ~512ms per chunk (optimized for network efficiency)

### Transcription Settings

- **Language**: English (can be changed to "pt" for Portuguese)
- **Partials**: Enabled for low-latency feedback
- **Operating Point**: Enhanced for better accuracy
- **Max Delay**: 1.0 seconds for good balance of latency/accuracy

## WebSocket API

### Connection

Connect to: `ws://localhost:8000/ws`

### Message Flow

1. **Client → Server**: Binary audio data (PCM s16le, 16kHz)
2. **Server → Client**: Text messages with transcription results

### Message Types

- `Connected to server successfully!` - Initial connection confirmation
- `Received chunk #N` - Audio chunk acknowledgment
- `🎤 Transcription started - speak now!` - Transcription session started
- `[partial] <text>` - Partial transcript (may change)
- `<text>` - Final transcript (won't change)
- `Error: <message>` - Error notifications

## Frontend Integration

The frontend should:

1. Capture audio at 16kHz sample rate
2. Convert float32 audio to int16 PCM format
3. Send audio chunks of ~8192 samples (~512ms) via WebSocket
4. Handle text responses for display

## Error Handling

The server handles various error scenarios:

- Invalid API tokens
- Network connectivity issues
- Audio format mismatches
- WebSocket disconnections

All errors are logged and sent back to the client when possible.

## Troubleshooting

### Common Issues

1. **"Please set SPEECHMATICS_API_TOKEN"**

   - Make sure you've set the environment variable
   - Verify your API token is valid

2. **Audio not being transcribed**

   - Check that audio is 16kHz, PCM s16le format
   - Verify chunks are properly sized (~8192 samples)
   - Check browser microphone permissions

3. **Connection errors**
   - Ensure server is running on port 8000
   - Check firewall settings
   - Verify CORS configuration for your domain

### Logs

The server provides detailed logging for debugging:

- Audio chunk reception
- Speechmatics session status
- WebSocket connection events
- Error details
