#!/bin/bash

# DNS Management Script for escribamed.com
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
HOSTED_ZONE_ID="Z05558643C2KVNLKOZ751"

show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  status     - Show current DNS records"
    echo "  nameservers - Show Route53 nameservers"
    echo "  add-app    - Add A record for app.escribamed.com"
    echo "  test       - Test DNS resolution"
    echo "  propagation - Check DNS propagation status"
    echo ""
}

show_status() {
    log "Current DNS records for ${DOMAIN}:"
    aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' --output table
}

show_nameservers() {
    log "Route53 nameservers for ${DOMAIN}:"
    aws route53 get-hosted-zone --id $HOSTED_ZONE_ID --query 'DelegationSet.NameServers' --output table
    
    echo ""
    info "📋 To update your domain's nameservers:"
    echo "1. Go to your domain registrar's control panel"
    echo "2. Find DNS/Nameserver settings"
    echo "3. Replace existing nameservers with the Route53 nameservers above"
    echo "4. Save changes and wait for propagation (up to 48 hours)"
}

add_app_record() {
    echo ""
    warn "⚠️  This will add an A record for app.escribamed.com"
    echo ""
    read -p "Enter the IP address for app.escribamed.com: " APP_IP
    
    if [ -z "$APP_IP" ]; then
        error "IP address is required"
    fi
    
    # Validate IP format (basic check)
    if [[ ! $APP_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "Invalid IP address format"
    fi
    
    log "Creating A record for app.escribamed.com -> $APP_IP"
    
    # Create change batch JSON
    cat > /tmp/change-batch.json << EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "app.escribamed.com",
                "Type": "A",
                "TTL": 300,
                "ResourceRecords": [
                    {
                        "Value": "$APP_IP"
                    }
                ]
            }
        }
    ]
}
EOF

    # Apply the change
    CHANGE_ID=$(aws route53 change-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID \
        --change-batch file:///tmp/change-batch.json \
        --query 'ChangeInfo.Id' --output text)
    
    log "✅ DNS record created. Change ID: $CHANGE_ID"
    log "Waiting for change to propagate..."
    
    aws route53 wait resource-record-sets-changed --id $CHANGE_ID
    
    log "✅ DNS change has propagated!"
    
    # Clean up
    rm /tmp/change-batch.json
}

test_dns() {
    log "Testing DNS resolution..."
    
    echo ""
    info "Testing escribamed.com:"
    nslookup escribamed.com || warn "escribamed.com not resolved"
    
    echo ""
    info "Testing app.escribamed.com:"
    nslookup app.escribamed.com || warn "app.escribamed.com not resolved"
    
    echo ""
    info "Testing api.escribamed.com:"
    nslookup api.escribamed.com || warn "api.escribamed.com not resolved (will be created during backend deployment)"
}

check_propagation() {
    log "Checking DNS propagation status..."
    
    # Check nameservers at different DNS servers
    DNS_SERVERS=("8.8.8.8" "1.1.1.1" "208.67.222.222")
    
    for dns in "${DNS_SERVERS[@]}"; do
        echo ""
        info "Checking via DNS server $dns:"
        
        echo -n "  escribamed.com NS: "
        nslookup -type=NS escribamed.com $dns | grep "nameserver" | head -1 || echo "Not propagated"
        
        echo -n "  app.escribamed.com A: "
        nslookup app.escribamed.com $dns 2>/dev/null | grep "Address:" | tail -1 || echo "Not resolved"
    done
    
    echo ""
    info "🌐 You can also check propagation at: https://dnschecker.org"
}

# Main script logic
case "${1:-status}" in
    status)
        show_status
        ;;
    nameservers)
        show_nameservers
        ;;
    add-app)
        add_app_record
        ;;
    test)
        test_dns
        ;;
    propagation)
        check_propagation
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        error "Unknown command: $1"
        show_usage
        ;;
esac 