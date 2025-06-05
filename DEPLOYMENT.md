# AWS Deployment Guide for AI Backend with WSS Support

This guide explains how to deploy your AI backend (FastAPI + Speechmatics + OpenAI) to AWS with full WSS (WebSocket Secure) support for your existing app.escribamed.com domain.

## 🚀 Quick Start

### Prerequisites

- AWS Account with appropriate permissions
- Domain: escribamed.com (configured in Route53)
- API Keys: OpenAI and Speechmatics

### One-Command Deployment

```bash
# Set your API keys
export OPENAI_API_KEY="your-openai-api-key"
export SPEECHMATICS_API_TOKEN="your-speechmatics-token"

# Deploy everything
./deploy/deploy.sh deploy
```

Your backend will be available at:

- **API**: https://api.escribamed.com
- **WebSocket**: wss://api.escribamed.com/ws
- **Health Check**: https://api.escribamed.com/health

## 📋 Detailed Setup

### Step 1: Environment Configuration

```bash
# Required
export OPENAI_API_KEY="your-openai-api-key"
export SPEECHMATICS_API_TOKEN="your-speechmatics-token"

# Optional (with defaults)
export DOMAIN_NAME="api.escribamed.com"
export AWS_REGION="us-east-1"
export HOSTED_ZONE_ID="auto-detected"
```

### Step 2: Deployment Commands

```bash
# Full deployment (recommended)
./deploy/deploy.sh deploy

# Or step by step:
./deploy/deploy.sh build      # Build and push container
./deploy/deploy.sh secrets    # Create secrets in AWS
./deploy/deploy.sh infra      # Deploy infrastructure
```

### Step 3: Validation and Testing

```bash
# Check deployment status
./deploy/deploy.sh status

# Validate SSL certificate
./deploy/deploy.sh validate

# Test all endpoints
./deploy/deploy.sh test

# View logs
./deploy/deploy.sh logs
```

## 🔧 What Gets Deployed

### Infrastructure Components

- **ECS Fargate**: Containerized backend service
- **Application Load Balancer**: With SSL termination
- **Route53**: DNS record for api.escribamed.com
- **ACM Certificate**: Auto-validated SSL certificate
- **Secrets Manager**: Secure API key storage
- **CloudWatch**: Logging and monitoring
- **VPC**: Secure network with public subnets

### Security Features

- ✅ HTTPS-only (HTTP redirects to HTTPS)
- ✅ WSS (WebSocket Secure) support
- ✅ CORS configured for app.escribamed.com
- ✅ Secrets stored in AWS Secrets Manager
- ✅ VPC isolation with security groups

## 🌐 Frontend Integration

### NextJS Configuration

Update your NextJS app to use the new backend:

```javascript
// config/api.js
const API_CONFIG = {
  baseURL: "https://api.escribamed.com",
  websocketURL: "wss://api.escribamed.com/ws",
};

// Example WebSocket connection
const ws = new WebSocket(`${API_CONFIG.websocketURL}?session_id=${sessionId}`);

// Example HTTP request
const response = await fetch(`${API_CONFIG.baseURL}/health`);
```

### CORS Support

The backend is pre-configured to accept requests from:

- `https://app.escribamed.com`
- `https://api.escribamed.com`
- `http://localhost:3000` (for development)

## 🔍 Monitoring and Troubleshooting

### Check Deployment Status

```bash
./deploy/deploy.sh status
```

### View Real-time Logs

```bash
./deploy/deploy.sh logs
```

### Test All Endpoints

```bash
./deploy/deploy.sh test
```

### SSL Certificate Issues

```bash
./deploy/deploy.sh validate
```

If certificate validation fails, check:

1. Route53 hosted zone exists for escribamed.com
2. DNS validation records are created
3. Domain ownership is verified

### Common Issues

#### 1. Certificate Pending Validation

```bash
# Check validation records
./deploy/deploy.sh validate

# Manual DNS validation may be required
```

#### 2. Service Not Starting

```bash
# Check ECS service status
aws ecs describe-services --cluster ai-backend-cluster --services ai-backend-service

# Check container logs
./deploy/deploy.sh logs
```

#### 3. WebSocket Connection Issues

- Ensure client uses `wss://` not `ws://`
- Check CORS settings
- Verify security groups allow traffic

## 💰 Cost Estimation

### Monthly Costs (24/7 operation)

- **ECS Fargate** (0.5 vCPU, 1GB): ~$15-20
- **Application Load Balancer**: ~$16
- **Route53** (hosted zone): $0.50
- **ACM Certificate**: Free
- **Data Transfer**: $0.09/GB after 1GB free

**Total**: ~$32-37/month

### Cost Optimization

- Use spot instances for development
- Scale down during off-hours
- Monitor with AWS Cost Explorer

## 🛠️ Advanced Configuration

### Custom Domain

```bash
export DOMAIN_NAME="your-custom-domain.com"
export HOSTED_ZONE_ID="your-zone-id"
./deploy/deploy.sh deploy
```

### Production Scaling

```bash
# Increase container resources
# Edit aws/cloudformation-template.yaml:
Cpu: 1024      # 1 vCPU
Memory: 2048   # 2 GB
```

### Multiple Environments

```bash
# Deploy to staging
export PROJECT_NAME="ai-backend-staging"
export DOMAIN_NAME="api-staging.escribamed.com"
./deploy/deploy.sh deploy
```

## 🧹 Cleanup

```bash
# Delete all AWS resources
./deploy/deploy.sh cleanup
```

This will remove:

- CloudFormation stack
- ECR repository
- Secrets Manager secrets
- Route53 records (manual cleanup may be needed)

## 📞 Support

### Useful Commands

```bash
# Complete help
./deploy/deploy.sh help

# Stack events (for debugging)
aws cloudformation describe-stack-events --stack-name ai-backend-stack

# ECS service details
aws ecs describe-services --cluster ai-backend-cluster --services ai-backend-service
```

### CloudWatch Dashboard

Monitor your deployment in the AWS Console:

- **ECS**: Service health and task status
- **CloudWatch Logs**: Application logs
- **ALB**: Request metrics and health checks
- **ACM**: Certificate status

Your backend is now ready for production with full WSS support! 🚀
