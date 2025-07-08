# AWS Integration Guide for Strapi

This document explains how the AWS infrastructure is integrated with the Strapi codebase while maintaining clean separation from upstream components.

## Directory Structure

```
strapi/
├── docker/                         # Docker configurations
│   └── Dockerfile                  # Production Dockerfile
├── infrastructure/                 # AWS infrastructure (no conflicts with upstream)
│   ├── cloudformation/            # CloudFormation templates
│   ├── docs/                      # Infrastructure documentation
│   ├── parameters/                # Environment parameters
│   └── scripts/                   # Deployment scripts
└── examples/
    └── getstarted/
        ├── aws/                   # AWS-specific example configurations
        │   ├── Dockerfile         # Example Dockerfile with AWS optimizations
        │   ├── Dockerfile.simple  # Simplified version
        │   ├── docker-entrypoint.sh
        │   └── config/
        │       └── plugins.production.js
        └── [upstream files remain untouched]
```

## Key Principles

1. **No Upstream Modifications**: All AWS-specific code is contained in dedicated directories
2. **Environment-Based Configuration**: Use environment variables for AWS-specific settings
3. **Clear Separation**: AWS infrastructure code is clearly separated from Strapi application code

## Environment Variables

The AWS deployment uses these environment variables:

```bash
# Database
DATABASE_CLIENT=postgres
DATABASE_HOST=${RDS_ENDPOINT}
DATABASE_PORT=5432
DATABASE_NAME=${DATABASE_NAME}
DATABASE_USERNAME=${DATABASE_USERNAME}
DATABASE_PASSWORD=${DATABASE_PASSWORD}

# S3 Upload Provider
AWS_BUCKET_NAME=${S3_BUCKET_NAME}
AWS_REGION=${AWS_REGION}

# Application
NODE_ENV=production
STRAPI_URL=${STRAPI_URL}
```

## Building for AWS

### Using Root Dockerfile
```bash
docker build -f docker/Dockerfile -t strapi-aws .
```

### Using Example AWS Dockerfile
```bash
cd examples/getstarted
docker build -f aws/Dockerfile -t strapi-aws-example .
```

## Deployment Process

1. **Infrastructure Setup**
   ```bash
   cd infrastructure/scripts
   ./deploy-three-phase.sh --project-name strapi --environment production --region us-west-2
   ```

2. **Build and Push Docker Image**
   ```bash
   cd infrastructure/scripts
   ./build-and-push.sh --repository $ECR_URI --tag latest
   ```

3. **Configure Environment**
   - Set all required environment variables in ECS task definition
   - Configure Secrets Manager references

## Updating from Upstream

This structure allows seamless updates from upstream:

```bash
# Fetch latest from upstream
git fetch upstream

# Merge upstream changes (no conflicts with AWS files)
git merge upstream/develop

# Your AWS infrastructure remains intact
```

## Best Practices

1. **Keep AWS code isolated**: Never modify upstream Strapi files
2. **Use environment variables**: Configure AWS services through environment
3. **Document changes**: Update this guide when adding new AWS integrations
4. **Test locally**: Use docker-compose with LocalStack for local AWS testing

## Related Documentation

- `/infrastructure/cloudformation/README.md` - Detailed CloudFormation deployment guide
- `/infrastructure/cloudformation/HTTPS-SETUP-GUIDE.md` - HTTPS configuration
- `/infrastructure/cloudformation/WAF-IP-WHITELIST-README.md` - WAF setup
- `/infrastructure/docs/git-setup.md` - Git workflow documentation