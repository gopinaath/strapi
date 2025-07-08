# Strapi AWS Deployment Cleanup Task List

This comprehensive task list ensures complete removal of all Strapi deployment resources from AWS regions us-east-1 and us-west-2.

## Pre-Cleanup Preparation

### 1. Gather Information
- [ ] Record all stack names in both regions
- [ ] Document any custom resource names
- [ ] Take screenshots of current AWS Console for reference
- [ ] Export current billing information

### 2. Disable Protections
```bash
# Check for deletion protection on RDS
aws rds describe-db-clusters --region us-west-2 --query 'DBClusters[?contains(DBClusterIdentifier, `strapi`)].{Name:DBClusterIdentifier,Protection:DeletionProtection}'
aws rds describe-db-clusters --region us-east-1 --query 'DBClusters[?contains(DBClusterIdentifier, `strapi`)].{Name:DBClusterIdentifier,Protection:DeletionProtection}'

# Check for ALB deletion protection
aws elbv2 describe-load-balancers --region us-west-2 --query 'LoadBalancers[?contains(LoadBalancerName, `strapi`)].{Name:LoadBalancerName,Arn:LoadBalancerArn}'
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[?contains(LoadBalancerName, `strapi`)].{Name:LoadBalancerName,Arn:LoadBalancerArn}'
```

### 3. Backup Critical Data
- [ ] Create final RDS snapshots if needed
- [ ] Download any critical S3 data
- [ ] Export CloudWatch logs if needed

## US-EAST-1 Cleanup (CloudFront WAF Region)

### 1. CloudFormation Stacks
```bash
# List all stacks
aws cloudformation list-stacks --region us-east-1 --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[?contains(StackName, `strapi`)].{Name:StackName,Status:StackStatus}'

# Delete WAF CloudFront stack (if exists)
aws cloudformation delete-stack --stack-name strapi-production-waf-cloudfront --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name strapi-production-waf-cloudfront --region us-east-1
```

### 2. WAF Resources (Manual Check)
```bash
# List WAF ACLs
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1

# Delete specific WAF ACL if found
# aws wafv2 delete-web-acl --scope CLOUDFRONT --region us-east-1 --name <acl-name> --id <acl-id> --lock-token <token>
```

### 3. CloudWatch Logs
```bash
# List and delete log groups
aws logs describe-log-groups --region us-east-1 --log-group-name-prefix "/aws/waf/strapi"
# For each log group:
# aws logs delete-log-group --log-group-name <log-group-name> --region us-east-1
```

## US-WEST-2 Cleanup (Primary Deployment Region)

### 1. Stop Running Services
```bash
# Stop ECS services first
aws ecs list-services --cluster strapi-production-cluster --region us-west-2
aws ecs update-service --cluster strapi-production-cluster --service strapi-production-service --desired-count 0 --region us-west-2

# Wait for tasks to stop
aws ecs wait services-stable --cluster strapi-production-cluster --services strapi-production-service --region us-west-2

# Delete the service
aws ecs delete-service --cluster strapi-production-cluster --service strapi-production-service --force --region us-west-2
```

### 2. Empty S3 Buckets
```bash
# List all S3 buckets
aws s3 ls | grep strapi

# For each bucket (media, logs, templates):
# Empty media bucket
aws s3 rm s3://strapi-production-media-<account-id> --recursive --region us-west-2

# Empty logs bucket
aws s3 rm s3://strapi-production-logs-<account-id> --recursive --region us-west-2

# Empty VPC flow logs bucket if exists
aws s3 rm s3://strapi-production-vpc-flow-logs-<account-id> --recursive --region us-west-2

# Empty templates bucket
aws s3 rm s3://strapi-production-cloudformation-templates-<region> --recursive --region us-west-2
```

### 3. Delete CloudFormation Stacks (Reverse Order)
```bash
# List all stacks
aws cloudformation list-stacks --region us-west-2 --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE --query 'StackSummaries[?contains(StackName, `strapi`)].{Name:StackName,Status:StackStatus}'

# Delete in reverse dependency order:

# 1. WAF Stack
aws cloudformation delete-stack --stack-name strapi-production-waf-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-waf-stack --region us-west-2

# 2. ECS Stack
aws cloudformation delete-stack --stack-name strapi-production-ecs-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-ecs-stack --region us-west-2

# 3. S3 CloudFront Stack
aws cloudformation delete-stack --stack-name strapi-production-s3-cloudfront-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-s3-cloudfront-stack --region us-west-2

# 4. RDS Stack
aws cloudformation delete-stack --stack-name strapi-production-rds-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-rds-stack --region us-west-2

# 5. Secrets Stack
aws cloudformation delete-stack --stack-name strapi-production-secrets-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-secrets-stack --region us-west-2

# 6. VPC Stack
aws cloudformation delete-stack --stack-name strapi-production-vpc-stack --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production-vpc-stack --region us-west-2

# 7. Master Stack (if still exists)
aws cloudformation delete-stack --stack-name strapi-production --region us-west-2
aws cloudformation wait stack-delete-complete --stack-name strapi-production --region us-west-2
```

### 4. Manual Resource Cleanup

#### ECR Repository (Created by build-and-push.sh)
```bash
# List ECR repositories
aws ecr describe-repositories --region us-west-2 --query 'repositories[?contains(repositoryName, `strapi`)].repositoryName'

# Delete images first
aws ecr list-images --repository-name strapi-production --region us-west-2
aws ecr batch-delete-image --repository-name strapi-production --image-ids imageTag=latest --region us-west-2

# Delete repository
aws ecr delete-repository --repository-name strapi-production --force --region us-west-2
```

#### RDS Snapshots
```bash
# List snapshots
aws rds describe-db-cluster-snapshots --region us-west-2 --query 'DBClusterSnapshots[?contains(DBClusterSnapshotIdentifier, `strapi`)].DBClusterSnapshotIdentifier'

# Delete each snapshot
# aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier <snapshot-id> --region us-west-2
```

#### CloudWatch Resources
```bash
# Delete log groups
aws logs describe-log-groups --region us-west-2 --log-group-name-prefix "/ecs/strapi"
aws logs describe-log-groups --region us-west-2 --log-group-name-prefix "/aws/ecs/strapi"
aws logs describe-log-groups --region us-west-2 --log-group-name-prefix "/aws/rds/cluster/strapi"

# For each log group:
# aws logs delete-log-group --log-group-name <log-group-name> --region us-west-2

# Delete alarms
aws cloudwatch describe-alarms --region us-west-2 --alarm-name-prefix "strapi"
# For each alarm:
# aws cloudwatch delete-alarms --alarm-names <alarm-name> --region us-west-2
```

### 5. IAM Cleanup (Global)
```bash
# List IAM roles
aws iam list-roles --query 'Roles[?contains(RoleName, `strapi`)].RoleName'

# Note: IAM roles created by CloudFormation should be deleted automatically
# Only delete if orphaned roles exist
```

## Post-Cleanup Verification

### 1. Resource Explorer Check
```bash
# Use AWS Resource Explorer to find any remaining resources
aws resource-explorer-2 search --query "resourceType:* AND tags.Project:strapi" --region us-west-2
aws resource-explorer-2 search --query "resourceType:* AND tags.Project:strapi" --region us-east-1
```

### 2. Manual Console Verification
Check each service console for any remaining resources:
- [ ] EC2 (Security Groups, Network Interfaces)
- [ ] VPC (Subnets, Route Tables, Internet Gateways, NAT Gateways)
- [ ] RDS (Clusters, Instances, Snapshots, Parameter Groups, Subnet Groups)
- [ ] ECS (Clusters, Services, Task Definitions)
- [ ] ECR (Repositories)
- [ ] S3 (Buckets)
- [ ] CloudFront (Distributions)
- [ ] WAF (Web ACLs, IP Sets, Rule Groups)
- [ ] Secrets Manager (Secrets)
- [ ] Systems Manager (Parameter Store)
- [ ] CloudWatch (Log Groups, Alarms, Dashboards)
- [ ] Route 53 (Hosted Zones, Records)
- [ ] Certificate Manager (Certificates)
- [ ] Elastic Load Balancing (Load Balancers, Target Groups)

### 3. Cost Verification
```bash
# Check for any ongoing charges
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1
```

### 4. Tag-Based Search
```bash
# Search for resources by tags
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=strapi --region us-west-2
aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=production --region us-west-2
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=strapi --region us-east-1
aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=production --region us-east-1
```

## Troubleshooting Common Issues

### Stack Deletion Failures
1. **S3 Bucket Not Empty**: Empty the bucket first using the commands above
2. **ECS Service Still Running**: Stop and delete the service first
3. **RDS Deletion Protection**: Disable deletion protection
4. **ALB Deletion Protection**: Disable deletion protection
5. **Dependency Violations**: Delete stacks in reverse order

### Manual Cleanup Commands
```bash
# Force delete an ECS cluster
aws ecs delete-cluster --cluster strapi-production-cluster --region us-west-2

# Force delete a load balancer
aws elbv2 delete-load-balancer --load-balancer-arn <arn> --region us-west-2

# Force delete security groups (after dependencies are removed)
aws ec2 delete-security-group --group-id <sg-id> --region us-west-2
```

## Final Checklist
- [ ] All CloudFormation stacks deleted in both regions
- [ ] All S3 buckets emptied and deleted
- [ ] All ECR repositories deleted
- [ ] All RDS instances and snapshots deleted
- [ ] All ECS resources deleted
- [ ] All CloudFront distributions deleted
- [ ] All WAF resources deleted
- [ ] All CloudWatch resources deleted
- [ ] All IAM roles cleaned up
- [ ] Resource Explorer shows no Strapi resources
- [ ] Cost Explorer shows no ongoing charges
- [ ] Tag-based search returns no results

## Notes
- Always run cleanup in a test environment first
- Keep this checklist updated as you complete each task
- Document any issues or manual steps required
- Save all command outputs for audit purposes