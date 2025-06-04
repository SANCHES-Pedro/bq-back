# AWS Deployment Guide for AI Backend

This guide explains how to deploy your AI backend (FastAPI + Speechmatics + OpenAI) to AWS using containerization.

## 🚀 Deployment Options

### Option 1: Automated Deployment (Recommended)

Use the provided deployment script for a fully automated setup.

### Option 2: AWS App Runner (Simpler)

For a managed container service with minimal configuration.

### Option 3: Manual ECS Deployment

For full control over the infrastructure.

---

## 📋 Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** installed and configured
3. **Docker** installed and running
4. **API Keys**:
   - OpenAI API Key
   - Speechmatics API Token

### Installing Prerequisites

```bash
# Install AWS CLI (macOS)
brew install awscli

# Configure AWS credentials
aws configure

# Install Docker Desktop
# Download from: https://docs.docker.com/desktop/
```

---

## 🎯 Option 1: Automated Deployment (Recommended)

### Step 1: Prepare Environment Variables

```bash
export AWS_REGION="us-east-1"  # or your preferred region
export OPENAI_API_KEY="your-openai-api-key"
export SPEECHMATICS_API_TOKEN="your-speechmatics-token"
```

### Step 2: Run Deployment

```bash
# Full deployment (everything)
./deploy/deploy.sh deploy

# Or step by step:
./deploy/deploy.sh build      # Build and push container
./deploy/deploy.sh secrets    # Create secrets in AWS
./deploy/deploy.sh infra      # Deploy infrastructure
```

### Step 3: Check Status

```bash
./deploy/deploy.sh status
```

Your application will be available at the ALB URL provided in the output.

---

## 🔍 Testing Your Deployment

Get the ALB URL from the output of the following command:
AWS_PAGER="" aws elbv2 describe-load-balancers --names ai-backend-alb --region us-east-1 --query 'LoadBalancers[0].DNSName' --output text

### Health Check

```bash
curl http://ai-backend-alb-1939037997.us-east-1.elb.amazonaws.com/health
```

**Your Live URL:** `http://ai-backend-alb-1939037997.us-east-1.elb.amazonaws.com`

### WebSocket Test

```javascript
const ws = new WebSocket(
  "ws://ai-backend-alb-1939037997.us-east-1.elb.amazonaws.com/ws?session_id=test123"
);
ws.onopen = () => console.log("Connected");
ws.onmessage = (event) => console.log("Message:", event.data);
```

### Medical Report API Test

```bash
curl -X POST http://ai-backend-alb-1939037997.us-east-1.elb.amazonaws.com/report \
  -H "Content-Type: application/json" \
  -d '{
    "transcript": "Patient complains of headache...",
    "template": "# Medical Report\n## Chief Complaint\n\n## History\n\n",
    "unspoken_notes": "Patient appears anxious"
  }'
```

---

## 📊 Monitoring and Logs

### View Logs

```bash
./deploy/deploy.sh logs

# Or manually:
aws logs tail /ecs/ai-backend --region us-east-1 --follow
```

### CloudWatch Metrics

Monitor your application in AWS CloudWatch:

- CPU/Memory utilization
- Request count and latency
- Health check status

### Application Load Balancer

- Access logs can be enabled for detailed request tracking
- Health checks monitor `/health` endpoint

---

## 💰 Cost Optimization

### ECS Fargate Pricing (us-east-1)

- **vCPU**: $0.04048 per hour
- **Memory**: $0.004445 per GB per hour
- **Data Transfer**: First 1GB free, then $0.09/GB

### Cost Estimate (24/7 operation)

- **Basic setup** (0.5 vCPU, 1GB RAM): ~$15-20/month
- **Production setup** (1 vCPU, 2GB RAM): ~$30-40/month

### Cost Optimization Tips

1. **Use Spot instances** for development
2. **Schedule scaling** based on usage patterns
3. **Monitor unused resources** with AWS Trusted Advisor

---

## 🔧 Troubleshooting

### Common Issues

#### 1. Container Won't Start

```bash
# Check logs
aws logs describe-log-streams --log-group-name /ecs/ai-backend
aws logs get-log-events --log-group-name /ecs/ai-backend --log-stream-name STREAM_NAME
```

#### 2. WebSocket Connection Issues

- Ensure ALB has sticky sessions enabled
- Check security groups allow WebSocket traffic
- Verify CORS settings in the application

#### 3. API Key Issues

```bash
# Verify secrets exist
aws secretsmanager list-secrets --filter Key=name,Values=ai-backend/

# Check task role permissions
aws iam get-role --role-name ecsTaskExecutionRole
```

#### 4. Health Check Failures

- Verify `/health` endpoint responds correctly
- Check container port mapping (8000)
- Ensure security groups allow traffic

### Performance Tuning

#### 1. Container Resources

```yaml
# Increase for high load
cpu: "1024" # 1 vCPU
memory: "2048" # 2 GB
```

#### 2. Auto Scaling

```yaml
# Add to ECS service
autoScalingGroup:
  minCapacity: 1
  maxCapacity: 10
  targetCPUUtilization: 70
```

#### 3. Load Balancer Settings

```yaml
# Optimize for WebSocket connections
targetGroup:
  stickinessDuration: 86400 # 24 hours
  healthCheckGracePeriod: 300
```

---

## 🛡️ Security Best Practices

### 1. Network Security

- Use private subnets for ECS tasks (requires NAT Gateway)
- Restrict security groups to necessary ports only
- Enable VPC Flow Logs for monitoring

### 2. Secrets Management

- Never store API keys in code or environment variables
- Use AWS Secrets Manager or Parameter Store
- Rotate secrets regularly

### 3. Container Security

- Use minimal base images
- Run containers as non-root user
- Keep dependencies updated

### 4. Monitoring

- Enable AWS CloudTrail for API auditing
- Set up CloudWatch alarms for anomalies
- Use AWS Config for compliance monitoring

---

## 🔄 CI/CD Integration

### GitHub Actions Example

```yaml
name: Deploy to AWS
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Deploy
        run: ./deploy/deploy.sh build
```

---

## 📞 Support

### AWS Resources

- [ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [Application Load Balancer Guide](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/)
- [Secrets Manager](https://docs.aws.amazon.com/secretsmanager/)

### Cleanup

```bash
# Remove all resources
./deploy/deploy.sh cleanup
```

This will delete:

- CloudFormation stack and all resources
- ECR repository and images
- Secrets in AWS Secrets Manager
