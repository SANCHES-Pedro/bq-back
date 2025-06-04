#!/bin/bash

# AWS Deployment Script for AI Backend
# This script helps deploy the AI backend to AWS using ECS with Fargate

set -e

# Configuration
PROJECT_NAME="ai-backend"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT_NAME}"

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

deploy_infrastructure() {
    log "Deploying infrastructure with CloudFormation..."
    
    # Get secret ARNs
    OPENAI_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/openai-api-key --region ${AWS_REGION} --query ARN --output text)
    SPEECHMATICS_SECRET_ARN=$(aws secretsmanager describe-secret --secret-id ${PROJECT_NAME}/speechmatics-token --region ${AWS_REGION} --query ARN --output text)
    
    aws cloudformation deploy \
        --template-file aws/cloudformation-template.yaml \
        --stack-name ${PROJECT_NAME}-stack \
        --parameter-overrides \
            ProjectName=${PROJECT_NAME} \
            ContainerImage=${ECR_REPOSITORY_URI}:latest \
            OpenAIApiKeySecretArn=${OPENAI_SECRET_ARN} \
            SpeechmaticsTokenSecretArn=${SPEECHMATICS_SECRET_ARN} \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION}
    
    # Get outputs
    ALB_URL=$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-stack --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL`].OutputValue' --output text)
    
    log "Deployment completed!"
    log "Your AI Backend is available at: ${ALB_URL}"
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
    echo ""
}

show_status() {
    log "Checking deployment status..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-stack --region ${AWS_REGION} &> /dev/null; then
        STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-stack --region ${AWS_REGION} --query 'Stacks[0].StackStatus' --output text)
        echo "CloudFormation Stack Status: ${STACK_STATUS}"
        
        if [ "$STACK_STATUS" = "CREATE_COMPLETE" ] || [ "$STACK_STATUS" = "UPDATE_COMPLETE" ]; then
            ALB_URL=$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-stack --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL`].OutputValue' --output text)
            echo "Application URL: ${ALB_URL}"
            echo "Health Check: ${ALB_URL}/health"
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
        log "Deleting CloudFormation stack..."
        aws cloudformation delete-stack --stack-name ${PROJECT_NAME}-stack --region ${AWS_REGION}
        
        log "Deleting ECR repository..."
        aws ecr delete-repository --repository-name ${PROJECT_NAME} --region ${AWS_REGION} --force || true
        
        log "Deleting secrets..."
        aws secretsmanager delete-secret --secret-id ${PROJECT_NAME}/openai-api-key --region ${AWS_REGION} --force-delete-without-recovery || true
        aws secretsmanager delete-secret --secret-id ${PROJECT_NAME}/speechmatics-token --region ${AWS_REGION} --force-delete-without-recovery || true
        
        log "Cleanup completed!"
    else
        log "Cleanup cancelled"
    fi
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
    help|--help|-h)
        show_usage
        ;;
    *)
        error "Unknown command: $1"
        show_usage
        ;;
esac 