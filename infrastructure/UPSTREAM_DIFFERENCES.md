# Differences from Upstream Strapi

This document outlines all the changes made to the official Strapi repository for AWS deployment.

## Summary
- **Total Changes**: 39 files changed, 5,930 insertions(+), 46 deletions(-)
- **Modified Files**: 1 (examples/getstarted/config/database.js)
- **Added Files**: 38 (all AWS infrastructure related)

## Key Differences

### 1. Infrastructure Directory (Added)
All AWS deployment infrastructure is contained in the `infrastructure/` directory:

#### CloudFormation Templates
- `01-vpc.yaml` - VPC with public/private/database subnets
- `02-rds.yaml` - Aurora PostgreSQL cluster 
- `03-ecs.yaml` - ECS Fargate service
- `04-s3-cloudfront.yaml` - S3 bucket and CloudFront CDN
- `05a-waf-regional.yaml` - Regional WAF for ALB
- `05b-waf-cloudfront.yaml` - CloudFront WAF
- `06-secrets.yaml` - Secrets Manager resources

#### Deployment Scripts
- `deploy-three-phase.sh` - Main deployment script
- `build-and-push.sh` - Docker build and ECR push
- `deploy-update-service.sh` - Update running ECS service
- `cleanup-strapi.sh` - Remove all AWS resources

#### Documentation
- `README.md` - Infrastructure overview
- `AWS_INTEGRATION.md` - Integration strategy
- `HTTPS-SETUP-GUIDE.md` - SSL/TLS setup guide
- `WAF-IP-WHITELIST-README.md` - WAF configuration

### 2. Docker Directory (Added)
- `docker/Dockerfile` - Moved from root
- `docker/README.md` - Docker documentation

### 3. Example Application Changes

#### Added Files
- `examples/getstarted/aws/` - AWS-specific configurations
  - `Dockerfile` - Production multi-stage build
  - `Dockerfile.simple` - Simple build
  - `config/plugins.production.js` - Production plugins
  - `docker-entrypoint.sh` - Container entrypoint
  
- Production configurations:
  - `config/database.production.js`
  - `config/env/production/database.js`
  - `config/plugins.production.js`
  - `Dockerfile.production`

#### Modified Files
- `examples/getstarted/config/database.js` - Updated to support environment variables in production mode

### 4. Clean Separation Strategy

All AWS-specific additions follow a clean separation pattern:
- AWS infrastructure is isolated in `infrastructure/`
- Docker configurations moved to `docker/`
- Example AWS configs in `examples/getstarted/aws/`
- Minimal changes to upstream files (only 1 file modified)

### 5. Environment Configuration

Added production environment support:
- Database configuration via environment variables
- AWS service integration (S3, CloudFront, RDS)
- Secrets management via AWS Secrets Manager
- Container deployment via ECS Fargate

### 6. No Core Strapi Changes

Important: No changes were made to:
- Core Strapi packages (`packages/`)
- Admin panel
- Plugin system
- API structure
- Build system

This ensures easy updates from upstream while maintaining AWS deployment capabilities.

## Maintenance Strategy

1. **Upstream Updates**: Can pull upstream changes without conflicts in most cases
2. **AWS Updates**: All AWS-specific code is isolated and maintainable separately
3. **Configuration**: Environment-based configuration allows flexibility

## File Organization

```
strapi/
├── docker/                        # Added: Docker configurations
├── examples/
│   └── getstarted/
│       ├── aws/                   # Added: AWS-specific configs
│       └── config/
│           ├── database.js        # Modified: Env var support
│           └── *.production.js    # Added: Production configs
├── infrastructure/                # Added: All AWS infrastructure
│   ├── cloudformation/           # CloudFormation templates
│   ├── docs/                     # Documentation
│   ├── parameters/               # Stack parameters
│   └── scripts/                  # Deployment scripts
└── [upstream files unchanged]
```