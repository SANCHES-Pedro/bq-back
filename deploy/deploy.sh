#!/bin/bash

# AWS Deployment Script for AI Backend
# This script helps deploy the AI backend to AWS using ECS with Fargate

set -e

# Configuration
PROJECT_NAME="ai-backend"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}"
STACK_NAME="${PROJECT_NAME}-stack"
DOMAIN_NAME="${DOMAIN_NAME:-api.escribamed.com}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
    fi
    
    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install it first."
    fi
    
    if ! docker info &> /dev/null; then
        error "Docker is not running. Please start Docker."
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Please run 'aws configure'."
    fi
    
    log "Prerequisites check passed!"
}

create_ecr_repository() {
    log "Creating ECR repository..."
    
    if aws ecr describe-repositories --repository-names ${PROJECT_NAME} --region ${AWS_REGION} &> /dev/null; then
        warn "ECR repository ${PROJECT_NAME} already exists"
    else
        aws ecr create-repository --repository-name ${PROJECT_NAME} --region ${AWS_REGION}
        log "ECR repository created: ${ECR_REPOSITORY_URI}"
    fi
}

build_and_push_image() {
    log "Building and pushing Docker image..."
    
    # Get ECR login token
    aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REPOSITORY_URI}
    
    # Build image with explicit platform for AWS Fargate compatibility
    docker build --platform linux/amd64 -t ${PROJECT_NAME}:latest .
    
    # Tag image for ECR
    docker tag ${PROJECT_NAME}:latest ${ECR_REPOSITORY_URI}:latest
    
    # Push image
    docker push ${ECR_REPOSITORY_URI}:latest
    
    log "Image pushed to ECR: ${ECR_REPOSITORY_URI}:latest"
}

create_secrets() {
    log "Setting up AWS Secrets Manager secrets..."
    
    # OpenAI API Key
    if ! aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/openai-api-key --region ${AWS_REGION} &> /dev/null; then
        if [ -z "$OPENAI_API_KEY" ]; then
            read -p "Enter your OpenAI API Key: " -s OPENAI_API_KEY
            echo
        fi
        aws secretsmanager create-secret --name ${PROJECT_NAME}/openai-api-key --secret-string "$OPENAI_API_KEY" --region ${AWS_REGION}
        log "OpenAI API Key secret created"
    else
        warn "OpenAI API Key secret already exists"
    fi
    
    # Speechmatics API Token
    if ! aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/speechmatics-token --region ${AWS_REGION} &> /dev/null; then
        if [ -z "$SPEECHMATICS_API_TOKEN" ]; then
            read -p "Enter your Speechmatics API Token: " -s SPEECHMATICS_API_TOKEN
            echo
        fi
        aws secretsmanager create-secret --name ${PROJECT_NAME}/speechmatics-token --secret-string "$SPEECHMATICS_API_TOKEN" --region ${AWS_REGION}
        log "Speechmatics API Token secret created"
    else
        warn "Speechmatics API Token secret already exists"
    fi
}

cleanup_stack() {
    log "Cleaning up existing stack..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} &> /dev/null; then
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].StackStatus' --output text)
        
        # If stack is in DELETE_IN_PROGRESS, wait for it to complete
        if [ "$STACK_STATUS" = "DELETE_IN_PROGRESS" ]; then
            log "Stack is being deleted. Waiting for deletion to complete..."
            aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME} --region ${AWS_REGION}
        else
            # Delete the stack
            log "Deleting existing stack..."
            aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${AWS_REGION}
            aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME} --region ${AWS_REGION}
        fi
    else
        log "No existing stack found."
    fi
}

deploy_infrastructure() {
    log "Deploying infrastructure with CloudFormation..."
    
    # Clean up any existing stack first
    cleanup_stack
    
    # Get secret ARNs
    OPENAI_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/openai-api-key --region ${AWS_REGION} --query ARN --output text)
    SPEECHMATICS_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/speechmatics-token --region ${AWS_REGION} --query ARN --output text)
    
    # Get Hosted Zone ID if not provided
    if [ -z "$HOSTED_ZONE_ID" ]; then
        log "Looking up Route53 Hosted Zone ID for escribamed.com..."
        HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='escribamed.com.'].Id" --output text | cut -d'/' -f3)
        if [ -z "$HOSTED_ZONE_ID" ]; then
            error "Could not find Route53 Hosted Zone for escribamed.com. Please provide HOSTED_ZONE_ID manually."
        fi
        log "Found Hosted Zone ID: ${HOSTED_ZONE_ID}"
    fi
    
    # Validate template first
    log "Validating CloudFormation template..."
    aws cloudformation validate-template --template-body file://aws/cloudformation-template.yaml --region ${AWS_REGION}
    
    # Deploy with minimal wait time for stack creation
    log "Creating CloudFormation stack..."
    if ! aws cloudformation deploy \
        --template-file aws/cloudformation-template.yaml \
        --stack-name ${STACK_NAME} \
        --parameter-overrides \
            ProjectName=${PROJECT_NAME} \
            ContainerImage=${ECR_REPOSITORY_URI}:latest \
            OpenAIApiKeySecretArn=${OPENAI_SECRET_ARN} \
            SpeechmaticsTokenSecretArn=${SPEECHMATICS_SECRET_ARN} \
            DomainName=${DOMAIN_NAME} \
            HostedZoneId=${HOSTED_ZONE_ID} \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION} \
        --no-fail-on-empty-changeset; then
        
        error "Stack deployment failed. Checking stack events..."
        
        # Get the most recent stack events
        log "Recent stack events:"
        aws cloudformation describe-stack-events \
            --stack-name ${STACK_NAME} \
            --region ${AWS_REGION} \
            --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED`].[LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
            --output table
        
        error "Deployment failed. See stack events above for details."
    fi
    
    # Wait for the ALB to be available
    log "Waiting for Load Balancer to be available..."
    while true; do
        ALB_DNS=$(AWS_PAGER="" aws elbv2 describe-load-balancers --names ${PROJECT_NAME}-alb --region ${AWS_REGION} --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
        if [ ! -z "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
            log "Load Balancer is available: ${ALB_DNS}"
            break
        fi
        sleep 10
    done
    
    # Wait for SSL certificate validation
    log "Waiting for SSL certificate validation..."
    CERT_ARN=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`CertificateArn`].OutputValue' --output text)
    
    if [ ! -z "$CERT_ARN" ]; then
        VALIDATION_ATTEMPTS=0
        MAX_VALIDATION_ATTEMPTS=20  # 10 minutes
        
        while [ $VALIDATION_ATTEMPTS -lt $MAX_VALIDATION_ATTEMPTS ]; do
            CERT_STATUS=$(aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.Status' --output text)
            
            if [ "$CERT_STATUS" = "ISSUED" ]; then
                log "✅ SSL Certificate validated successfully!"
                break
            elif [ "$CERT_STATUS" = "FAILED" ]; then
                error "❌ SSL certificate validation failed. Please check the DNS validation records."
            elif [ "$CERT_STATUS" = "PENDING_VALIDATION" ]; then
                if [ $VALIDATION_ATTEMPTS -eq 0 ]; then
                    log "Certificate is pending DNS validation. Showing validation records:"
                    aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.DomainValidationOptions[0].ResourceRecord.{Name:Name,Type:Type,Value:Value}' --output table
                fi
                log "Certificate status: ${CERT_STATUS}. Waiting for validation... (attempt $((VALIDATION_ATTEMPTS + 1))/${MAX_VALIDATION_ATTEMPTS})"
            else
                log "Certificate status: ${CERT_STATUS}. Waiting... (attempt $((VALIDATION_ATTEMPTS + 1))/${MAX_VALIDATION_ATTEMPTS})"
            fi
            
            VALIDATION_ATTEMPTS=$((VALIDATION_ATTEMPTS + 1))
            sleep 30
        done
        
        if [ $VALIDATION_ATTEMPTS -eq $MAX_VALIDATION_ATTEMPTS ]; then
            warn "Certificate validation is taking longer than expected. You can check status later with: $0 validate"
        fi
    fi
    
    # Wait for ECS service to be running
    log "Waiting for ECS service to be stable..."
    aws ecs wait services-stable --cluster ${PROJECT_NAME}-cluster --services ${PROJECT_NAME}-service --region ${AWS_REGION}
    
    log "🎉 Deployment completed successfully!"
    log "📊 Deployment Summary:"
    log "   • API URL: https://${DOMAIN_NAME}"
    log "   • WebSocket URL: wss://${DOMAIN_NAME}/ws"
    log "   • Health Check: https://${DOMAIN_NAME}/health"
    log "   • ALB DNS: ${ALB_DNS}"
    log ""
    log "🔍 Next steps:"
    log "   • Test deployment: $0 test"
    log "   • Check status: $0 status"
    log "   • View logs: $0 logs"
}

show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  deploy     - Full deployment (ECR + Secrets + Infrastructure)"
    echo "  build      - Build and push Docker image only"
    echo "  secrets    - Create AWS Secrets Manager secrets only"
    echo "  infra      - Deploy infrastructure only"
    echo "  status     - Show deployment status"
    echo "  logs       - Show application logs"
    echo "  cleanup    - Delete all AWS resources"
    echo "  validate   - Validate SSL certificate"
    echo "  test       - Test the deployed API"
    echo ""
    echo "Environment Variables:"
    echo "  DOMAIN_NAME        - Domain for the API (default: api.escribamed.com)"
    echo "  HOSTED_ZONE_ID     - Route53 Hosted Zone ID (auto-detected if not set)"
    echo "  AWS_REGION         - AWS Region (default: us-east-1)"
    echo "  OPENAI_API_KEY     - OpenAI API Key"
    echo "  SPEECHMATICS_API_TOKEN - Speechmatics API Token"
    echo ""
}

show_status() {
    log "Checking deployment status..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} &> /dev/null; then
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].StackStatus' --output text)
        echo "CloudFormation Stack Status: ${STACK_STATUS}"
        
        # Get domain name from stack parameters
        DOMAIN_NAME=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Parameters[?ParameterKey==`DomainName`].ParameterValue' --output text)
        
        if [ ! -z "$DOMAIN_NAME" ]; then
            echo "Application URL: https://${DOMAIN_NAME}"
            echo "WebSocket URL: wss://${DOMAIN_NAME}/ws"
            echo "Health Check: https://${DOMAIN_NAME}/health"
            
            # Check if the service is healthy
            SERVICE_STATUS=$(aws ecs describe-services --cluster ${PROJECT_NAME}-cluster --services ${PROJECT_NAME}-service --region ${AWS_REGION} --query 'services[0].runningCount' --output text)
            echo "Running Tasks: ${SERVICE_STATUS}"
            
            # Check SSL certificate status
            CERT_ARN=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`CertificateArn`].OutputValue' --output text)
            if [ ! -z "$CERT_ARN" ]; then
                CERT_STATUS=$(aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.Status' --output text)
                echo "SSL Certificate Status: ${CERT_STATUS}"
            fi
        else
            echo "Domain name not configured"
        fi
    else
        echo "CloudFormation stack not found"
    fi
}

show_logs() {
    log "Fetching application logs..."
    aws logs tail /ecs/${PROJECT_NAME} --region ${AWS_REGION} --follow
}

cleanup() {
    warn "This will delete all AWS resources for ${PROJECT_NAME}. Are you sure? (y/N)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        cleanup_stack
        
        log "Deleting ECR repository..."
        aws ecr delete-repository --repository-name ${PROJECT_NAME} --force --region ${AWS_REGION}
        
        log "Deleting secrets..."
        aws secretsmanager delete-secret --secret-id ${PROJECT_NAME}/openai-api-key --force-delete-without-recovery --region ${AWS_REGION}
        aws secretsmanager delete-secret --secret-id ${PROJECT_NAME}/speechmatics-token --force-delete-without-recovery --region ${AWS_REGION}
        
        log "Cleanup completed!"
    else
        log "Cleanup cancelled."
    fi
}

validate_certificate() {
    log "Validating SSL certificate..."
    
    # Get certificate ARN from CloudFormation stack
    CERT_ARN=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`CertificateArn`].OutputValue' --output text 2>/dev/null)
    
    if [ -z "$CERT_ARN" ]; then
        error "Certificate ARN not found. Deploy the infrastructure first."
    fi
    
    # Check certificate status
    CERT_STATUS=$(aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.Status' --output text)
    echo "Certificate Status: ${CERT_STATUS}"
    
    if [ "$CERT_STATUS" = "ISSUED" ]; then
        log "Certificate is valid and issued!"
        
        # Show certificate details
        aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.{DomainName:DomainName,Status:Status,Issuer:Issuer,NotAfter:NotAfter}' --output table
    elif [ "$CERT_STATUS" = "PENDING_VALIDATION" ]; then
        warn "Certificate is pending validation. DNS records may need to be created."
        
        # Show DNS validation records
        log "DNS validation records needed:"
        aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} --query 'Certificate.DomainValidationOptions[0].ResourceRecord.{Name:Name,Type:Type,Value:Value}' --output table
    else
        error "Certificate status is ${CERT_STATUS}. Check AWS Console for details."
    fi
}

test_deployment() {
    log "Testing deployed API..."
    
    # Get domain name from stack
    DOMAIN_NAME=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Parameters[?ParameterKey==`DomainName`].ParameterValue' --output text 2>/dev/null)
    
    if [ -z "$DOMAIN_NAME" ]; then
        error "Domain name not found. Deploy the infrastructure first."
    fi
    
    # Test health endpoint
    log "Testing health endpoint..."
    if curl -f -s "https://${DOMAIN_NAME}/health" > /dev/null; then
        log "✅ Health endpoint is working"
        curl -s "https://${DOMAIN_NAME}/health" | jq . || echo "Health check passed"
    else
        error "❌ Health endpoint failed"
    fi
    
    # Test CORS headers
    log "Testing CORS headers..."
    CORS_RESPONSE=$(curl -s -I -H "Origin: https://app.escribamed.com" "https://${DOMAIN_NAME}/health")
    if echo "$CORS_RESPONSE" | grep -i "access-control-allow-origin" > /dev/null; then
        log "✅ CORS headers are present"
    else
        warn "❌ CORS headers not found"
    fi
    
    # Test WebSocket endpoint
    log "Testing WebSocket endpoint (connection test)..."
    if command -v wscat &> /dev/null; then
        echo "Testing WebSocket connection..." 
        timeout 5 wscat -c "wss://${DOMAIN_NAME}/ws?session_id=test" --no-check || warn "WebSocket test timed out (expected for connection test)"
    else
        warn "wscat not installed. Install with: npm install -g wscat"
    fi
    
    log "API URL: https://${DOMAIN_NAME}"
    log "WebSocket URL: wss://${DOMAIN_NAME}/ws"
}

# Main script logic
case "${1:-deploy}" in
    deploy)
        check_prerequisites
        create_ecr_repository
        build_and_push_image
        create_secrets
        deploy_infrastructure
        ;;
    build)
        check_prerequisites
        create_ecr_repository
        build_and_push_image
        ;;
    secrets)
        create_secrets
        ;;
    infra)
        deploy_infrastructure
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    cleanup)
        cleanup
        ;;
    validate)
        validate_certificate
        ;;
    test)
        test_deployment
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        error "Unknown command: $1"
        show_usage
        ;;
esac 