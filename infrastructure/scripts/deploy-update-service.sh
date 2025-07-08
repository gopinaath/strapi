#!/bin/bash
set -e

# Production-safe script for updating Strapi service with new Docker image
# This script ONLY builds and deploys the Docker image, without infrastructure changes

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
STACK_NAME=""
REGION="us-west-2"
TAG="latest"
SKIP_BUILD=false

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
    echo "  --stack-name NAME    CloudFormation stack name (required)"
    echo "  --region REGION      AWS region (default: us-west-2)"
    echo "  --tag TAG            Docker image tag (default: latest)"
    echo "  --skip-build         Skip Docker build, only update service"
    echo "  --help               Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 --stack-name strapi-production"
    echo ""
    echo "This script safely updates the ECS service with a new Docker image"
    echo "without modifying any infrastructure."
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
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

# Validate required parameters
if [ -z "$STACK_NAME" ]; then
    print_message $RED "Error: --stack-name is required"
    usage
    exit 1
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check prerequisites
print_message $YELLOW "Checking prerequisites..."
PREREQ_ARGS=()
if [ "$SKIP_BUILD" = true ]; then
    PREREQ_ARGS+=(--skip-docker)
fi

if ! "$SCRIPT_DIR/check-prerequisites.sh" "${PREREQ_ARGS[@]}"; then
    print_message $RED "Prerequisites check failed. Please fix the issues above before proceeding."
    exit 1
fi
echo ""

# Export flag to skip redundant checks in child scripts
export STRAPI_PREREQ_CHECKED=true

print_message $GREEN "=== Strapi Service Update ==="
print_message $YELLOW "Stack: $STACK_NAME"
print_message $YELLOW "Region: $REGION"
print_message $YELLOW "Tag: $TAG"
echo ""

# Verify stack exists
print_message $YELLOW "Verifying stack exists..."
if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    print_message $RED "Error: Stack $STACK_NAME not found in region $REGION"
    exit 1
fi

# Get ECR URI and service details from stack outputs
print_message $YELLOW "Retrieving stack information..."
ECR_URI=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
    --output text)

CLUSTER_NAME="${STACK_NAME}-cluster"
SERVICE_NAME="${STACK_NAME}-service"

if [ -z "$ECR_URI" ] || [ "$ECR_URI" = "None" ]; then
    print_message $RED "Error: Could not retrieve ECR URI from stack outputs"
    exit 1
fi

print_message $GREEN "✓ Stack information retrieved"
print_message $YELLOW "ECR URI: $ECR_URI"
echo ""

# Build and push Docker image (unless skipped)
if [ "$SKIP_BUILD" = false ]; then
    print_message $BLUE "=== Building and Pushing Docker Image ==="
    
    BUILD_SCRIPT="$SCRIPT_DIR/build-and-push.sh"
    if [ ! -f "$BUILD_SCRIPT" ]; then
        print_message $RED "Error: build-and-push.sh not found"
        exit 1
    fi
    
    # Build from repository root using the AWS-specific Dockerfile
    REPO_ROOT="$SCRIPT_DIR/../.."
    DOCKERFILE="$REPO_ROOT/Dockerfile.aws"
    
    if [ ! -f "$DOCKERFILE" ]; then
        print_message $RED "Error: Dockerfile.aws not found at $DOCKERFILE"
        exit 1
    fi
    
    # Build and push with explicit error handling
    if ! "$BUILD_SCRIPT" \
        --repository "$ECR_URI" \
        --tag "$TAG" \
        --context "$REPO_ROOT" \
        --dockerfile "$DOCKERFILE" \
        --region "$REGION"; then
        print_message $RED "Docker build and push failed"
        exit 1
    fi
    
    print_message $GREEN "✓ Docker image built and pushed successfully"
else
    print_message $YELLOW "Skipping Docker build (--skip-build specified)"
fi

# Update ECS service
print_message $BLUE "=== Updating ECS Service ==="
print_message $YELLOW "Forcing new deployment of service..."

if ! aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --force-new-deployment \
    --region "$REGION" \
    --output json > /dev/null; then
    print_message $RED "Failed to update ECS service"
    exit 1
fi

print_message $GREEN "✓ ECS service update initiated"

# Wait for service to stabilize
print_message $YELLOW "Waiting for service to stabilize (this may take a few minutes)..."

if aws ecs wait services-stable \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION"; then
    print_message $GREEN "✓ Service deployment completed successfully"
else
    print_message $RED "Service failed to stabilize"
    print_message $YELLOW "Check ECS console for details"
    exit 1
fi

# Verify deployment
print_message $BLUE "=== Verifying Deployment ==="

# Get running task count
RUNNING_TASKS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' \
    --output text)

DESIRED_TASKS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].desiredCount' \
    --output text)

print_message $YELLOW "Service status: $RUNNING_TASKS/$DESIRED_TASKS tasks running"

if [ "$RUNNING_TASKS" -eq "$DESIRED_TASKS" ]; then
    print_message $GREEN "✓ All tasks are running"
else
    print_message $YELLOW "⚠ Warning: Not all tasks are running yet"
fi

# Check ALB health
ALB_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL`].OutputValue' \
    --output text)

if [ -n "$ALB_URL" ] && [ "$ALB_URL" != "None" ]; then
    print_message $YELLOW "Checking health endpoint..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ALB_URL/_health" || echo "000")
    if [ "$HTTP_STATUS" = "204" ] || [ "$HTTP_STATUS" = "200" ]; then
        print_message $GREEN "✓ Health check passed (HTTP $HTTP_STATUS)"
    else
        print_message $YELLOW "⚠ Health check returned HTTP $HTTP_STATUS"
    fi
fi

print_message $GREEN "=== Service Update Complete ==="
print_message $YELLOW ""
print_message $YELLOW "Application URL: $ALB_URL"
print_message $YELLOW ""
print_message $YELLOW "To view logs:"
print_message $YELLOW "aws logs tail /ecs/$STACK_NAME --region $REGION --follow"