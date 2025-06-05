#!/bin/bash

# Simple deployment script with Route53 configuration
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Set the hosted zone ID
export HOSTED_ZONE_ID="Z05558643C2KVNLKOZ751"
export DOMAIN_NAME="api.escribamed.com"

log "🚀 Starting deployment with Route53 configuration..."
log "Hosted Zone ID: ${HOSTED_ZONE_ID}"
log "Domain: ${DOMAIN_NAME}"

# Check if required environment variables are set
if [ -z "$OPENAI_API_KEY" ]; then
    warn "OPENAI_API_KEY not set. Please set it before running:"
    echo "export OPENAI_API_KEY=\"your-openai-api-key\""
    exit 1
fi

if [ -z "$SPEECHMATICS_API_TOKEN" ]; then
    warn "SPEECHMATICS_API_TOKEN not set. Please set it before running:"
    echo "export SPEECHMATICS_API_TOKEN=\"your-speechmatics-token\""
    exit 1
fi

log "✅ Environment variables configured"
log "🔄 Running deployment..."

# Run the main deployment script
./deploy/deploy.sh deploy

log "🎉 Deployment completed!"
log "Your backend will be available at: https://api.escribamed.com"
log "WebSocket endpoint: wss://api.escribamed.com/ws" 