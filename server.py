import asyncio
import os
import logging
import threading
import io
import queue
import wave
import json
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import speechmatics
import openai
from pydantic import BaseModel
class ReportRequest(BaseModel):
    transcript: str
    template: str
    unspoken_notes: str

# Configure logging
logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# OpenAI configuration
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if OPENAI_API_KEY:
    openai.api_key = OPENAI_API_KEY

# Speechmatics configuration
SM_URL = os.getenv("SM_URL", "wss://eu2.rt.speechmatics.com/v2")
SM_TOKEN = os.getenv("SPEECHMATICS_API_TOKEN", "")

app = FastAPI()

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# SSL configuration for production
ssl_keyfile = os.getenv("SSL_KEYFILE")
ssl_certfile = os.getenv("SSL_CERTFILE")

# Configure uvicorn settings
uvicorn_config = {
    "host": "0.0.0.0",
    "port": int(os.getenv("PORT", "8000")),
    "ssl_keyfile": ssl_keyfile if ssl_keyfile else None,
    "ssl_certfile": ssl_certfile if ssl_certfile else None,
}

class AudioStream:
    """File-like object that provides audio data to Speechmatics SDK"""
    
    def __init__(self):
        self.audio_queue = queue.Queue()
        self.current_buffer = b''
        self.closed = False
        
    def read(self, size=-1):
        """Read audio data - implements file-like interface"""
        if self.closed:
            return b''
            
        # Return buffered data first
        if self.current_buffer:
            if size == -1 or len(self.current_buffer) <= size:
                data = self.current_buffer
                self.current_buffer = b''
                return data
            else:
                data = self.current_buffer[:size]
                self.current_buffer = self.current_buffer[size:]
                return data
        
        try:
            # Wait for new data with timeout
            new_data = self.audio_queue.get(timeout=2.0)
            if new_data is None:  # Poison pill
                self.closed = True
                return b''
            
            if size == -1 or len(new_data) <= size:
                return new_data
            else:
                self.current_buffer = new_data[size:]
                return new_data[:size]
                
        except queue.Empty:
            # Return silence to keep stream alive
            return b'\x00\x00' * int(16000 * 0.1)  # 100ms of silence at 16kHz
        except Exception:
            self.closed = True
            return b''
    
    def add_audio_data(self, data):
        """Add audio data to the stream"""
        if not self.closed:
            self.audio_queue.put(data)
    
    def close(self):
        """Close the stream"""
        self.closed = True
        self.audio_queue.put(None)  # Poison pill


class TranscriptionSession:
    """Manages a complete transcription session including audio and text storage"""
    
    def __init__(self, session_id):
        self.session_id = session_id
        self.start_time = datetime.now()
        self.audio_chunks = []
        self.transcripts = []
        self.sample_rate = 16000
        self.channels = 1
        self.sample_width = 2  # 16-bit audio
        
    def add_audio_chunk(self, chunk):
        """Add an audio chunk to the session"""
        self.audio_chunks.append(chunk)
        
    def add_transcript(self, text, is_partial=False):
        """Add a transcript entry with timestamp"""
        self.transcripts.append({
            'timestamp': (datetime.now() - self.start_time).total_seconds(),
            'text': text,
            'is_partial': is_partial
        })
        
    def save_session(self, output_dir='sessions'):
        """Save the complete session (audio + transcripts)"""
        os.makedirs(output_dir, exist_ok=True)
        
        # Generate filename with timestamp
        timestamp = self.start_time.strftime('%Y%m%d_%H%M%S')
        base_filename = f"{output_dir}/session_{timestamp}"
        
        # Save audio as WAV file
        audio_filename = f"{base_filename}.wav"
        with wave.open(audio_filename, 'wb') as wav_file:
            wav_file.setnchannels(self.channels)
            wav_file.setsampwidth(self.sample_width)
            wav_file.setframerate(self.sample_rate)
            
            # Combine all audio chunks
            for chunk in self.audio_chunks:
                wav_file.writeframes(chunk)
        
        # Save transcripts as JSON
        transcript_filename = f"{base_filename}_transcript.json"
        session_data = {
            'session_id': self.session_id,
            'start_time': self.start_time.isoformat(),
            'duration': (datetime.now() - self.start_time).total_seconds(),
            'transcripts': self.transcripts
        }
        
        with open(transcript_filename, 'w') as f:
            json.dump(session_data, f, indent=2)
        
        # Also save a plain text version
        text_filename = f"{base_filename}_transcript.txt"
        with open(text_filename, 'w') as f:
            for entry in self.transcripts:
                if not entry['is_partial']:
                    f.write(f"[{entry['timestamp']:.2f}s] {entry['text']}\n")
        
        log.info(f"Session saved: {audio_filename}, {transcript_filename}, {text_filename}")
        return audio_filename, transcript_filename, text_filename


class SpeechmaticsHandler:
    """Handler for Speechmatics WebSocket client"""
    
    def __init__(self, send_message_callback, session):
        self.send_message_callback = send_message_callback
        self.session = session
        self.client = None
        self.audio_stream = AudioStream()
        
        # Connection settings
        self.connection_settings = speechmatics.models.ConnectionSettings(
            url=SM_URL,
            auth_token=SM_TOKEN,
        )
        
        # Audio settings
        self.audio_settings = speechmatics.models.AudioSettings(
            sample_rate=16000,
            encoding="pcm_s16le",
            chunk_size=1024,
        )
        
        # Transcription config
        self.transcription_config = speechmatics.models.TranscriptionConfig(
            language="pt",
            enable_partials=True,
            operating_point="enhanced",
            max_delay=1.0,
            enable_entities=True,
        )
    
    def setup_event_handlers(self):
        """Set up event handlers for Speechmatics client"""
        # Final transcript handler
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.AddTranscript,
            lambda msg: self._handle_transcript(msg, is_partial=False)
        )
        
        # Partial transcript handler
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.AddPartialTranscript,
            lambda msg: self._handle_transcript(msg, is_partial=True)
        )
        
        # Error handler
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.Error,
            lambda msg: self.send_message_callback(f"Error: {msg.get('reason', 'Unknown error')}")
        )
        
        # Recognition started handler
        self.client.add_event_handler(
            speechmatics.models.ServerMessageType.RecognitionStarted,
            lambda msg: self.send_message_callback("🎤 Transcription started - speak now!")
        )
    
    def _handle_transcript(self, msg, is_partial):
        """Handle transcript messages"""
        try:
            transcript = msg.get("metadata", {}).get("transcript", "")
            if transcript.strip():
                self.session.add_transcript(transcript, is_partial)
                if is_partial:
                    self.send_message_callback(f"[partial] {transcript}")
                else:
                    self.send_message_callback(transcript)
        except Exception as e:
            log.error(f"Error handling transcript: {e}")
    
    def add_audio_data(self, audio_data):
        """Add audio data to stream and session"""
        self.audio_stream.add_audio_data(audio_data)
        self.session.add_audio_chunk(audio_data)
    
    def start_transcription(self):
        """Start the Speechmatics transcription"""
        try:
            self.client = speechmatics.client.WebsocketClient(self.connection_settings)
            self.setup_event_handlers()
            
            log.info("Starting Speechmatics transcription...")
            self.client.run_synchronously(
                self.audio_stream,
                self.transcription_config,
                self.audio_settings
            )
            
        except Exception as e:
            log.error(f"Speechmatics transcription error: {e}")
            self.send_message_callback(f"Transcription error: {str(e)}")
    
    def stop_transcription(self):
        """Stop the transcription"""
        self.audio_stream.close()


# Global message queue for thread-safe communication
message_queue = queue.Queue()

def message_sender_callback(message):
    """Thread-safe callback to send messages to WebSocket"""
    message_queue.put(message)


@app.websocket("/ws")
async def websocket_proxy(client_ws: WebSocket):
    await client_ws.accept()
    log.info("Client connected")
    
    # Get session ID from query parameters
    session_id = client_ws.query_params.get("session_id")
    if not session_id:
        # Fallback to generating one if not provided (for backward compatibility)
        session_id = datetime.now().strftime('%Y%m%d_%H%M%S')
        log.warning("No session_id provided, generated fallback: {session_id}")
    else:
        log.info(f"Using provided session_id: {session_id}")
    
    # Create session
    session = TranscriptionSession(session_id)
    
    # Send initial connection message
    await client_ws.send_text("Connected to server successfully!")
    await client_ws.send_text(f"Using session ID: {session_id}")

    # Create Speechmatics handler
    sm_handler = SpeechmaticsHandler(message_sender_callback, session)
    
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
                
                await asyncio.sleep(0.01)
                
            except Exception as e:
                log.error(f"Error in message handler: {e}")
                break

    # Start message handler task
    message_task = asyncio.create_task(message_handler())

    chunk_count = 0
    try:
        # Receive audio from browser
        while True:
            data = await client_ws.receive_bytes()
            chunk_count += 1
            
            # Add audio data to handler
            sm_handler.add_audio_data(data)
            
            # Send acknowledgment every 10 chunks to reduce traffic
            if chunk_count % 10 == 0:
                await client_ws.send_text(f"Received {chunk_count} chunks")
            
    except WebSocketDisconnect:
        log.info("Browser disconnected")
    except Exception as e:
        log.error(f"WebSocket error: {e}")
    finally:
        # Clean up
        log.info("Cleaning up session...")
        sm_handler.stop_transcription()
        
        # Cancel message handler
        message_task.cancel()
        
        # Wait for clean shutdown
        try:
            transcription_future.result(timeout=2.0)
        except:
            pass
        
        executor.shutdown(wait=False)
        
        # Save session data
        audio_file, transcript_json, transcript_txt = session.save_session()
        log.info(f"Session ended. Total chunks: {chunk_count}")
        log.info(f"Session files saved: {audio_file}, {transcript_json}, {transcript_txt}")
        
        # Send session timestamp to client before closing
        try:
            await client_ws.send_text(f"SESSION_ENDED:{session_id}")
        except:
            pass


# ------------------------------------------------------------------
# Medical‑report generation utilities
# ------------------------------------------------------------------

@app.get("/health")
async def health_check():
    """Health check endpoint for AWS deployment monitoring"""
    return {"status": "healthy", "service": "ai-backend"}



@app.post("/report")
async def get_medical_report(request: ReportRequest):
    """
    Generate and return a medical report given raw transcript and template strings.
    """
    prompt = (
        "Você é um médico assistente virtual especializado em redação de "
        "prontuários. Leia a conversa abaixo, leve em conta as anotações não ditas "
        "pelo clínico e preencha o template a seguir. Mantenha os títulos em português "
        "exatamente como estão no template. Deixe campos em branco caso a informação "
        "não esteja presente.\n\n"
        "Nao faça nenhuma hipótese diagnóstica, apenas preencha o template com as "
        "informações presentes na transcrição e nas anotações do clínico.\n"
        f"### TRANSCRIÇÃO DA CONSULTA\n```{request.transcript}```\n\n"
        f"### ANOTAÇÕES NÃO DITAS (dos clínico)\n```{request.unspoken_notes}```\n\n"
        f"### TEMPLATE\n{request.template}\n\n"
        "### PRONTUÁRIO COMPLETO"
    )
    try:
        response = openai.chat.completions.create(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": prompt}],
            temperature=0.1,
        )
        report_md = response.choices[0].message.content.strip()
    except Exception as exc:
        log.error(f"Error generating report: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))
    return {"report": report_md}

if __name__ == "__main__":
    if not SM_TOKEN:
        log.error("Please set SPEECHMATICS_API_TOKEN environment variable")
    else:
        log.info(f"Starting server on port {uvicorn_config['port']}...")
    uvicorn.run("server:app", **uvicorn_config)