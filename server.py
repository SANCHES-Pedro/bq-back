import asyncio
import os
import logging
import threading
import io
import queue
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import speechmatics

# Configure logging
logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# Speechmatics configuration
SM_URL = "wss://eu2.rt.speechmatics.com/v2"  # pick us2 / ap2 if closer
SM_TOKEN = os.getenv("SPEECHMATICS_API_TOKEN", "")  # long-lived or temp JWT

app = FastAPI()

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, replace with your frontend URL
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class AudioStream:
    """File-like object that provides audio data to Speechmatics SDK"""
    
    def __init__(self):
        self.audio_queue = queue.Queue()
        self.current_buffer = b''
        self.closed = False
        
    def read(self, size=-1):
        """Read audio data - implements file-like interface"""
        if self.closed:
            print(f"[AUDIO_STREAM] Attempted to read from closed stream")
            return b''
            
        # If we have data in current buffer, return it first
        if self.current_buffer:
            if size == -1 or len(self.current_buffer) <= size:
                data = self.current_buffer
                self.current_buffer = b''
                print(f"[AUDIO_STREAM] Returning buffered data: {len(data)} bytes")
                return data
            else:
                data = self.current_buffer[:size]
                self.current_buffer = self.current_buffer[size:]
                print(f"[AUDIO_STREAM] Returning partial buffered data: {len(data)} bytes, {len(self.current_buffer)} bytes remaining")
                return data
        
        # Try to get new data from queue - use a longer timeout for streaming
        try:
            # Wait up to 2 seconds for new data (longer than chunk intervals)
            new_data = self.audio_queue.get(timeout=2.0)
            if new_data is None:  # Poison pill
                print(f"[AUDIO_STREAM] Received poison pill, closing stream")
                self.closed = True
                return b''
            
            if size == -1 or len(new_data) <= size:
                print(f"[AUDIO_STREAM] Returning new data: {len(new_data)} bytes")
                return new_data
            else:
                self.current_buffer = new_data[size:]
                print(f"[AUDIO_STREAM] Returning partial new data: {size} bytes, {len(self.current_buffer)} bytes buffered")
                return new_data[:size]
                
        except queue.Empty:
            # If no data after 2 seconds, return a small amount of silence to keep stream alive
            # This prevents Speechmatics from thinking the stream ended
            silence_duration = 0.1  # 100ms of silence
            samples = int(16000 * silence_duration)  # 16kHz sample rate
            silence_bytes = b'\x00\x00' * samples  # 16-bit silence
            print(f"[AUDIO_STREAM] No data for 2s, returning {len(silence_bytes)} bytes of silence to keep stream alive")
            return silence_bytes
        except Exception as e:
            print(f"[AUDIO_STREAM] Exception in read: {e}")
            if self.closed:
                return b''
            # If we get an exception but stream isn't closed, something went wrong
            self.closed = True
            return b''
    
    def add_audio_data(self, data):
        """Add audio data to the stream"""
        if not self.closed:
            queue_size = self.audio_queue.qsize()
            print(f"[AUDIO_STREAM] Adding {len(data)} bytes to queue (queue size: {queue_size})")
            self.audio_queue.put(data)
        else:
            print(f"[AUDIO_STREAM] Attempted to add data to closed stream")
    
    def close(self):
        """Close the stream"""
        print(f"[AUDIO_STREAM] Closing stream")
        self.closed = True
        self.audio_queue.put(None)  # Poison pill


class SpeechmaticsHandler:
    """Handler for Speechmatics WebSocket client that works properly with async"""
    
    def __init__(self, send_message_callback):
        self.send_message_callback = send_message_callback
        self.client = None
        self.audio_stream = AudioStream()
        self.loop = None
        
        # Connection settings
        self.connection_settings = speechmatics.models.ConnectionSettings(
            url=SM_URL,
            auth_token=SM_TOKEN,
        )
        
        # Audio settings - 16kHz is more standard for real-time speech
        self.audio_settings = speechmatics.models.AudioSettings(
            sample_rate=16000,
            encoding="pcm_s16le",
            chunk_size=1024,  # Smaller chunks for real-time
        )
        
        # Transcription config
        self.transcription_config = speechmatics.models.TranscriptionConfig(
            language="en",
            enable_partials=True,
            operating_point="enhanced",
            max_delay=1.0,
            enable_entities=True,
        )
    
    def setup_event_handlers(self):
        """Set up event handlers for Speechmatics client"""
        def handle_transcript(msg):
            """Handle final transcript"""
            try:
                print(f"[SPEECHMATICS FINAL] Raw message: {msg}")
                transcript = msg.get("metadata", {}).get("transcript", "")
                if transcript.strip():
                    print(f"[SPEECHMATICS FINAL] Extracted transcript: '{transcript}'")
                    self.send_message_callback(transcript)
                else:
                    print(f"[SPEECHMATICS FINAL] Empty transcript in message")
            except Exception as e:
                log.error(f"Error handling transcript: {e}")
        
        def handle_partial_transcript(msg):
            """Handle partial transcript"""
            try:
                print(f"[SPEECHMATICS PARTIAL] Raw message: {msg}")
                transcript = msg.get("metadata", {}).get("transcript", "")
                if transcript.strip():
                    print(f"[SPEECHMATICS PARTIAL] Extracted transcript: '{transcript}'")
                    self.send_message_callback(f"[partial] {transcript}")
                else:
                    print(f"[SPEECHMATICS PARTIAL] Empty transcript in message")
            except Exception as e:
                log.error(f"Error handling partial transcript: {e}")
        
        def handle_error(msg):
            """Handle errors"""
            try:
                print(f"[SPEECHMATICS ERROR] Raw message: {msg}")
                error_msg = msg.get("reason", "Unknown error")
                print(f"[SPEECHMATICS ERROR] Extracted error: '{error_msg}'")
                self.send_message_callback(f"Error: {error_msg}")
            except Exception as e:
                log.error(f"Error handling error message: {e}")
        
        def handle_recognition_started(msg):
            """Handle recognition started"""
            try:
                print(f"[SPEECHMATICS RECOGNITION_STARTED] Raw message: {msg}")
                self.send_message_callback("🎤 Transcription started - speak now!")
            except Exception as e:
                log.error(f"Error handling recognition started: {e}")
        
        def handle_audio_added(msg):
            """Handle audio added confirmation"""
            try:
                print(f"[SPEECHMATICS AUDIO_ADDED] Raw message: {msg}")
            except Exception as e:
                log.error(f"Error handling audio added: {e}")
        
        def handle_end_of_transcript(msg):
            """Handle end of transcript"""
            try:
                print(f"[SPEECHMATICS END_OF_TRANSCRIPT] Raw message: {msg}")
                print(f"[SPEECHMATICS END_OF_TRANSCRIPT] WARNING: Transcript ended unexpectedly!")
                print(f"[SPEECHMATICS END_OF_TRANSCRIPT] This usually means the audio stream appeared to end")
                self.send_message_callback("⚠️ Transcription session ended unexpectedly. This may be due to audio stream interruption.")
            except Exception as e:
                log.error(f"Error handling end of transcript: {e}")
        
        def handle_unknown_message(msg):
            """Handle any other message types"""
            try:
                print(f"[SPEECHMATICS UNKNOWN] Raw message: {msg}")
            except Exception as e:
                log.error(f"Error handling unknown message: {e}")
        
        # Register event handlers
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.AddTranscript,
            handle_transcript
        )
        
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.AddPartialTranscript,
            handle_partial_transcript
        )
        
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.Error,
            handle_error
        )
        
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.RecognitionStarted,
            handle_recognition_started
        )
        
        # Add handlers for other message types to see everything
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.AudioAdded,
            handle_audio_added
        )
        
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.EndOfTranscript,
            handle_end_of_transcript
        )
        
        # Add a catch-all handler for any message type we might have missed
        # Note: This might not work with all SDK versions, but it's worth trying
        try:
            # Try to register a handler for all possible message types
            for msg_type in speechmatics.models.ServerMessageType:
                if msg_type not in [
                    speechmatics.models.ServerMessageType.AddTranscript,
                    speechmatics.models.ServerMessageType.AddPartialTranscript,
                    speechmatics.models.ServerMessageType.Error,
                    speechmatics.models.ServerMessageType.RecognitionStarted,
                    speechmatics.models.ServerMessageType.AudioAdded,
                    speechmatics.models.ServerMessageType.EndOfTranscript,
                ]:
                    print(f"[SPEECHMATICS SETUP] Registering handler for: {msg_type}")
                    self.client.add_event_handler(msg_type, handle_unknown_message)
        except Exception as e:
            print(f"[SPEECHMATICS SETUP] Could not register catch-all handlers: {e}")
    
    def add_audio_data(self, audio_data):
        """Add audio data to stream"""
        self.audio_stream.add_audio_data(audio_data)
    
    def start_transcription(self):
        """Start the Speechmatics transcription in a separate thread"""
        try:
            print(f"[SPEECHMATICS] Initializing WebSocket client...")
            print(f"[SPEECHMATICS] URL: {SM_URL}")
            print(f"[SPEECHMATICS] Token (first 10 chars): {SM_TOKEN[:10]}...")
            
            # Create WebSocket client
            self.client = speechmatics.client.WebsocketClient(self.connection_settings)
            
            # Setup event handlers
            print(f"[SPEECHMATICS] Setting up event handlers...")
            self.setup_event_handlers()
            
            print(f"[SPEECHMATICS] Audio settings: {self.audio_settings}")
            print(f"[SPEECHMATICS] Transcription config: {self.transcription_config}")
            
            log.info("Starting Speechmatics transcription...")
            print(f"[SPEECHMATICS] Starting run_synchronously...")
            
            # Run synchronously in this thread
            self.client.run_synchronously(
                self.audio_stream,
                self.transcription_config,
                self.audio_settings
            )
            
            print(f"[SPEECHMATICS] run_synchronously completed")
            
        except Exception as e:
            print(f"[SPEECHMATICS] Exception in start_transcription: {e}")
            print(f"[SPEECHMATICS] Exception type: {type(e)}")
            import traceback
            print(f"[SPEECHMATICS] Traceback: {traceback.format_exc()}")
            log.error(f"Speechmatics transcription error: {e}")
            self.send_message_callback(f"Transcription error: {str(e)}")
    
    def stop_transcription(self):
        """Stop the transcription"""
        print(f"[SPEECHMATICS] Stopping transcription...")
        self.audio_stream.close()


# Global message queue for thread-safe communication
message_queue = queue.Queue()

def message_sender_callback(message):
    """Thread-safe callback to send messages to WebSocket"""
    message_queue.put(message)


# ----- FastAPI WebSocket bridge --------------------------------------------
@app.websocket("/ws")
async def websocket_proxy(client_ws: WebSocket):
    await client_ws.accept()
    log.info("Client connected")
    
    # Send initial connection message
    await client_ws.send_text("Connected to server successfully!")

    # Create Speechmatics handler with thread-safe callback
    sm_handler = SpeechmaticsHandler(message_sender_callback)
    
    # Start transcription in a separate thread
    executor = ThreadPoolExecutor(max_workers=1)
    transcription_future = executor.submit(sm_handler.start_transcription)

    # Task to handle messages from the background thread
    async def message_handler():
        while True:
            try:
                # Check for messages from background thread
                try:
                    message = message_queue.get_nowait()
                    await client_ws.send_text(message)
                except queue.Empty:
                    pass
                
                # Small delay to prevent busy waiting
                await asyncio.sleep(0.01)
                
            except Exception as e:
                log.error(f"Error in message handler: {e}")
                break

    # Start message handler task
    message_task = asyncio.create_task(message_handler())

    chunk_count = 0
    try:
        # Receive audio from browser and add to handler
        while True:
            data = await client_ws.receive_bytes()
            chunk_count += 1
            log.info(f"Received audio chunk #{chunk_count}, size: {len(data)} bytes")
            
            # Add audio data to handler
            sm_handler.add_audio_data(data)
            
            # Send acknowledgment
            await client_ws.send_text(f"Received chunk #{chunk_count}")
            
    except WebSocketDisconnect:
        log.info("Browser disconnected")
    except Exception as e:
        log.error(f"WebSocket error: {e}")
    finally:
        # Clean up
        log.info("Cleaning up Speechmatics session...")
        sm_handler.stop_transcription()
        
        # Cancel message handler
        message_task.cancel()
        
        # Wait a bit for clean shutdown
        try:
            transcription_future.result(timeout=2.0)
        except:
            pass
        
        executor.shutdown(wait=False)
        log.info(f"Session ended. Total chunks received: {chunk_count}")


if __name__ == "__main__":
    if not SM_TOKEN:
        log.error("Please set SPEECHMATICS_API_TOKEN environment variable")
    else:
        log.info(f"Starting server with Speechmatics token: {SM_TOKEN[:10]}...")
    uvicorn.run(app, host="0.0.0.0", port=8000)