#!/bin/bash

# Enhanced Strapi AWS Deployment Script with .env support

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
PROJECT_NAME="strapi"
ENVIRONMENT="dev"
AWS_REGION="us-east-1"
TEMPLATES_BUCKET=""
TEMPLATES_BUCKET_PREFIX="strapi-cloudformation-templates"  # Default prefix
STACK_NAME=""
PARAMS_FILE=""
DATABASE_RETENTION="RETAIN"
ADMIN_IPS=""  # No default - must be explicitly set
FORCE_DEPLOY=false  # Skip interactive prompts

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Load .env file if it exists
load_env_file() {
    # Get the script's directory
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    ENV_FILE="$SCRIPT_DIR/../../.env"
    
    if [ -f "$ENV_FILE" ]; then
        print_message $GREEN "Loading configuration from $ENV_FILE..."
        export $(cat "$ENV_FILE" | grep -v '^#' | xargs)
        
        # Update defaults from .env
        PROJECT_NAME="${PROJECT_NAME:-strapi}"
        ENVIRONMENT="${ENVIRONMENT:-production}"
        AWS_REGION="${AWS_REGION:-us-east-1}"
        DATABASE_RETENTION="${DATABASE_RETENTION:-RETAIN}"
        # Support both ADMIN_IPS and legacy ADMIN_IP
        if [ -z "$ADMIN_IPS" ] && [ -n "$ADMIN_IP" ]; then
            ADMIN_IPS="$ADMIN_IP"
        fi
        # Warn if admin IPs not set
        if [ -z "$ADMIN_IPS" ]; then
            print_message $YELLOW "WARNING: No admin IPs specified. Using 0.0.0.0/0 (open to world)."
            print_message $YELLOW "Set ADMIN_IPS in .env file for production deployments."
            ADMIN_IPS="0.0.0.0/0"
        fi
    else
        print_message $YELLOW "No .env file found at $ENV_FILE. Using defaults (database will be retained, WAF open to world)."
    fi
}

# Function to check prerequisites
check_prerequisites() {
    # Get the script's directory
    local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    
    # Use the comprehensive prerequisites check script
    PREREQ_ARGS=()
    if [ -n "$ENVIRONMENT" ]; then
        PREREQ_ARGS+=(--environment "$ENVIRONMENT")
    fi
    if [ -n "$AWS_REGION" ]; then
        PREREQ_ARGS+=(--region "$AWS_REGION")
    fi
    # Skip docker check for infrastructure-only deployment
    PREREQ_ARGS+=(--skip-docker)
    
    if ! "$script_dir/../check-prerequisites.sh" "${PREREQ_ARGS[@]}"; then
        print_message $RED "Prerequisites check failed. Please fix the issues above before proceeding."
        exit 1
    fi
}

# Function to check for existing resources that might cause conflicts
check_existing_resources() {
    local stack_name=$1
    local has_conflicts=false
    
    print_message $YELLOW "Checking for existing resources that might cause conflicts..."
    
    # Check for existing log groups
    local ecs_log_group="/ecs/${stack_name}"
    
    if aws logs describe-log-groups --log-group-name-prefix "$ecs_log_group" --region "$AWS_REGION" --query "logGroups[?logGroupName=='$ecs_log_group'].logGroupName" --output text 2>/dev/null | grep -q "$ecs_log_group"; then
        print_message $YELLOW "⚠ Found existing ECS log group: $ecs_log_group"
        has_conflicts=true
    fi
    
    # Check for existing S3 buckets
    local media_bucket="${stack_name}-media-${AWS_ACCOUNT_ID}"
    if aws s3api head-bucket --bucket "$media_bucket" --region "$AWS_REGION" 2>/dev/null; then
        print_message $YELLOW "⚠ Found existing S3 media bucket: $media_bucket"
        has_conflicts=true
    fi
    
    # Check for existing ECR repository
    local ecr_repo="${stack_name}"
    if aws ecr describe-repositories --repository-names "$ecr_repo" --region "$AWS_REGION" 2>/dev/null >/dev/null; then
        print_message $YELLOW "⚠ Found existing ECR repository: $ecr_repo"
        has_conflicts=true
    fi
    
    # Check for previously failed stack
    local stack_status=$(aws cloudformation list-stacks --region "$AWS_REGION" \
        --query "StackSummaries[?StackName=='$stack_name' && (StackStatus=='DELETE_FAILED' || StackStatus=='ROLLBACK_COMPLETE' || StackStatus=='ROLLBACK_FAILED')].StackStatus" \
        --output text 2>/dev/null)
    
    if [ -n "$stack_status" ]; then
        print_message $YELLOW "⚠ Found stack in failed state: $stack_status"
        print_message $YELLOW "  You may need to delete it manually: aws cloudformation delete-stack --stack-name $stack_name --region $AWS_REGION"
        has_conflicts=true
    fi
    
    if [ "$has_conflicts" = true ]; then
        print_message $YELLOW "\nConflicting resources found. You have three options:"
        print_message $YELLOW "1. Delete the existing resources manually"
        print_message $YELLOW "2. Use a different stack name"
        print_message $YELLOW "3. Continue anyway (may cause deployment to fail)"
        
        if [ "$FORCE_DEPLOY" = true ]; then
            print_message $YELLOW "Force deploy enabled, continuing anyway..."
        else
            read -p "Do you want to continue anyway? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_message $RED "Deployment cancelled."
                exit 1
            fi
        fi
    else
        print_message $GREEN "No conflicting resources found."
    fi
}

# Function to create/update parameters file with .env values
update_parameters() {
    local params_file=$1
    local temp_file="${params_file}.tmp"
    
    if [ -f "$params_file" ]; then
        print_message $YELLOW "Updating parameters with .env values..."
        
        # Update EnableDeletionProtection based on DATABASE_RETENTION
        local deletion_protection="true"
        if [ "$DATABASE_RETENTION" = "DELETE" ]; then
            deletion_protection="false"
            print_message $YELLOW "WARNING: Database deletion protection DISABLED!"
        fi
        
        # Update parameters using jq
        jq --arg dp "$deletion_protection" \
           --arg bucket "$TEMPLATES_BUCKET" \
           --arg admin_ips "$ADMIN_IPS" \
           '.[] |= if .ParameterKey == "EnableDeletionProtection" then .ParameterValue = $dp
                  elif .ParameterKey == "TemplatesBucketName" then .ParameterValue = $bucket
                  elif .ParameterKey == "AdminIPs" then .ParameterValue = $admin_ips
                  else . end' "$params_file" > "$temp_file"
        
        mv "$temp_file" "$params_file"
        
        print_message $YELLOW "Admin IPs configured: $ADMIN_IPS"
    fi
}

# Function to create S3 bucket for templates
create_templates_bucket() {
    local bucket_name=$1
    
    print_message $YELLOW "Creating S3 bucket for CloudFormation templates..."
    
    # Check if bucket exists
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        print_message $GREEN "Bucket $bucket_name already exists."
    else
        # Create bucket
        if [ "$AWS_REGION" == "us-east-1" ]; then
            aws s3api create-bucket --bucket "$bucket_name" --acl private
        else
            aws s3api create-bucket --bucket "$bucket_name" --acl private \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        
        # Enable versioning
        aws s3api put-bucket-versioning --bucket "$bucket_name" \
            --versioning-configuration Status=Enabled
        
        # Note: Not blocking public access initially to allow CloudFormation to access templates via HTTPS URLs
        # The templates are still secure as they require specific knowledge of the bucket/key names
        print_message $YELLOW "Setting up bucket permissions for CloudFormation..."
        
        print_message $GREEN "Bucket $bucket_name created successfully."
    fi
}

# Function to upload templates to S3
upload_templates() {
    local bucket_name=$1
    local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    local templates_dir="$script_dir/../../cloudformation"
    
    print_message $YELLOW "Uploading CloudFormation templates to S3..."
    
    # Upload all YAML files
    for template in "$templates_dir"/*.yaml; do
        if [ -f "$template" ]; then
            filename=$(basename "$template")
            aws s3 cp "$template" "s3://$bucket_name/cloudformation/$filename"
            print_message $GREEN "Uploaded $filename"
        fi
    done
}

# Function to validate templates
validate_templates() {
    local bucket_name=$1
    local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    local templates_dir="$script_dir/../../cloudformation"
    
    print_message $YELLOW "Validating CloudFormation templates..."
    
    for template in "$templates_dir"/*.yaml; do
        if [ -f "$template" ] && [ "$(basename "$template")" != "master-stack.yaml" ]; then
            filename=$(basename "$template")
            print_message $YELLOW "Validating $filename..."
            
            if aws cloudformation validate-template \
                --template-url "https://$bucket_name.s3.amazonaws.com/cloudformation/$filename" \
                &> /dev/null; then
                print_message $GREEN "✓ $filename is valid"
            else
                print_message $RED "✗ $filename validation failed"
                exit 1
            fi
        fi
    done
}

# Function to deploy the stack
deploy_stack() {
    local stack_name=$1
    local bucket_name=$2
    local parameters_file=$3
    
    print_message $YELLOW "Deploying CloudFormation stack: $stack_name"
    
    # Build parameters
    local parameters=""
    if [ -f "$parameters_file" ]; then
        parameters="--parameters file://$parameters_file"
    else
        parameters="--parameters ParameterKey=TemplatesBucketName,ParameterValue=$bucket_name"
    fi
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "$stack_name" &> /dev/null; then
        # Update existing stack
        print_message $YELLOW "Updating existing stack..."
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-url "https://$bucket_name.s3.amazonaws.com/cloudformation/master-stack.yaml" \
            --capabilities CAPABILITY_NAMED_IAM \
            $parameters
    else
        # Create new stack
        print_message $YELLOW "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-url "https://$bucket_name.s3.amazonaws.com/cloudformation/master-stack.yaml" \
            --capabilities CAPABILITY_NAMED_IAM \
            $parameters \
            --on-failure DELETE
    fi
    
    # Wait for stack to complete with progress updates
    print_message $YELLOW "Waiting for stack operation to complete..."
    print_message $YELLOW "This may take 10-15 minutes for a full deployment..."
    
    local wait_time=0
    local max_wait=1800  # 30 minutes
    local check_interval=30
    
    while [ $wait_time -lt $max_wait ]; do
        # Check if stack exists
        if ! aws cloudformation describe-stacks --stack-name "$stack_name" &> /dev/null; then
            print_message $RED "Stack $stack_name not found. It may have been rolled back due to an error."
            
            # Check for rolled back stack
            local deleted_stack=$(aws cloudformation list-stacks \
                --query "StackSummaries[?StackName=='$stack_name' && StackStatus=='DELETE_COMPLETE'].StackStatus" \
                --output text | head -1)
            
            if [ "$deleted_stack" = "DELETE_COMPLETE" ]; then
                print_message $RED "Stack was rolled back and deleted due to creation failure."
                print_message $YELLOW "Checking recent stack events for failure reason..."
                
                # Get the most recent stack ID
                local stack_id=$(aws cloudformation list-stacks \
                    --query "StackSummaries[?StackName=='$stack_name'].StackId | [0]" \
                    --output text)
                
                if [ -n "$stack_id" ] && [ "$stack_id" != "None" ]; then
                    aws cloudformation describe-stack-events \
                        --stack-name "$stack_id" \
                        --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='DELETE_FAILED'][0].[LogicalResourceId, ResourceStatusReason]" \
                        --output table
                fi
            fi
            return 1
        fi
        
        # Get current stack status
        local current_status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null)
        
        case "$current_status" in
            CREATE_COMPLETE|UPDATE_COMPLETE)
                print_message $GREEN "\n✓ Stack deployment completed successfully!"
                return 0
                ;;
            CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_COMPLETE|DELETE_FAILED)
                print_message $RED "\n✗ Stack deployment failed with status: $current_status"
                print_message $YELLOW "Checking stack events for failure reason..."
                
                aws cloudformation describe-stack-events \
                    --stack-name "$stack_name" \
                    --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='UPDATE_FAILED'][0].[LogicalResourceId, ResourceStatusReason]" \
                    --output table
                
                return 1
                ;;
            CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS)
                # Still in progress, show status
                if [ $((wait_time % 60)) -eq 0 ]; then
                    local resource_count=$(aws cloudformation describe-stack-resources \
                        --stack-name "$stack_name" \
                        --query 'length(StackResources[?ResourceStatus==`CREATE_COMPLETE`])' \
                        --output text 2>/dev/null || echo "0")
                    
                    print_message $YELLOW "Status: $current_status (Resources created: $resource_count) - Elapsed: $((wait_time/60)) minutes..."
                fi
                ;;
            ROLLBACK_IN_PROGRESS)
                print_message $RED "\n⚠ Stack creation failed and is rolling back..."
                ;;
        esac
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done
    
    print_message $RED "Timeout waiting for stack deployment after $((max_wait/60)) minutes"
    return 1
}

# Function to get stack outputs
get_stack_outputs() {
    local stack_name=$1
    
    print_message $YELLOW "\nStack Outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
        --output table
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -p, --project-name    Project name (default: strapi or from .env)"
    echo "  -e, --environment     Environment (default: production or from .env)"
    echo "  -r, --region          AWS region (default: us-east-1 or from .env)"
    echo "  -b, --bucket          S3 bucket for templates (optional, auto-generated if not provided)"
    echo "  -s, --stack-name      CloudFormation stack name (required)"
    echo "  -f, --params-file     Parameters file (optional)"
    echo "  --force               Skip interactive prompts"
    echo "  -h, --help            Display this help message"
    echo ""
    echo "Environment variables (via .env file):"
    echo "  PROJECT_NAME          Project name"
    echo "  ENVIRONMENT           Environment name"
    echo "  AWS_REGION            AWS region"
    echo "  DATABASE_RETENTION    RETAIN or DELETE (default: RETAIN)"
    echo "  ADMIN_IPS             Comma-separated admin IPs (default: 0.0.0.0/0)"
    exit 1
}

# Load .env file first
load_env_file

# Parse command line arguments (override .env values)
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -p|--project-name)
            PROJECT_NAME="$2"
            shift
            shift
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift
            shift
            ;;
        -b|--bucket)
            TEMPLATES_BUCKET="$2"
            shift
            shift
            ;;
        -s|--stack-name)
            STACK_NAME="$2"
            shift
            shift
            ;;
        -f|--params-file)
            PARAMS_FILE="$2"
            shift
            shift
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$STACK_NAME" ]; then
    print_message $RED "Error: --stack-name is required"
    usage
fi

# Main execution
print_message $GREEN "=== Enhanced Strapi AWS Deployment Script ==="
print_message $YELLOW "Project: $PROJECT_NAME"
print_message $YELLOW "Environment: $ENVIRONMENT"
print_message $YELLOW "Region: $AWS_REGION"
print_message $YELLOW "Stack Name: $STACK_NAME"
print_message $YELLOW "Database Retention: $DATABASE_RETENTION"
print_message $YELLOW "Admin IPs: $ADMIN_IPS\n"

# Set AWS region
export AWS_DEFAULT_REGION=$AWS_REGION

# Get AWS account ID for resource checks
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Construct templates bucket name if not explicitly provided
if [ -z "$TEMPLATES_BUCKET" ]; then
    TEMPLATES_BUCKET="${TEMPLATES_BUCKET_PREFIX}-${AWS_ACCOUNT_ID}"
    print_message $YELLOW "Using auto-generated bucket name: $TEMPLATES_BUCKET"
fi

# Update parameters file with .env values if provided
if [ -n "$PARAMS_FILE" ]; then
    update_parameters "$PARAMS_FILE"
fi

# Execute deployment steps
check_prerequisites
check_existing_resources "$STACK_NAME"
create_templates_bucket "$TEMPLATES_BUCKET"
upload_templates "$TEMPLATES_BUCKET"
validate_templates "$TEMPLATES_BUCKET"
if deploy_stack "$STACK_NAME" "$TEMPLATES_BUCKET" "$PARAMS_FILE"; then
    get_stack_outputs "$STACK_NAME"
    print_message $GREEN "\n=== Deployment completed successfully! ==="
else
    print_message $RED "\n=== Deployment failed! ==="
    print_message $YELLOW "\nTroubleshooting steps:"
    print_message $YELLOW "1. Check the error message above for the specific resource that failed"
    print_message $YELLOW "2. Review CloudFormation events in AWS Console for more details"
    print_message $YELLOW "3. Ensure your AWS account has sufficient service limits"
    print_message $YELLOW "4. Run with a different stack name if resources already exist"
    exit 1
fi
print_message $YELLOW "\nNext steps:"
print_message $YELLOW "1. Build and push your Strapi Docker image to ECR"
print_message $YELLOW "2. Update the ECS service with the new image"
print_message $YELLOW "3. Configure your domain name to point to the ALB"

if [ "$ADMIN_IPS" = "0.0.0.0/0" ]; then
    print_message $YELLOW "4. WARNING: Admin panel is accessible from ANY IP. Update WAF IP set for security!"
else
    print_message $YELLOW "4. Admin panel is restricted to: $ADMIN_IPS"
fi

print_message $YELLOW "5. Configure SSL certificate on the ALB"

# Check if we should build Docker image
if [ -f "$SCRIPT_DIR/../build-and-push.sh" ]; then
    echo ""
    if [ "$FORCE_DEPLOY" = true ]; then
        print_message $YELLOW "Force deploy enabled, skipping Docker build prompt..."
        REPLY="n"
    else
        read -p "Would you like to build and push the Docker image now? (y/n) " -n 1 -r
        echo ""
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ECR_URI=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
            --output text)
        
        if [ -n "$ECR_URI" ]; then
            print_message $GREEN "Building and pushing Docker image..."
            # Get the repository root and script directory
            CURRENT_DIR="$(pwd)"
            SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
            REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
            
            # Check if ECS service exists before trying to update it
            SERVICE_EXISTS=$(aws ecs describe-services \
                --cluster "${STACK_NAME}-cluster" \
                --services "${STACK_NAME}-service" \
                --region "$AWS_REGION" \
                --query 'services[?status==`ACTIVE`].status' \
                --output text 2>/dev/null || echo "")
            
            # Build command arguments
            BUILD_ARGS=(
                --repository "$ECR_URI"
                --tag latest
                --context "$REPO_ROOT"
                --dockerfile "$REPO_ROOT/Dockerfile.aws"
                --region "$AWS_REGION"
            )
            
            # Only add update-service if the service exists
            if [ "$SERVICE_EXISTS" = "ACTIVE" ]; then
                print_message $YELLOW "ECS service exists, will update after build..."
                BUILD_ARGS+=(--update-service "${STACK_NAME}-cluster:${STACK_NAME}-service")
            else
                print_message $YELLOW "ECS service does not exist yet, skipping service update..."
            fi
            
            # Call build-and-push.sh
            "$SCRIPT_DIR/../build-and-push.sh" "${BUILD_ARGS[@]}"
        else
            print_message $RED "Could not find ECR repository URI from stack outputs"
        fi
    fi
fi