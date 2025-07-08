#!/bin/bash
set -e

# Three-Phase Deployment Script for Strapi AWS Infrastructure
# Phase 1: Deploy WAF in us-east-1
# Phase 2: Deploy infrastructure without ECS service
# Phase 3: Build Docker image and deploy ECS service

# Cleanup function for temporary files
cleanup() {
    if [ -n "$TEMP_PARAMS_FILE" ] && [ -f "$TEMP_PARAMS_FILE" ]; then
        rm -f "$TEMP_PARAMS_FILE"
    fi
    # Clean up any jq temporary files
    rm -f "${PARAMS_FILE}.tmp" "${TEMP_PARAMS_FILE}.new" 2>/dev/null || true
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_PROJECT_NAME="strapi"
DEFAULT_ENVIRONMENT="dev"
DEFAULT_REGION="us-west-2"
WAF_REGION="us-east-1"
SKIP_PHASE1=false
SKIP_PHASE2=false
SKIP_PHASE3=false
DRY_RUN=false
FORCE_DEPLOY=false

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --project-name NAME       Project name (default: strapi)"
    echo "  --environment ENV         Environment (default: dev)"
    echo "  --region REGION          AWS region for main deployment (default: us-west-2)"
    echo "  --profile PROFILE        AWS profile to use"
    echo "  --skip-phase1            Skip Phase 1 (WAF deployment)"
    echo "  --skip-phase2            Skip Phase 2 (infrastructure deployment)"
    echo "  --skip-phase3            Skip Phase 3 (Docker build and service deployment)"
    echo "  --dry-run                Show what would be done without executing"
    echo "  --force                  Skip all interactive prompts (force yes)"
    echo "  --help                   Display this help message"
    echo ""
    echo "Three-phase deployment:"
    echo "  Phase 1: Deploy CloudFront WAF in us-east-1"
    echo "  Phase 2: Deploy infrastructure without ECS service"
    echo "  Phase 3: Build Docker image and deploy ECS service"
    echo ""
    echo "Example:"
    echo "  # Full deployment"
    echo "  $0 --project-name myapp --environment production"
    echo ""
    echo "  # Skip WAF if already deployed"
    echo "  $0 --skip-phase1"
    echo ""
    echo "  # Only update ECS service with new image"
    echo "  $0 --skip-phase1 --skip-phase2"
}

# Parse command line arguments
PROJECT_NAME=$DEFAULT_PROJECT_NAME
ENVIRONMENT=$DEFAULT_ENVIRONMENT
REGION=$DEFAULT_REGION
AWS_PROFILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --project-name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            export AWS_PROFILE
            shift 2
            ;;
        --skip-phase1)
            SKIP_PHASE1=true
            shift
            ;;
        --skip-phase2)
            SKIP_PHASE2=true
            shift
            ;;
        --skip-phase3)
            SKIP_PHASE3=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check prerequisites
print_message $YELLOW "Checking prerequisites..."
PREREQ_ARGS=()
if [ -n "$ENVIRONMENT" ]; then
    PREREQ_ARGS+=(--environment "$ENVIRONMENT")
fi
if [ -n "$REGION" ]; then
    PREREQ_ARGS+=(--region "$REGION")
fi
if [ "$SKIP_PHASE3" = true ]; then
    PREREQ_ARGS+=(--skip-phase3)
fi

if ! "$SCRIPT_DIR/check-prerequisites.sh" "${PREREQ_ARGS[@]}"; then
    print_message $RED "Prerequisites check failed. Please fix the issues above before proceeding."
    exit 1
fi
echo ""

# Export flag to skip redundant checks in child scripts
export STRAPI_PREREQ_CHECKED=true

print_message $GREEN "=== Strapi Three-Phase Deployment ==="
print_message $YELLOW "Project: $PROJECT_NAME"
print_message $YELLOW "Environment: $ENVIRONMENT"
print_message $YELLOW "Region: $REGION"
print_message $YELLOW "Dry Run: $DRY_RUN"
if [ "$FORCE_DEPLOY" = true ]; then
    print_message $YELLOW "Force Deploy: Enabled (will skip prompts)"
fi
echo ""

# Set AWS CLI options
AWS_CLI_OPTS=""
if [ -n "$AWS_PROFILE" ]; then
    AWS_CLI_OPTS="--profile $AWS_PROFILE"
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity $AWS_CLI_OPTS --query Account --output text)
print_message $YELLOW "AWS Account: $AWS_ACCOUNT_ID"
echo ""

# Stack names
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
WAF_STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}-waf-cloudfront"
PARAMS_FILE="$SCRIPT_DIR/../parameters/${REGION}-${ENVIRONMENT}.json"

# Check if parameter template exists and process it
PARAMS_TEMPLATE="${PARAMS_FILE}.template"
if [ -f "$PARAMS_TEMPLATE" ]; then
    print_message $YELLOW "Found parameter template, processing..."
    if ! "$SCRIPT_DIR/lib/process-parameters.sh" "$PARAMS_TEMPLATE" "$PARAMS_FILE"; then
        print_message $RED "Failed to process parameter template"
        exit 1
    fi
    echo ""
elif [ ! -f "$PARAMS_FILE" ]; then
    print_message $RED "Error: Neither parameter file nor template found:"
    print_message $RED "  Expected: $PARAMS_FILE or $PARAMS_TEMPLATE"
    exit 1
fi

# Phase 1: Deploy WAF in us-east-1
if [ "$SKIP_PHASE1" = false ]; then
    print_message $BLUE "=== Phase 1: Deploying CloudFront WAF in us-east-1 ==="
    
    if [ "$DRY_RUN" = true ]; then
        print_message $YELLOW "[DRY RUN] Would deploy WAF stack: $WAF_STACK_NAME"
    else
        # Check if WAF stack already exists
        if aws cloudformation describe-stacks --stack-name $WAF_STACK_NAME --region $WAF_REGION $AWS_CLI_OPTS >/dev/null 2>&1; then
            print_message $YELLOW "WAF stack already exists. Getting WebACL ARN..."
            WAF_ARN=$(aws cloudformation describe-stacks \
                --stack-name $WAF_STACK_NAME \
                --region $WAF_REGION \
                $AWS_CLI_OPTS \
                --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontWebACLArn`].OutputValue' \
                --output text)
        else
            print_message $YELLOW "Creating WAF stack..."
            
            # Deploy WAF stack
            aws cloudformation create-stack \
                --stack-name $WAF_STACK_NAME \
                --template-body file://$SCRIPT_DIR/../cloudformation/05-waf-cloudfront.yaml \
                --parameters \
                    ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
                    ParameterKey=Environment,ParameterValue=$ENVIRONMENT \
                --region $WAF_REGION \
                $AWS_CLI_OPTS \
                --capabilities CAPABILITY_IAM
            
            print_message $YELLOW "Waiting for WAF stack to complete..."
            aws cloudformation wait stack-create-complete \
                --stack-name $WAF_STACK_NAME \
                --region $WAF_REGION \
                $AWS_CLI_OPTS
            
            # Get WAF ARN
            WAF_ARN=$(aws cloudformation describe-stacks \
                --stack-name $WAF_STACK_NAME \
                --region $WAF_REGION \
                $AWS_CLI_OPTS \
                --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontWebACLArn`].OutputValue' \
                --output text)
        fi
        
        print_message $GREEN "✓ WAF deployed successfully!"
        print_message $YELLOW "WAF ARN: $WAF_ARN"
        
        # Save WAF state to file
        WAF_STATE_DIR="$SCRIPT_DIR/../.deploy-state"
        WAF_STATE_FILE="${WAF_STATE_DIR}/${PROJECT_NAME}-${ENVIRONMENT}-waf.json"
        
        # Create state directory if it doesn't exist
        mkdir -p "$WAF_STATE_DIR"
        
        # Save WAF state
        cat > "$WAF_STATE_FILE" <<EOF
{
  "WAFArn": "$WAF_ARN",
  "WAFStackName": "$WAF_STACK_NAME",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$WAF_REGION"
}
EOF
        print_message $GREEN "✓ WAF state saved to: $WAF_STATE_FILE"
        
        # Update parameters file with WAF ARN
        if [ -f "$PARAMS_FILE" ] && [ -n "$WAF_ARN" ]; then
            # Add CloudFrontWebACLArn to parameters if not already present
            if ! grep -q "CloudFrontWebACLArn" "$PARAMS_FILE"; then
                print_message $YELLOW "Adding CloudFrontWebACLArn to parameters file..."
                # Use jq to add the parameter properly
                if ! jq --arg waf_arn "$WAF_ARN" \
                   '. + [{"ParameterKey": "CloudFrontWebACLArn", "ParameterValue": $waf_arn}]' \
                   "$PARAMS_FILE" > "${PARAMS_FILE}.tmp"; then
                    print_message $RED "Error: Failed to add CloudFrontWebACLArn to parameters file"
                    rm -f "${PARAMS_FILE}.tmp"
                    exit 1
                fi
                mv "${PARAMS_FILE}.tmp" "$PARAMS_FILE"
            else
                # Update existing parameter
                print_message $YELLOW "Updating CloudFrontWebACLArn in parameters file..."
                # Use jq for the update
                if ! jq --arg waf_arn "$WAF_ARN" \
                   '(.[] | select(.ParameterKey == "CloudFrontWebACLArn") | .ParameterValue) = $waf_arn' \
                   "$PARAMS_FILE" > "${PARAMS_FILE}.tmp"; then
                    print_message $RED "Error: Failed to update CloudFrontWebACLArn in parameters file"
                    rm -f "${PARAMS_FILE}.tmp"
                    exit 1
                fi
                mv "${PARAMS_FILE}.tmp" "$PARAMS_FILE"
            fi
        fi
    fi
    
    print_message $GREEN "✓ Phase 1 completed successfully"
    echo ""
else
    print_message $YELLOW "Skipping Phase 1 (WAF deployment)"
    echo ""
fi

# Check for WAF state if Phase 1 was skipped
if [ "$SKIP_PHASE1" = true ]; then
    WAF_STATE_DIR="$SCRIPT_DIR/../.deploy-state"
    WAF_STATE_FILE="${WAF_STATE_DIR}/${PROJECT_NAME}-${ENVIRONMENT}-waf.json"
    
    if [ -f "$WAF_STATE_FILE" ]; then
        print_message $YELLOW "Found WAF state file, loading WAF ARN..."
        WAF_ARN=$(jq -r '.WAFArn' "$WAF_STATE_FILE")
        
        if [ -n "$WAF_ARN" ] && [ "$WAF_ARN" != "null" ]; then
            print_message $GREEN "✓ Loaded WAF ARN from state: $WAF_ARN"
            
            # Update parameters file with WAF ARN
            if [ -f "$PARAMS_FILE" ]; then
                # Check if CloudFrontWebACLArn exists and update it
                if grep -q "CloudFrontWebACLArn" "$PARAMS_FILE"; then
                    print_message $YELLOW "Updating CloudFrontWebACLArn in parameters file..."
                    if ! jq --arg waf_arn "$WAF_ARN" \
                       '(.[] | select(.ParameterKey == "CloudFrontWebACLArn") | .ParameterValue) = $waf_arn' \
                       "$PARAMS_FILE" > "${PARAMS_FILE}.tmp"; then
                        print_message $RED "Error: Failed to update CloudFrontWebACLArn"
                        rm -f "${PARAMS_FILE}.tmp"
                        exit 1
                    fi
                    mv "${PARAMS_FILE}.tmp" "$PARAMS_FILE"
                else
                    print_message $YELLOW "Adding CloudFrontWebACLArn to parameters file..."
                    if ! jq --arg waf_arn "$WAF_ARN" \
                       '. + [{"ParameterKey": "CloudFrontWebACLArn", "ParameterValue": $waf_arn}]' \
                       "$PARAMS_FILE" > "${PARAMS_FILE}.tmp"; then
                        print_message $RED "Error: Failed to add CloudFrontWebACLArn"
                        rm -f "${PARAMS_FILE}.tmp"
                        exit 1
                    fi
                    mv "${PARAMS_FILE}.tmp" "$PARAMS_FILE"
                fi
                print_message $GREEN "✓ Updated parameters file with WAF ARN"
            fi
        else
            print_message $YELLOW "⚠ WAF state file exists but no valid ARN found"
        fi
    else
        print_message $YELLOW "⚠ No WAF state file found. Make sure WAF was deployed in Phase 1."
        print_message $YELLOW "  Expected: $WAF_STATE_FILE"
    fi
    echo ""
fi

# Phase 2: Deploy infrastructure without ECS service
if [ "$SKIP_PHASE2" = false ]; then
    print_message $BLUE "=== Phase 2: Deploying Infrastructure (without ECS Service) ==="
    
    # Create temporary parameters file with CreateECSService=false
    TEMP_PARAMS_FILE="${PARAMS_FILE}.phase2.tmp"
    
    if [ -f "$PARAMS_FILE" ]; then
        # Copy existing parameters and set CreateECSService to false
        if [ "$DRY_RUN" = true ]; then
            print_message $YELLOW "[DRY RUN] Would create temporary parameters file with CreateECSService=false"
        else
            # Use jq to update the parameter
            jq '(.[] | select(.ParameterKey == "CreateECSService") | .ParameterValue) = "false"' \
                "$PARAMS_FILE" > "$TEMP_PARAMS_FILE"
            
            # If CreateECSService doesn't exist, add it
            if ! grep -q "CreateECSService" "$TEMP_PARAMS_FILE"; then
                # Use jq to add the parameter properly
                if ! jq '. + [{"ParameterKey": "CreateECSService", "ParameterValue": "false"}]' \
                   "$TEMP_PARAMS_FILE" > "${TEMP_PARAMS_FILE}.new"; then
                    print_message $RED "Error: Failed to add CreateECSService to parameters file"
                    rm -f "${TEMP_PARAMS_FILE}.new" "$TEMP_PARAMS_FILE"
                    exit 1
                fi
                mv "${TEMP_PARAMS_FILE}.new" "$TEMP_PARAMS_FILE"
            fi
        fi
    else
        print_message $RED "Error: Parameters file not found: $PARAMS_FILE"
        exit 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        print_message $YELLOW "[DRY RUN] Would deploy infrastructure stack without ECS service"
    else
        # Deploy infrastructure without service
        DEPLOY_ARGS=(
            --stack-name "$STACK_NAME"
            --params-file "$TEMP_PARAMS_FILE"
            --region "$REGION"
        )
        
        # Add force-deploy flag if force is set
        if [ "$FORCE_DEPLOY" = true ]; then
            DEPLOY_ARGS+=(--force)
        fi
        
        "$SCRIPT_DIR/lib/deploy-enhanced.sh" "${DEPLOY_ARGS[@]}" || {
                rm -f "$TEMP_PARAMS_FILE"
                print_message $RED "Phase 2 failed. Exiting."
                exit 1
            }
        
        # Clean up temporary file
        rm -f "$TEMP_PARAMS_FILE"
    fi
    
    print_message $GREEN "✓ Phase 2 completed successfully"
    echo ""
else
    print_message $YELLOW "Skipping Phase 2 (infrastructure deployment)"
    echo ""
fi

# Phase 3: Build Docker image and deploy ECS service
if [ "$SKIP_PHASE3" = false ]; then
    print_message $BLUE "=== Phase 3: Building Docker Image and Deploying ECS Service ==="
    
    # Get ECR URI from stack outputs
    if [ "$DRY_RUN" = true ]; then
        print_message $YELLOW "[DRY RUN] Would retrieve ECR URI from stack outputs"
        ECR_URI="DRYRUN-ECR-URI"
    else
        ECR_URI=$(aws cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            $AWS_CLI_OPTS \
            --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
            --output text)
        
        if [ -z "$ECR_URI" ] || [ "$ECR_URI" = "None" ]; then
            print_message $RED "Error: Could not retrieve ECR URI from stack outputs"
            exit 1
        fi
    fi
    
    print_message $YELLOW "ECR URI: $ECR_URI"
    
    # Step 1: Build and push Docker image
    print_message $YELLOW "Building and pushing Docker image..."
    
    if [ "$DRY_RUN" = true ]; then
        print_message $YELLOW "[DRY RUN] Would build and push Docker image to $ECR_URI"
    else
        # Check if build-and-push.sh exists
        BUILD_SCRIPT="$SCRIPT_DIR/build-and-push.sh"
        if [ -f "$BUILD_SCRIPT" ]; then
            # Build from repository root using the AWS-specific Dockerfile
            REPO_ROOT="$SCRIPT_DIR/../.."
            DOCKERFILE="$REPO_ROOT/Dockerfile.aws"
            
            if [ ! -f "$DOCKERFILE" ]; then
                print_message $RED "Dockerfile.aws not found at $DOCKERFILE"
                print_message $YELLOW "Please ensure Dockerfile.aws exists in the repository root"
                exit 1
            fi
            
            "$BUILD_SCRIPT" \
                --repository "$ECR_URI" \
                --tag latest \
                --context "$REPO_ROOT" \
                --dockerfile "$DOCKERFILE" \
                --region "$REGION" || {
                    print_message $RED "Docker build and push failed. Exiting."
                    exit 1
                }
        else
            print_message $YELLOW "build-and-push.sh not found. Manual Docker build required:"
            print_message $YELLOW "1. cd to your Strapi application directory"
            print_message $YELLOW "2. docker build -t strapi-app ."
            print_message $YELLOW "3. aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI"
            print_message $YELLOW "4. docker tag strapi-app:latest $ECR_URI:latest"
            print_message $YELLOW "5. docker push $ECR_URI:latest"
            print_message $YELLOW ""
            if [ "$FORCE_DEPLOY" = true ]; then
                print_message $YELLOW "Force deploy enabled, skipping Docker build confirmation."
                REPLY="n"
            else
                read -p "Have you built and pushed the Docker image? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    print_message $RED "Please build and push the Docker image before continuing."
                    exit 1
                fi
            fi
        fi
    fi
    
    # Step 2: Update stack to create ECS service
    print_message $YELLOW "Updating stack to create ECS service..."
    
    if [ "$DRY_RUN" = true ]; then
        print_message $YELLOW "[DRY RUN] Would update stack with CreateECSService=true"
    else
        # Deploy with service enabled (using original parameters file)
        DEPLOY_ARGS=(
            --stack-name "$STACK_NAME"
            --params-file "$PARAMS_FILE"
            --region "$REGION"
        )
        
        # Add force-deploy flag if force is set
        if [ "$FORCE_DEPLOY" = true ]; then
            DEPLOY_ARGS+=(--force)
        fi
        
        "$SCRIPT_DIR/lib/deploy-enhanced.sh" "${DEPLOY_ARGS[@]}" || {
                print_message $RED "Phase 3 failed. Exiting."
                exit 1
            }
    fi
    
    print_message $GREEN "✓ Phase 3 completed successfully"
    echo ""
else
    print_message $YELLOW "Skipping Phase 3 (Docker build and service deployment)"
    echo ""
fi

# Final summary
print_message $GREEN "=== Three-Phase Deployment Complete ==="

if [ "$DRY_RUN" = false ]; then
    # Get final outputs
    print_message $YELLOW "Stack Outputs:"
    
    ALB_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        $AWS_CLI_OPTS \
        --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    
    CLOUDFRONT_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        $AWS_CLI_OPTS \
        --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    
    print_message $YELLOW "Application URL: $ALB_URL"
    print_message $YELLOW "CloudFront URL: $CLOUDFRONT_URL"
    print_message $YELLOW ""
fi

print_message $YELLOW "Next steps:"
print_message $YELLOW "1. Configure your domain name to point to the ALB"
print_message $YELLOW "2. Update WAF admin IP set with allowed IPs"
print_message $YELLOW "3. Configure SSL certificate on the ALB"
print_message $YELLOW "4. Monitor ECS service for successful deployment"
print_message $YELLOW ""
print_message $YELLOW "To check service status:"
print_message $YELLOW "aws ecs describe-services --cluster ${STACK_NAME}-cluster --services ${STACK_NAME}-service --region $REGION"