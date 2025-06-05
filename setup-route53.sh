#!/bin/bash

# Route53 Setup Script for escribamed.com
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

DOMAIN="escribamed.com"

log "Setting up Route53 for ${DOMAIN}..."

# Check if hosted zone already exists
log "Checking if hosted zone already exists..."
EXISTING_ZONE=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text 2>/dev/null || echo "")

if [ ! -z "$EXISTING_ZONE" ]; then
    HOSTED_ZONE_ID=$(echo $EXISTING_ZONE | cut -d'/' -f3)
    warn "Hosted zone already exists for ${DOMAIN}"
    log "Hosted Zone ID: ${HOSTED_ZONE_ID}"
else
    # Create hosted zone
    log "Creating hosted zone for ${DOMAIN}..."
    
    RESULT=$(aws route53 create-hosted-zone \
        --name ${DOMAIN} \
        --caller-reference "escribamed-$(date +%s)" \
        --hosted-zone-config Comment="Hosted zone for ${DOMAIN}")
    
    HOSTED_ZONE_ID=$(echo $RESULT | jq -r '.HostedZone.Id' | cut -d'/' -f3)
    log "✅ Hosted zone created successfully!"
    log "Hosted Zone ID: ${HOSTED_ZONE_ID}"
fi

# Get nameservers
log "Getting nameservers for the hosted zone..."
NAMESERVERS=$(aws route53 get-hosted-zone --id $HOSTED_ZONE_ID --query 'DelegationSet.NameServers' --output table)

echo ""
info "🎯 IMPORTANT: Update your domain's nameservers"
echo ""
echo "Your Route53 nameservers are:"
echo "$NAMESERVERS"
echo ""
info "📋 Steps to complete setup:"
echo "1. Go to your domain registrar (where you bought escribamed.com)"
echo "2. Find the DNS/Nameserver settings"
echo "3. Replace the current nameservers with the Route53 nameservers above"
echo "4. Wait 24-48 hours for DNS propagation"
echo ""

# Test current app subdomain
log "Testing current app.escribamed.com..."
if nslookup app.escribamed.com > /dev/null 2>&1; then
    CURRENT_IP=$(nslookup app.escribamed.com | grep "Address:" | tail -1 | awk '{print $2}')
    warn "app.escribamed.com currently points to: ${CURRENT_IP}"
    echo ""
    info "🔄 After updating nameservers, you'll need to:"
    echo "1. Create an A record for app.escribamed.com pointing to your NextJS app"
    echo "2. The backend will automatically get api.escribamed.com"
    echo ""
else
    log "app.escribamed.com is not currently configured"
fi

# Save hosted zone ID for deployment
echo "export HOSTED_ZONE_ID=\"${HOSTED_ZONE_ID}\"" > .env.route53
log "✅ Hosted Zone ID saved to .env.route53"

echo ""
info "🚀 Ready for deployment!"
echo "Once nameservers are updated, run:"
echo "source .env.route53"
echo "./deploy/deploy.sh deploy"

echo ""
log "Current Hosted Zone ID: ${HOSTED_ZONE_ID}" 