# Strapi AWS Infrastructure

This directory contains the Infrastructure as Code (IaC) setup for deploying Strapi to AWS using CloudFormation.

## Deployment Approach

This infrastructure deploys the Strapi monorepo's `examples/getstarted` application to AWS. This approach:
- Uses the existing example application from the Strapi source code
- Maintains full compatibility with upstream changes
- Requires no modifications to core Strapi code
- Builds the entire monorepo to resolve workspace dependencies

See [AWS_DEPLOYMENT.md](../AWS_DEPLOYMENT.md) for detailed explanation.

## Architecture Overview

The deployment creates a secure, scalable, and highly available infrastructure with:

- **Multi-AZ VPC** with public, private, and database subnets across 3 availability zones
- **Aurora PostgreSQL** Multi-AZ database cluster for high availability
- **ECS Fargate** for running containerized Strapi application
- **Application Load Balancer** with AWS WAF for security
- **S3 bucket** for media storage with CloudFront CDN
- **CloudFront WAF** (optional) for DDoS protection and security rules on CDN
- **AWS Secrets Manager** for secure credential management
- **Auto-scaling** based on CPU and memory metrics
- **CloudWatch** monitoring and alarms

For detailed architecture diagrams and explanations, see [docs/README.md](docs/README.md).

## Prerequisites

1. AWS CLI installed and configured
2. Docker installed (for building images)
3. jq installed (for JSON parsing)
4. AWS account with appropriate permissions

## Directory Structure

```
infrastructure/
├── cloudformation/          # CloudFormation templates
│   ├── 01-vpc.yaml         # VPC and networking
│   ├── 02-rds.yaml         # RDS PostgreSQL database
│   ├── 03-ecs.yaml         # ECS Fargate service
│   ├── 04-s3-cloudfront.yaml  # S3 and CDN
│   ├── 05-waf-alb.yaml     # WAF security rules for ALB
│   ├── 05-waf-cloudfront.yaml # WAF for CloudFront (us-east-1)
│   ├── 06-secrets.yaml     # Secrets Manager
│   └── master-stack.yaml   # Master nested stack
├── parameters/             # Parameter templates
│   └── *.json.template    # Environment-specific templates
├── scripts/               # Deployment scripts
│   ├── deploy-three-phase.sh # Complete deployment (recommended)
│   ├── deploy-update-service.sh # Update running service
│   ├── cleanup-strapi.sh  # Remove all resources
│   ├── build-and-push.sh  # Docker build utility
│   ├── check-prerequisites.sh # Environment validation
│   ├── list-strapi-stacks.sh # List all stacks
│   └── lib/
│       ├── deploy-enhanced.sh # Internal CloudFormation engine
│       └── process-parameters.sh # Parameter template processor
├── docs/                  # Architecture documentation
│   ├── README.md          # Documentation overview
│   ├── BLOG_HIGH_AVAILABILITY_STRAPI_AWS.md # Complete blog post
│   ├── ARCHITECTURE_DIAGRAM.md # Detailed technical diagram
│   ├── ARCHITECTURE_DIAGRAM_SIMPLE.md # Simplified diagram
│   └── ARCHITECTURE_COMPONENTS_FOR_SLIDES.md # Presentation materials
└── README.md             # This file
```

## Quick Start

### Interactive Deployment (Recommended for first-time users)
```bash
# 1. Navigate to scripts directory
cd infrastructure/scripts

# 2. Deploy Strapi to AWS (will prompt for confirmations)
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2

# 3. Monitor deployment status
./list-strapi-stacks.sh
```

### Non-Interactive Deployment (Recommended for automation)
```bash
# Deploy without any prompts using --force flag
cd infrastructure/scripts
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2 --force
```

**Note**: The `--force` flag skips all interactive prompts and is ideal for CI/CD pipelines. For first-time deployments, we recommend running without `--force` to review changes.

## Deployment Steps

### 1. Configure Environment (Optional)

The `.env` file in the infrastructure directory contains deployment configuration:
```bash
# Edit infrastructure/.env with your values (optional)
# Default values are suitable for development environments
```

### Parameter Templates

The deployment uses parameter templates (`.json.template` files) that are automatically processed during deployment:
- Templates use `{{ACCOUNT_ID}}` placeholder for AWS account ID
- The deployment script automatically generates the actual parameter files
- Generated `.json` files are ignored by git for security
- No manual editing of account IDs is required

### 2. Deploy Infrastructure

#### Option A: Three-Phase Deployment (Recommended - Solves Docker Image Dependency)

```bash
cd infrastructure/scripts

# Deploy using three-phase approach
./deploy-three-phase.sh \
  --project-name strapi \
  --environment production \
  --region us-west-2
```

This approach solves the "chicken and egg" problem where ECS needs a Docker image that doesn't exist yet:

**Phase 1**: Deploy CloudFront WAF in us-east-1 (AWS requirement)
**Phase 2**: Deploy all infrastructure WITHOUT the ECS service
**Phase 3**: Build/push Docker image, then deploy the ECS service

You can skip phases if needed:
```bash
# Skip WAF if already deployed
./deploy-three-phase.sh --skip-phase1

# Only update ECS service with new image
./deploy-three-phase.sh --skip-phase1 --skip-phase2
```

#### Option B: Standard Deployment (No CloudFront WAF)

```bash
cd infrastructure/scripts

# Deploy using the enhanced script (auto-generates bucket name)
./lib/deploy-enhanced.sh \
  --stack-name strapi-production \
  --params-file ../parameters/us-west-2-production.json \
  --region us-west-2

# Note: The parameter file will be automatically generated from the template
# if it doesn't exist
```

The script will:
1. Auto-generate S3 bucket name using your AWS account ID
2. Check for conflicting resources before deployment
3. Create an S3 bucket for templates (if it doesn't exist)
4. Upload and validate all CloudFormation templates
5. Deploy the master stack with progress updates
6. Show clear error messages if deployment fails

### 3. Build and Push Strapi Image

**Note**: If you used the three-phase deployment (Option A), this step is already completed in Phase 3.

For other deployment options, after the infrastructure is deployed:

```bash
# Get ECR repository URI from stack outputs
ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name strapi-production \
  --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
  --output text)

# Build and push image
./build-and-push.sh \
  --repository $ECR_URI \
  --tag latest \
  --update-service strapi-production-cluster:strapi-production-service
```

### 4. Post-Deployment Configuration

1. **Configure Domain Name**
   - Point your domain to the ALB DNS name
   - Configure SSL certificate in ACM and attach to ALB

2. **Update WAF Admin IPs**
   - Edit the Admin IP Set in WAF console
   - Add your office/VPN IP addresses

3. **Configure Strapi**
   - Access Strapi admin at `http://ALB-DNS-NAME/admin`
   - Complete initial setup

4. **Enable HTTPS**
   - Request/import SSL certificate in ACM
   - Add HTTPS listener to ALB
   - Update security groups

5. **Configure CloudFront for Media Files**
   - See [CLOUDFRONT_MEDIA_CONFIGURATION.md](./CLOUDFRONT_MEDIA_CONFIGURATION.md) for details
   - Enables CDN URLs for uploaded media files

## Environment Variables

The deployment automatically configures these environment variables:

- `NODE_ENV`: Environment name
- `HOST`: 0.0.0.0
- `PORT`: 1337
- `DATABASE_CLIENT`: postgres
- `DATABASE_HOST`: RDS endpoint
- `DATABASE_PORT`: 5432
- `DATABASE_NAME`: strapi
- `DATABASE_USERNAME`: From parameters
- `DATABASE_PASSWORD`: From Secrets Manager
- `APP_KEYS`: Auto-generated in Secrets Manager
- `API_TOKEN_SALT`: Auto-generated
- `ADMIN_JWT_SECRET`: Auto-generated
- `TRANSFER_TOKEN_SALT`: Auto-generated
- `JWT_SECRET`: Auto-generated
- `AWS_BUCKET_NAME`: S3 media bucket

## Configuration Options

### Environment Variables (.env file)

Create an `.env` file in the infrastructure directory to customize deployment:

```bash
# Database retention policy
DATABASE_RETENTION=RETAIN  # or DELETE for test environments

# Admin IP whitelist (currently requires manual WAF update post-deployment)
ADMIN_IPS=203.0.113.0/32,198.51.100.0/32  # Your admin IPs
```

### Optional Features

Add these to your parameters file to enable:

```json
{
  "ParameterKey": "EnableVPCFlowLogs",
  "ParameterValue": "true"  // Default: false - Enable for compliance/security monitoring
}
```

## Security Features

1. **Network Security**
   - Private subnets for ECS tasks
   - Database in isolated subnets
   - Security groups with least privilege
   - VPC Flow Logs (optional)

2. **Application Security**
   - AWS WAF protecting ALB and CloudFront
   - Rate limiting enabled
   - SQL injection protection
   - Admin panel IP restrictions

3. **Data Security**
   - Encrypted RDS storage
   - Encrypted S3 buckets
   - Secrets in AWS Secrets Manager
   - SSL/TLS in transit

4. **Access Control**
   - IAM roles with minimal permissions
   - No public EC2 instances
   - CloudFront OAC for S3 access

## Monitoring and Alarms

CloudWatch alarms are configured for:
- High CPU/Memory usage (ECS and RDS)
- Database connections
- Low storage space
- Target group unhealthy hosts
- WAF blocked requests
- CloudFront error rates

## Scaling

Auto-scaling is configured for:
- ECS tasks (2-10 instances based on CPU/memory)
- Target: 70% CPU/memory utilization
- Scale-out cooldown: 60 seconds
- Scale-in cooldown: 300 seconds

## Backup and Recovery

- RDS automated backups: 7 days retention
- Point-in-time recovery enabled
- S3 versioning enabled
- Manual snapshots before major changes

## Cost Optimization

1. **Use smaller instances for non-production**
   - Update `DBInstanceClass` and `TaskCPU/Memory` in parameters

2. **Enable S3 lifecycle policies**
   - Transition to IA after 90 days
   - Transition to Glacier after 180 days

3. **CloudFront caching**
   - Reduces S3 requests
   - Improves performance

## Troubleshooting

For detailed troubleshooting information, see:
- [scripts/README.md](scripts/README.md#troubleshooting) - Script-specific issues
- [cloudformation/README.md](cloudformation/README.md) - Template validation and stack issues

### Quick Troubleshooting

```bash
# Check deployment status
./scripts/list-strapi-stacks.sh

# View stack events for errors
aws cloudformation describe-stack-events \
  --stack-name strapi-production \
  --region us-west-2 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --output table

# Clean up failed deployment
./scripts/cleanup-strapi.sh strapi-production
```

## Strapi Version Upgrades

After initial deployment, to update Strapi versions:

```bash
cd infrastructure/scripts

# 1. Create a database backup
aws rds create-db-cluster-snapshot \
  --db-cluster-snapshot-identifier strapi-backup-$(date +%Y%m%d-%H%M%S) \
  --db-cluster-identifier strapi-production-cluster \
  --region us-west-2

# 2. Update Strapi version in your application
cd ../../examples/getstarted
npm update @strapi/strapi@latest @strapi/plugin-*@latest
npm run build

# 3. Build and push new Docker image
cd ../../infrastructure/scripts
./build-and-push.sh \
  --repository $ECR_URI \
  --tag latest \
  --update-service strapi-production-cluster:strapi-production-service
```

The process will:
1. Create a database snapshot for rollback
2. Build new Docker image with updated Strapi version
3. Push to ECR
4. Update ECS service with zero-downtime rolling deployment
5. Verify health checks pass

### Rollback Process

If issues occur after upgrade:
```bash
# Quick rollback to previous ECS task definition
aws ecs update-service \
  --cluster strapi-production-cluster \
  --service strapi-production-service \
  --task-definition strapi-production:PREVIOUS_REVISION

# If database changes caused issues, restore from snapshot
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier strapi-production-restored \
  --snapshot-identifier SNAPSHOT_ID
```

## Clean Up

### Complete Cleanup (Recommended)

To ensure all Strapi resources are removed from your AWS account:

```bash
cd infrastructure/scripts
./cleanup-strapi.sh
```

This script will:
- Delete all CloudFormation stacks (including failed ones) in us-east-1 and us-west-2
- Remove CloudFront WAF WebACLs
- Empty and delete S3 buckets
- Delete ECR repositories with images
- Remove CloudWatch Log Groups
- Reset the parameters file

### Manual Cleanup

To manually delete specific resources:

```bash
# Delete the stack (this will delete all nested stacks)
aws cloudformation delete-stack --stack-name strapi-production --region us-west-2

# Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name strapi-production --region us-west-2

# Delete WAF stack in us-east-1
aws cloudformation delete-stack --stack-name strapi-production-waf-cloudfront --region us-east-1

# Clean up S3 buckets (must be empty first)
aws s3 rb s3://strapi-cloudformation-templates-YOUR-ACCOUNT-ID --force
```

## Support

For issues or questions:
1. Check CloudFormation events for errors
2. Review CloudWatch logs
3. Verify IAM permissions
4. Check AWS service limits