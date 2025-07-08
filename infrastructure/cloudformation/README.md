# Strapi AWS CloudFormation Templates

This directory contains the Infrastructure as Code (IaC) templates for deploying Strapi on AWS using CloudFormation.

## Architecture

The deployment creates a secure, scalable, and highly available Strapi infrastructure:

- **VPC**: Multi-AZ setup with public, private, and database subnets
- **RDS**: Aurora PostgreSQL cluster with Multi-AZ deployment
- **ECS**: Fargate containers for the Strapi application
- **ALB**: Application Load Balancer with health checks
- **S3 + CloudFront**: CDN for media storage and delivery
- **WAF**: Web Application Firewall for security (Regional + CloudFront)
- **Secrets Manager**: Secure credential storage

## Template Structure

Each template handles a specific component of the infrastructure. They're designed to work together through the master stack.

### Core Templates
- `01-vpc.yaml` - VPC infrastructure with Multi-AZ setup
- `02-rds.yaml` - Aurora PostgreSQL database cluster
- `03-ecs.yaml` - ECS Fargate service and task definitions
  - **Key Parameter**: `CreateService` - Set to 'false' for initial deployment without Docker image
- `04-s3-cloudfront.yaml` - S3 bucket and CloudFront CDN
- `05-waf-alb.yaml` - Regional WAF for ALB protection
- `05-waf-cloudfront.yaml` - CloudFront WAF (must be deployed to us-east-1)
- `06-secrets.yaml` - AWS Secrets Manager configuration
- `master-stack.yaml` - Master nested stack that orchestrates all components
  - **Key Parameter**: `CreateECSService` - Controls whether ECS service is created

### Template Parameters

Each template accepts specific parameters that control the deployment. Key parameters include:

- **CreateECSService** (in master-stack.yaml and 03-ecs.yaml): Set to 'false' for initial deployment without Docker image
- **Environment**: Deployment environment (dev/staging/production)
- **CloudFrontWebACLArn**: ARN of CloudFront WAF (required for CDN deployment)
- **AdminIPWhitelist**: IP addresses allowed to access admin panel

### Deployment Order

The templates are numbered to indicate their deployment order:
1. VPC infrastructure (01-vpc.yaml)
2. RDS database (02-rds.yaml)
3. ECS service (03-ecs.yaml)
4. S3 and CloudFront (04-s3-cloudfront.yaml)
5. WAF rules (05-waf-*.yaml)
6. Secrets management (06-secrets.yaml)

The master stack orchestrates these in the correct order with proper dependencies.

## Template Customization

### Modifying Resources

Each template can be customized by editing the parameters or resources sections:

- **Database Configuration** (02-rds.yaml):
  - Instance types: `DBInstanceClass`
  - Storage size: `AllocatedStorage`
  - Backup retention: `BackupRetentionPeriod`

- **Application Resources** (03-ecs.yaml):
  - CPU/Memory: `TaskCPU`, `TaskMemory`
  - Auto-scaling: `MinTasks`, `MaxTasks`
  - Health check settings

- **CDN Settings** (04-s3-cloudfront.yaml):
  - Cache behaviors
  - Origin configurations
  - Custom error pages

### Adding New Resources

To add new resources:
1. Create a new template following the existing pattern
2. Add it to the master stack's nested stacks
3. Update parameters files as needed

## Stack Outputs

The master stack exports key values for use by other resources:

- **ALBEndpoint**: Load balancer URL for accessing Strapi
- **CloudFrontDomain**: CDN domain for media files
- **ECRRepositoryUri**: Docker repository for pushing images
- **DatabaseEndpoint**: RDS cluster endpoint
- **MediaBucketName**: S3 bucket for media storage

## Related Documentation

- **[Infrastructure Overview](../README.md)**: Complete deployment guide
- **[Deployment Scripts](../scripts/README.md)**: Script usage and examples
- **[WAF IP Whitelist Guide](WAF-IP-WHITELIST-README.md)**: Managing admin access
- **[Strapi Upgrade Guide](../STRAPI_UPGRADE_GUIDE.md)**: Version upgrade procedures

## Template Validation

Before deployment, validate templates locally:

```bash
# Validate individual template
aws cloudformation validate-template \
  --template-body file://01-vpc.yaml

# Validate master stack
aws cloudformation validate-template \
  --template-body file://master-stack.yaml
```