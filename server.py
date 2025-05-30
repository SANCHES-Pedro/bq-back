from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import asyncio
import os
from datetime import datetime
import logging
import wave
import io
import subprocess
import tempfile
import shutil

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI()

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, replace with your frontend URL
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Create a directory for audio files if it doesn't exist
AUDIO_DIR = "audio_chunks"
os.makedirs(AUDIO_DIR, exist_ok=True)

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    logger.info("WebSocket connection accepted")
    
    # Create a unique session directory for this connection
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    session_dir = os.path.join(AUDIO_DIR, session_id)
    os.makedirs(session_dir, exist_ok=True)
    
    chunk_count = 0
    is_connected = True
    
    try:
        # Send a test message immediately after connection
        await websocket.send_text("Connected to server successfully!")
        logger.info("Sent initial connection message")
        
        while is_connected:
            try:
                # Receive binary data
                data = await websocket.receive_bytes()
                chunk_count += 1
                
                # Log the size of received data
                logger.info(f"Received audio chunk #{chunk_count}, size: {len(data)} bytes")
                
                # Save the WebM chunk to a file
                chunk_file = os.path.join(session_dir, f"chunk_{chunk_count:04d}.webm")
                with open(chunk_file, "wb") as f:
                    f.write(data)
                logger.info(f"Saved WebM chunk to {chunk_file}")
                
                # Send acknowledgment back to client
                await websocket.send_text(f"Received chunk #{chunk_count}")
                
            except WebSocketDisconnect:
                logger.info("Client disconnected")
                is_connected = False
                break
            except Exception as chunk_error:
                logger.error(f"Error processing chunk: {chunk_error}")
                if not is_connected:
                    break
                continue
            
    except WebSocketDisconnect:
        logger.info("Client disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        try:
            if is_connected:
                await websocket.close()
            
        except Exception as close_error:
            logger.error(f"Error closing WebSocket: {close_error}")
        logger.info(f"Session {session_id} ended. Total chunks received: {chunk_count}")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000) 