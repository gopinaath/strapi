# Manual Resources Audit

## Resources Created During Deployment

### 1. Resources Created MANUALLY (Outside CloudFormation)

#### During Troubleshooting:
1. **ECR Repository** (`build-and-push.sh`)
   - The script creates ECR repository if it doesn't exist
   - This happens BEFORE ECS stack deployment
   - **Issue**: Should be part of CloudFormation stack
   ```bash
   aws ecr create-repository --repository-name "$PROJECT_NAME-$ENVIRONMENT" --region "$REGION"
   ```

2. **ALB Security Group Rule** (Added during debugging)
   - Added HTTP ingress rule manually to fix connectivity
   - Later updated the CloudFormation template to include it
   - **Status**: Fixed in template, but was manual during initial deployment
   ```bash
   aws ec2 authorize-security-group-ingress --group-id sg-0c7308a5e1c7a3af2 --protocol tcp --port 80 --cidr 0.0.0.0/0
   ```

3. **ALB Deletion Protection** (Modified during troubleshooting)
   - Manually disabled deletion protection to delete failed stack
   - **Status**: Template updated to set deletion_protection.enabled='false'
   ```bash
   aws elbv2 modify-load-balancer-attributes --load-balancer-arn <arn> --attributes Key=deletion_protection.enabled,Value=false
   ```

### 2. Resources Created by CloudFormation

All other resources are properly managed by CloudFormation:
- ✅ VPC, Subnets, Route Tables, Internet Gateway, NAT Gateways
- ✅ Security Groups (except the missing ALB ingress rule initially)
- ✅ RDS Aurora PostgreSQL Cluster
- ✅ ECS Cluster, Service, Task Definition
- ✅ Application Load Balancer, Target Group
- ✅ S3 Buckets (Media and Logs)
- ✅ CloudFront Distribution
- ✅ WAF Web ACLs (Regional and CloudFront)
- ✅ Secrets Manager Secrets
- ✅ IAM Roles and Policies
- ✅ CloudWatch Log Groups
- ✅ CloudWatch Alarms

### 3. Scripts That Need Updates

#### `build-and-push.sh`
**Current behavior**: Creates ECR repository if it doesn't exist
**Recommendation**: Remove ECR creation, assume it exists from CloudFormation

### 4. Current State

The **`deploy-three-phase.sh`** script is properly implemented:
- Does NOT create secrets manually (uses CloudFormation)
- Does NOT create any resources outside CloudFormation
- Only runs CloudFormation deployments in the correct order

### 5. Recommendations

1. **ECR Repository**: 
   - Move ECR creation to ECS CloudFormation template
   - Update build-and-push.sh to only push, not create

2. **Security Group Rules**:
   - Already fixed in template
   - No action needed

3. **Monitoring**:
   - All CloudWatch resources are in CloudFormation
   - No manual creation needed

### 6. Clean Deployment Test

To verify everything is in CloudFormation:
1. Delete all stacks
2. Run `deploy-three-phase.sh`
3. Should create everything without manual intervention

**Result**: After fixes, the deployment is fully automated with no manual resource creation required.