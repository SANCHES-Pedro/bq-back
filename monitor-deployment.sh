#!/bin/bash

# Deployment Monitoring Script
set -e

# Configuration
PROJECT_NAME="ai-backend"
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${PROJECT_NAME}-stack"

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
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

monitor_stack() {
    log "🔍 Monitoring CloudFormation stack: ${STACK_NAME}"
    echo ""
    
    while true; do
        # Clear screen for better readability
        clear
        
        echo "=== CloudFormation Stack Monitor ==="
        echo "Stack: ${STACK_NAME}"
        echo "Region: ${AWS_REGION}"
        echo "Time: $(date)"
        echo ""
        
        # Get stack status
        if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} &> /dev/null; then
            STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].StackStatus' --output text)
            
            case $STACK_STATUS in
                "CREATE_IN_PROGRESS")
                    info "🔄 Stack Status: CREATING..."
                    ;;
                "CREATE_COMPLETE")
                    log "✅ Stack Status: COMPLETE!"
                    ;;
                "CREATE_FAILED")
                    error "❌ Stack Status: FAILED!"
                    ;;
                "UPDATE_IN_PROGRESS")
                    info "🔄 Stack Status: UPDATING..."
                    ;;
                "UPDATE_COMPLETE")
                    log "✅ Stack Status: UPDATE COMPLETE!"
                    ;;
                *)
                    warn "⚠️  Stack Status: ${STACK_STATUS}"
                    ;;
            esac
            
            echo ""
            
            # Show recent events
            info "📋 Recent Stack Events:"
            aws cloudformation describe-stack-events \
                --stack-name ${STACK_NAME} \
                --region ${AWS_REGION} \
                --query 'StackEvents[0:8].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
                --output table 2>/dev/null || echo "No events available"
            
            # Show stack outputs if available
            if [[ "$STACK_STATUS" == "CREATE_COMPLETE" || "$STACK_STATUS" == "UPDATE_COMPLETE" ]]; then
                echo ""
                info "🎯 Stack Outputs:"
                aws cloudformation describe-stacks \
                    --stack-name ${STACK_NAME} \
                    --region ${AWS_REGION} \
                    --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL` || OutputKey==`WebSocketURL` || OutputKey==`DomainName`].[OutputKey,OutputValue]' \
                    --output table 2>/dev/null || echo "No outputs available yet"
                
                echo ""
                log "🎉 Deployment completed successfully!"
                echo ""
                info "🔗 Your endpoints:"
                DOMAIN_NAME=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Parameters[?ParameterKey==`DomainName`].ParameterValue' --output text 2>/dev/null)
                if [ ! -z "$DOMAIN_NAME" ]; then
                    echo "  • API: https://${DOMAIN_NAME}"
                    echo "  • WebSocket: wss://${DOMAIN_NAME}/ws"
                    echo "  • Health: https://${DOMAIN_NAME}/health"
                fi
                
                echo ""
                info "🧪 Test your deployment:"
                echo "  ./deploy/deploy.sh test"
                
                break
            fi
            
            # Check for failures
            if [[ "$STACK_STATUS" == *"FAILED"* ]]; then
                echo ""
                error "💥 Stack creation failed! Recent failed events:"
                aws cloudformation describe-stack-events \
                    --stack-name ${STACK_NAME} \
                    --region ${AWS_REGION} \
                    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
                    --output table 2>/dev/null
                break
            fi
            
        else
            error "❌ Stack not found: ${STACK_NAME}"
            break
        fi
        
        echo ""
        echo "⏱️  Refreshing in 30 seconds... (Press Ctrl+C to exit)"
        sleep 30
    done
}

# Show usage if no arguments
if [ $# -eq 0 ]; then
    echo "Usage: $0 [monitor|status|events]"
    echo ""
    echo "Commands:"
    echo "  monitor  - Real-time monitoring (default)"
    echo "  status   - One-time status check"
    echo "  events   - Show recent stack events"
    echo ""
    exit 0
fi

case "${1:-monitor}" in
    monitor)
        monitor_stack
        ;;
    status)
        ./deploy/deploy.sh status
        ;;
    events)
        log "Recent CloudFormation events:"
        aws cloudformation describe-stack-events \
            --stack-name ${STACK_NAME} \
            --region ${AWS_REGION} \
            --query 'StackEvents[0:10].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
            --output table
        ;;
    *)
        error "Unknown command: $1"
        exit 1
        ;;
esac 