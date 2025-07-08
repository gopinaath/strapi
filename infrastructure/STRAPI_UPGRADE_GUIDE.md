# Strapi Upgrade Guide for AWS Infrastructure

This comprehensive guide explains how to safely upgrade Strapi versions in your AWS deployment, including pre-upgrade planning, execution steps, and rollback procedures.

## Overview of Upgrade Types

### 1. **Patch Updates** (e.g., 4.15.1 → 4.15.2)
- **Risk**: Low
- **Downtime**: Minimal (rolling update)
- **Infrastructure Changes**: None
- **Database Backup**: Recommended

### 2. **Minor Updates** (e.g., 4.15.x → 4.16.x)
- **Risk**: Medium
- **Downtime**: Minimal to moderate
- **Infrastructure Changes**: Usually none
- **Database Backup**: Required

### 3. **Major Updates** (e.g., 4.x.x → 5.x.x)
- **Risk**: High
- **Downtime**: Planned maintenance window
- **Infrastructure Changes**: May require database migrations
- **Database Backup**: Critical

## Pre-Upgrade Checklist

Before upgrading Strapi:

1. **Review the Strapi changelog** for breaking changes
   - Check [Strapi Releases](https://github.com/strapi/strapi/releases)
   - Read migration guides for major versions

2. **Test the upgrade locally** first
   - Clone your production database to local
   - Test the upgrade process
   - Verify all features work correctly

3. **Create a database backup** (required for production)
   - Use RDS snapshots for easy rollback
   - Tag snapshots with version information

4. **Plan for rollback** if needed
   - Keep previous Docker images in ECR
   - Document rollback procedure
   - Test rollback process in staging

5. **Review infrastructure compatibility**
   - Check Node.js version requirements
   - Verify dependency compatibility
   - Review memory/CPU requirements

## Step-by-Step Upgrade Process

### Step 1: Create Database Backup

**For production environments, always create a backup first:**

```bash
# Get the database cluster ID
STACK_NAME="strapi-production"
DB_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region us-west-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`DatabaseEndpoint`].OutputValue' \
    --output text)

DB_CLUSTER_ID=$(echo "$DB_ENDPOINT" | cut -d'.' -f1)

# Create snapshot with version info
OLD_VERSION="4.15.0"  # Current version
NEW_VERSION="4.16.0"  # Target version
SNAPSHOT_ID="${STACK_NAME}-upgrade-${OLD_VERSION}-to-${NEW_VERSION}-$(date +%Y%m%d-%H%M%S)"

aws rds create-db-cluster-snapshot \
    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
    --db-cluster-identifier "$DB_CLUSTER_ID" \
    --region us-west-2 \
    --tags Key=Purpose,Value=VersionUpgrade Key=FromVersion,Value="$OLD_VERSION" Key=ToVersion,Value="$NEW_VERSION"

# Wait for snapshot to complete
aws rds wait db-cluster-snapshot-completed \
    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" \
    --region us-west-2

echo "Snapshot created: $SNAPSHOT_ID"
```

### Step 2: Update Application Code

1. **Update package.json dependencies:**
```json
{
  "dependencies": {
    "@strapi/strapi": "4.16.0",
    "@strapi/plugin-users-permissions": "4.16.0",
    "@strapi/plugin-i18n": "4.16.0",
    "@strapi/plugin-graphql": "4.16.0",
    "@strapi/provider-upload-aws-s3": "4.16.0"
    // Update all Strapi packages to the same version
  }
}
```

2. **Update yarn.lock or package-lock.json:**
```bash
# For yarn
yarn install

# For npm
npm install
```

3. **Test locally:**
```bash
# Start with production-like environment
NODE_ENV=production yarn build
NODE_ENV=production yarn start
```

### Step 3: Build and Tag New Docker Image

```bash
# Build with specific version tag
cd /path/to/strapi/app
NEW_VERSION="4.16.0"
BUILD_TAG="v${NEW_VERSION}-$(date +%Y%m%d-%H%M%S)"

# Build the image
docker build -t strapi:$BUILD_TAG -f Dockerfile.aws .

# Get ECR URI
ECR_URI=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region us-west-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
    --output text)

# Tag for ECR
docker tag strapi:$BUILD_TAG $ECR_URI:$BUILD_TAG
docker tag strapi:$BUILD_TAG $ECR_URI:$NEW_VERSION

# Push to ECR
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin $ECR_URI
docker push $ECR_URI:$BUILD_TAG
docker push $ECR_URI:$NEW_VERSION
```

### Step 4: Deploy Updated Service

For zero-downtime deployment, use the update service script:

```bash
cd infrastructure/scripts

# Update service with new image
./deploy-update-service.sh \
    --stack-name strapi-production \
    --tag $NEW_VERSION \
    --region us-west-2
```

This performs a rolling update:
1. New tasks start with the new version
2. Health checks verify they're working
3. Old tasks are drained and stopped
4. No downtime if health checks pass

### Step 5: Verify Deployment

1. **Check ECS service status:**
```bash
aws ecs describe-services \
    --cluster strapi-production-cluster \
    --services strapi-production-service \
    --region us-west-2 \
    --query 'services[0].deployments'
```

2. **Monitor logs:**
```bash
aws logs tail /ecs/strapi-production --follow --region us-west-2
```

3. **Test application:**
- Access admin panel
- Test API endpoints
- Verify media uploads
- Check integrations

## What Changes During Upgrades

### 1. **Application Code & Docker Image** ✅ Always Changes
- New Strapi version in package.json
- Updated dependencies
- New Docker image in ECR

### 2. **Database Schema** ⚠️ Sometimes Changes
- Strapi handles migrations automatically
- May add new tables or columns
- Backward compatibility usually maintained

### 3. **Environment Variables** ⚠️ Sometimes Changes
- New features may require new variables
- Deprecated variables should be removed
- Check Strapi migration guide

### 4. **Infrastructure** ❌ Rarely Changes
- ECS task definition usually unchanged
- Security groups remain the same
- Load balancer configuration unchanged

## What Stays the Same

### 1. **AWS Infrastructure** ✅
- VPC, subnets, security groups
- RDS cluster configuration
- ECS cluster and service settings
- Load balancer and target groups
- S3 buckets and CloudFront

### 2. **Configuration Files** ✅
- database.js configuration
- server.js settings
- Plugin configurations (usually)

### 3. **Data** ✅
- Database content
- Media files in S3
- User accounts and permissions

## Rollback Procedure

If issues occur after upgrade:

### Quick Rollback (Recommended)
```bash
# Update service to previous version
OLD_VERSION="4.15.0"  # Previous stable version

./deploy-update-service.sh \
    --stack-name strapi-production \
    --tag $OLD_VERSION \
    --region us-west-2
```

### Database Rollback (If Needed)
Only necessary if database migrations cause issues:

```bash
# Stop the ECS service first
aws ecs update-service \
    --cluster strapi-production-cluster \
    --service strapi-production-service \
    --desired-count 0 \
    --region us-west-2

# Restore from snapshot
aws rds restore-db-cluster-from-snapshot \
    --db-cluster-identifier strapi-production-cluster-restored \
    --snapshot-identifier $SNAPSHOT_ID \
    --region us-west-2

# Update ECS task to use restored database
# Then restart service with old version
```

## Version-Specific Considerations

### Strapi 4.x → 4.x (Minor Updates)
- Usually straightforward
- Plugin compatibility important
- Check for deprecated features

### Strapi 4.x → 5.x (Major Update)
- Significant changes expected
- Extended testing required
- May need infrastructure updates
- Plan for longer maintenance window

## Best Practices

1. **Always test in staging first**
   - Use identical infrastructure
   - Test with production-like data
   - Verify all integrations

2. **Use semantic versioning for images**
   - Tag with exact version: `4.16.0`
   - Add build timestamp: `4.16.0-20240315-143022`
   - Keep `latest` for current production

3. **Monitor after deployment**
   - Watch CloudWatch metrics
   - Check error rates
   - Monitor response times
   - Verify background jobs

4. **Document each upgrade**
   - Version upgraded from/to
   - Any issues encountered
   - Configuration changes made
   - Performance impact

## Automation

For frequent updates, consider automating the process:

```bash
# Example automation script structure
#!/bin/bash
set -e

# 1. Create database backup
./scripts/backup-database.sh

# 2. Build and push new image
./scripts/build-and-push.sh --tag $NEW_VERSION

# 3. Update ECS service
./scripts/deploy-update-service.sh --tag $NEW_VERSION

# 4. Run health checks
./scripts/verify-deployment.sh

# 5. Notify team
./scripts/send-notification.sh "Upgrade to $NEW_VERSION complete"
```

## Troubleshooting Common Issues

### 1. **Migration Failures**
- Check Strapi logs for errors
- Verify database permissions
- Ensure migrations table exists

### 2. **Plugin Incompatibility**
- Update all plugins together
- Check plugin documentation
- Test in development first

### 3. **Performance Degradation**
- Review new version requirements
- Adjust task CPU/memory if needed
- Check for new background processes

### 4. **Configuration Issues**
- Compare old vs new config files
- Check for renamed variables
- Verify plugin configurations

## Summary

Upgrading Strapi in AWS involves:
1. **Planning** - Review changes, test locally
2. **Backup** - Create RDS snapshots
3. **Build** - Create new Docker images
4. **Deploy** - Rolling update via ECS
5. **Verify** - Test all functionality
6. **Monitor** - Watch for issues

The AWS infrastructure remains stable during upgrades, with only the application container changing. This provides a safe, repeatable upgrade process with easy rollback options.