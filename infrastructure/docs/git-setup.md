# Git Setup for Private Strapi AWS Repository

This document explains the dual-remote Git setup for maintaining a private fork of the public Strapi repository with custom AWS deployment configurations.

## Repository Structure

- **Public Fork**: https://github.com/gopinaath/strapi (forked from strapi/strapi)
- **Private Repository**: https://github.com/gopinaath/strapi-aws (contains AWS-specific changes)

## Remote Configuration

```bash
# View current remotes
git remote -v

# Current setup:
origin          https://github.com/gopinaath/strapi (fetch)
origin          https://github.com/gopinaath/strapi (push)
private-origin  https://github.com/gopinaath/strapi-aws.git (fetch)
private-origin  https://github.com/gopinaath/strapi-aws.git (push)
```

## Branch Tracking

The `develop` branch is configured to track `private-origin/develop`:
```bash
git config --get branch.develop.remote
# Output: private-origin
```

## Common Operations

### Push Changes to Private Repository
```bash
# Default push (goes to private-origin)
git push

# Explicit push to private repository
git push private-origin develop
```

### Pull Updates from Public Strapi
```bash
# Pull updates from public fork
git pull origin develop

# If you need updates from original strapi/strapi
git remote add upstream https://github.com/strapi/strapi.git
git fetch upstream
git merge upstream/develop
```

### Push to Specific Remote
```bash
# Push to private repository
git push private-origin develop

# Push to public fork (if needed)
git push origin develop
```

## What's in the Private Repository

The private repository contains all Strapi code plus:

### Modified Files
- `examples/getstarted/config/database.js` - Environment-based database configuration
- `examples/getstarted/config/plugins.js` - Plugin configurations
- `examples/getstarted/package.json` - Updated dependencies
- `infrastructure/cloudformation/*.yaml` - AWS CloudFormation templates

### New Files
- Docker configurations (`Dockerfile`, `docker-entrypoint.sh`)
- AWS infrastructure code:
  - VPC, RDS, ECS, S3/CloudFront templates
  - WAF configurations
  - Deployment scripts
- Production configurations
- `examples/getstarted-minimal/` - Minimal example setup

## Switching Between Remotes

### Change branch tracking
```bash
# Track private repository
git branch --set-upstream-to=private-origin/develop develop

# Track public repository
git branch --set-upstream-to=origin/develop develop
```

### Check current tracking
```bash
git branch -vv
```

## Best Practices

1. **Always push sensitive changes to private-origin**
   - AWS credentials, infrastructure configs
   - Internal deployment scripts
   - Company-specific customizations

2. **Keep public fork clean**
   - Only push changes that could benefit the community
   - Remove sensitive information before pushing to origin

3. **Regular syncing**
   - Periodically pull updates from upstream Strapi
   - Merge carefully to avoid conflicts with customizations

## Troubleshooting

### Authentication Issues
If you encounter SSH key issues, the remote is configured to use HTTPS:
```bash
git remote set-url private-origin https://github.com/gopinaath/strapi-aws.git
```

### Checking Remote URLs
```bash
git remote get-url origin
git remote get-url private-origin
```

### Changing Default Push Behavior
```bash
# Always push to private by default
git config push.default current
git config branch.develop.pushRemote private-origin
```