#!/bin/bash

# Script to build and push Strapi Docker image to ECR
# Fixed version that handles monorepo structure and ECR login correctly

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ECR_REPOSITORY=""
AWS_REGION="us-west-2"  # Changed default to us-west-2
IMAGE_TAG="latest"
DOCKERFILE_PATH="./Dockerfile"
BUILD_CONTEXT="."

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check Docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_message $RED "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_message $RED "Docker daemon is not running. Please start Docker."
        exit 1
    fi
}

# Function to extract ECR registry URL from repository URI
extract_ecr_registry() {
    local repository=$1
    # Extract the registry URL from the full repository URI
    # Format: ACCOUNT.dkr.ecr.REGION.amazonaws.com/REPO_NAME
    echo "$repository" | sed 's|/.*||'
}

# Function to extract region from ECR repository URI
extract_ecr_region() {
    local repository=$1
    # Extract region from ECR URI (macOS compatible)
    # Format: ACCOUNT.dkr.ecr.REGION.amazonaws.com/REPO_NAME
    echo "$repository" | sed -E 's/.*\.ecr\.([^.]+)\.amazonaws\.com.*/\1/'
}

# Function to login to ECR
ecr_login() {
    local repository=$1
    local region=$2
    
    # Extract registry URL from repository
    local registry=$(extract_ecr_registry "$repository")
    
    print_message $YELLOW "Logging in to Amazon ECR..."
    print_message $BLUE "Registry: $registry"
    print_message $BLUE "Region: $region"
    
    # Login to the specific ECR registry
    aws ecr get-login-password --region "$region" | \
        docker login --username AWS --password-stdin "$registry"
    
    print_message $GREEN "Successfully logged in to ECR!"
}

# Function to build Docker image
build_image() {
    local repository=$1
    local tag=$2
    local dockerfile=$3
    local context=$4
    
    print_message $YELLOW "Building Docker image..."
    print_message $BLUE "Dockerfile: $dockerfile"
    print_message $BLUE "Context: $context"
    print_message $BLUE "Repository: $repository"
    
    # Check if we're dealing with an absolute path
    if [[ "$dockerfile" = /* ]]; then
        # Absolute path - check if file exists
        if [ ! -f "$dockerfile" ]; then
            print_message $RED "Error: Dockerfile not found at $dockerfile"
            exit 1
        fi
    else
        # Relative path - check in context directory
        if [ ! -f "$context/$dockerfile" ]; then
            print_message $RED "Error: Dockerfile not found at $context/$dockerfile"
            exit 1
        fi
    fi
    
    docker build \
        -t "$repository:$tag" \
        -t "$repository:latest" \
        -f "$dockerfile" \
        "$context"
    
    print_message $GREEN "Docker image built successfully!"
}

# Function to push image to ECR
push_image() {
    local repository=$1
    local tag=$2
    
    print_message $YELLOW "Pushing image to ECR..."
    
    docker push "$repository:$tag"
    if [ "$tag" != "latest" ]; then
        docker push "$repository:latest"
    fi
    
    print_message $GREEN "Image pushed successfully!"
}

# Function to update ECS service
update_ecs_service() {
    local cluster=$1
    local service=$2
    local region=$3
    
    print_message $YELLOW "Updating ECS service..."
    
    aws ecs update-service \
        --cluster "$cluster" \
        --service "$service" \
        --force-new-deployment \
        --region "$region" \
        --output json > /dev/null
    
    print_message $GREEN "ECS service update initiated!"
}

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -r, --repository      ECR repository URI (required)"
    echo "  -t, --tag             Image tag (default: latest)"
    echo "  -f, --dockerfile      Path to Dockerfile (default: ./Dockerfile)"
    echo "  -c, --context         Build context (default: .)"
    echo "  -g, --region          AWS region (default: us-west-2)"
    echo "  -u, --update-service  Update ECS service (format: cluster:service)"
    echo "  -h, --help            Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 --repository 123456789012.dkr.ecr.us-west-2.amazonaws.com/myapp \\"
    echo "     --dockerfile /path/to/Dockerfile.aws \\"
    echo "     --context /path/to/repo \\"
    echo "     --region us-west-2"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -r|--repository)
            ECR_REPOSITORY="$2"
            shift
            shift
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift
            shift
            ;;
        -f|--dockerfile)
            DOCKERFILE_PATH="$2"
            shift
            shift
            ;;
        -c|--context)
            BUILD_CONTEXT="$2"
            shift
            shift
            ;;
        -g|--region)
            AWS_REGION="$2"
            shift
            shift
            ;;
        -u|--update-service)
            UPDATE_SERVICE="$2"
            shift
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
if [ -z "$ECR_REPOSITORY" ]; then
    print_message $RED "Error: --repository is required"
    usage
fi


# If region wasn't specified, try to extract it from the repository URI
if [ "$AWS_REGION" == "us-west-2" ] && [[ "$ECR_REPOSITORY" =~ \.ecr\. ]]; then
    EXTRACTED_REGION=$(extract_ecr_region "$ECR_REPOSITORY")
    if [ -n "$EXTRACTED_REGION" ]; then
        # Validate the extracted region
        if [[ "$EXTRACTED_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]] || [[ "$EXTRACTED_REGION" =~ ^[a-z]{2}-gov-[a-z]+-[0-9]+$ ]]; then
            AWS_REGION="$EXTRACTED_REGION"
            print_message $YELLOW "Auto-detected region from repository URI: $AWS_REGION"
        else
            print_message $YELLOW "Warning: Extracted region '$EXTRACTED_REGION' doesn't look valid, using default: $AWS_REGION"
        fi
    fi
fi

# Get script directory for prerequisites check
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check prerequisites (focuses on Docker and AWS)
# Skip if already checked in parent script
if [ "$STRAPI_PREREQ_CHECKED" != "true" ]; then
    print_message $YELLOW "Checking prerequisites..."
    if ! "$SCRIPT_DIR/check-prerequisites.sh"; then
        print_message $RED "Prerequisites check failed. Please fix the issues above before proceeding."
        exit 1
    fi
    echo ""
fi

# Main execution
print_message $GREEN "=== Strapi ECR Build and Push Script ==="
print_message $YELLOW "Repository: $ECR_REPOSITORY"
print_message $YELLOW "Tag: $IMAGE_TAG"
print_message $YELLOW "Region: $AWS_REGION"
print_message $YELLOW "Dockerfile: $DOCKERFILE_PATH"
print_message $YELLOW "Context: $BUILD_CONTEXT"

# Debug: Show current working directory
print_message $BLUE "Current directory: $(pwd)"
echo ""

# Execute steps
check_docker
ecr_login "$ECR_REPOSITORY" "$AWS_REGION"
build_image "$ECR_REPOSITORY" "$IMAGE_TAG" "$DOCKERFILE_PATH" "$BUILD_CONTEXT"
push_image "$ECR_REPOSITORY" "$IMAGE_TAG"

# Update ECS service if requested
if [ ! -z "$UPDATE_SERVICE" ]; then
    IFS=':' read -r cluster service <<< "$UPDATE_SERVICE"
    if [ ! -z "$cluster" ] && [ ! -z "$service" ]; then
        update_ecs_service "$cluster" "$service" "$AWS_REGION"
    else
        print_message $RED "Invalid service format. Use: cluster:service"
    fi
fi

print_message $GREEN "\n=== Build and push completed successfully! ==="