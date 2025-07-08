# Infrastructure Scripts

This directory contains scripts for deploying and managing the Strapi AWS infrastructure.

## 🎯 Primary User Scripts

These are the ONLY scripts you need to use:

### 1. `deploy-three-phase.sh` - Complete Infrastructure Deployment
Use this for initial deployments or infrastructure changes.

#### Basic Usage

```bash
# Deploy everything (new environment) - Interactive mode
./deploy-three-phase.sh

# Deploy with custom settings - Interactive mode
./deploy-three-phase.sh --project-name myapp --environment staging --region us-east-2

# Skip phases if already deployed
./deploy-three-phase.sh --skip-phase1  # Skip WAF (if already exists)
./deploy-three-phase.sh --skip-phase1 --skip-phase2  # Only update Docker/ECS
```

#### Non-Interactive Deployment (Recommended for automation)

```bash
# Deploy with --force flag to skip all prompts
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2 --force
```

#### The --force Flag

**When to use --force:**
- ✅ CI/CD pipelines and automation
- ✅ Scripted deployments
- ✅ When you're confident about the deployment parameters
- ✅ Repeated deployments with known-good configurations
- ✅ When you want to avoid CloudFormation change set reviews

**When NOT to use --force:**
- ❌ First-time deployments (review changes carefully)
- ❌ Production deployments requiring manual verification
- ❌ When making significant infrastructure changes
- ❌ If you're unsure about the deployment impact

**Behavior WITH --force:**
- Skips all interactive prompts
- Automatically approves CloudFormation change sets
- Proceeds without confirmation for Docker builds
- Suitable for automated workflows

**Behavior WITHOUT --force (default):**
- Shows CloudFormation change sets for review before applying
- Prompts for confirmation at key decision points
- Asks for Docker build confirmation if build script is missing
- Safer for manual deployments

**What it does:**
- Phase 1: Deploys CloudFront WAF in us-east-1
- Phase 2: Deploys infrastructure (VPC, RDS, S3, etc.)
- Phase 3: Builds Docker image and deploys ECS service

### 2. `deploy-update-service.sh` - Update Running Service
Use this for code updates and routine deployments (CI/CD).

```bash
# Standard code deployment
./deploy-update-service.sh --stack-name strapi-dev

# Deploy specific version
./deploy-update-service.sh --stack-name strapi-production --tag v1.2.3

# Skip Docker build (use existing image)
./deploy-update-service.sh --stack-name strapi-dev --skip-build
```

**What it does:**
- Builds new Docker image from current code
- Pushes to ECR
- Updates ECS service (rolling deployment)
- NO infrastructure changes

### 3. `cleanup-strapi.sh` - Remove All Resources
Use this to completely remove a Strapi environment.

```bash
# Remove dev environment
./cleanup-strapi.sh strapi-dev

# Force removal without confirmation
./cleanup-strapi.sh strapi-dev --force
```

**Warning:** This deletes ALL resources including databases!

## 📁 Supporting Scripts (Internal Use Only)

These scripts are used internally - you don't need to call them directly:

- `lib/deploy-enhanced.sh` - CloudFormation deployment engine
- `build-and-push.sh` - Docker build and ECR push utility
- `check-prerequisites.sh` - Environment validation
- `list-strapi-stacks.sh` - List all Strapi stacks (utility)

## 🚀 Quick Start

### First Time Deployment
```bash
# 1. Deploy everything (parameter files are auto-generated from templates)
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2

# Note: The deployment automatically:
# - Processes parameter templates with your AWS account ID
# - Creates necessary S3 buckets
# - Manages all AWS resources

# 3. Note the output URLs
# ALB URL: http://strapi-dev-alb-xxxxx.region.elb.amazonaws.com
# CloudFront URL: https://xxxxx.cloudfront.net
```

### Routine Code Updates
```bash
# After making code changes
git commit -m "feat: add new feature"

# Deploy to dev
./deploy-update-service.sh --stack-name strapi-dev

# Deploy to production
./deploy-update-service.sh --stack-name strapi-production
```

### Environment Cleanup
```bash
# Remove entire environment
./cleanup-strapi.sh strapi-dev
```

## 🔧 Prerequisites

Before running any scripts:

1. **Required tools:**
   - AWS CLI v2
   - Docker
   - jq
   - bash 4+

2. **AWS setup:**
   - AWS credentials configured (`aws configure`)
   - Sufficient IAM permissions

3. **Required files:**
   - `Dockerfile.aws` in repository root
   - Parameters file: `../parameters/{region}-{environment}.json`
   - (Optional) `.env` file for custom settings

Run `./check-prerequisites.sh` to verify your environment.

## 🌍 Environment Configuration

### Using .env file
Create `../.env` with:
```bash
PROJECT_NAME=strapi
ENVIRONMENT=dev
AWS_REGION=us-west-2
DATABASE_RETENTION=DELETE  # or RETAIN for production
ADMIN_IPS=1.2.3.4/32,5.6.7.8/32  # WAF whitelist
```

### Using command line
```bash
./deploy-three-phase.sh --project-name myapp --environment prod --region eu-west-1
```

## 📝 Common Scenarios

### Deploy to Multiple Environments
```bash
# Development (interactive - review changes)
./deploy-three-phase.sh --environment dev

# Staging (automated - skip prompts)
./deploy-three-phase.sh --environment staging --force

# Production (interactive - always review changes!)
./deploy-three-phase.sh --environment production
```

### CI/CD Pipeline Deployment
```bash
# Automated deployment without prompts
./deploy-three-phase.sh --project-name myapp --environment dev --region us-west-2 --force
```

### First-Time vs Subsequent Deployments
```bash
# First time - review all changes carefully
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2

# Subsequent deployments - can use --force if confident
./deploy-three-phase.sh --project-name strapi --environment dev --region us-west-2 --force
```

### Update After Strapi Version Upgrade
See [STRAPI_UPGRADE_GUIDE.md](../STRAPI_UPGRADE_GUIDE.md) for detailed instructions.

## ⚠️ Important Notes

1. **Default environment is "dev"** - always specify `--environment production` for production deployments
2. **WAF is deployed in us-east-1** - required for CloudFront, regardless of main region
3. **First deployment takes ~20 minutes** - be patient!
4. **Database backups** - Always backup before upgrades or cleanup

## 🆘 Troubleshooting

### Prerequisites Check Failed
Run `./check-prerequisites.sh` to see what's missing.

### Stack Creation Failed
1. Check CloudFormation console for detailed error
2. Review CloudWatch logs
3. Ensure service quotas aren't exceeded

### ECS Service Won't Start
1. Check ECS task logs: `aws logs tail /ecs/stack-name --follow`
2. Verify Docker image exists in ECR
3. Check task definition CPU/memory settings

### Permission Denied
```bash
chmod +x *.sh
chmod +x lib/*.sh
```

## 🔒 Security

- Admin panel protected by WAF IP whitelist
- Database credentials in Secrets Manager
- All data encrypted at rest
- VPC with private subnets for RDS/ECS

## 📚 Additional Documentation

- [Infrastructure Overview](../README.md)
- [CloudFormation Templates](../cloudformation/README.md)
- [Strapi Version Upgrades](../STRAPI_VERSION_UPGRADE.md)