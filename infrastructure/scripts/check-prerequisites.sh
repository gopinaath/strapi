#!/bin/bash

# Prerequisites Check Script for Strapi AWS Deployment
# Validates all requirements before deployment

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track if all checks pass
ALL_CHECKS_PASSED=true

# Skip if already checked in parent script
if [ "$STRAPI_PREREQ_CHECKED" = "true" ]; then
    echo -e "${GREEN}✓ Prerequisites already verified by parent script${NC}"
    exit 0
fi

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if a command exists
check_command() {
    local cmd=$1
    local min_version=$2
    local version_cmd=$3
    
    if command -v "$cmd" &> /dev/null; then
        if [ -n "$version_cmd" ]; then
            local version=$($version_cmd 2>&1)
            print_message $GREEN "✓ $cmd is installed: $version"
        else
            print_message $GREEN "✓ $cmd is installed"
        fi
    else
        print_message $RED "✗ $cmd is not installed"
        ALL_CHECKS_PASSED=false
        return 1
    fi
}

# Parse command line arguments
ENVIRONMENT=""
REGION=""
SKIP_DOCKER=false
SKIP_PHASE3=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --skip-docker)
            SKIP_DOCKER=true
            shift
            ;;
        --skip-phase3)
            SKIP_PHASE3=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$SCRIPT_DIR/../.."

print_message $BLUE "=== Checking Prerequisites for Strapi AWS Deployment ==="
echo ""

# 1. Check required commands
print_message $YELLOW "Checking required tools..."

# AWS CLI
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
    if [[ "$AWS_VERSION" =~ ^2\. ]]; then
        print_message $GREEN "✓ AWS CLI v2 is installed: $AWS_VERSION"
    else
        print_message $YELLOW "⚠ AWS CLI v1 detected. v2 is recommended: $AWS_VERSION"
    fi
else
    print_message $RED "✗ AWS CLI is not installed"
    ALL_CHECKS_PASSED=false
fi

# jq
check_command "jq" "" "jq --version"

# bash version
BASH_VERSION=$(bash --version | head -n1 | cut -d' ' -f4 | cut -d'(' -f1)
if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
    print_message $GREEN "✓ Bash version is 4+: $BASH_VERSION"
else
    print_message $RED "✗ Bash version is less than 4: $BASH_VERSION"
    ALL_CHECKS_PASSED=false
fi

# Docker (only if not skipping)
if [ "$SKIP_DOCKER" = false ] && [ "$SKIP_PHASE3" = false ]; then
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | sed 's/,$//')
            print_message $GREEN "✓ Docker is installed and running: $DOCKER_VERSION"
        else
            print_message $RED "✗ Docker is installed but not running"
            print_message $YELLOW "  Please start Docker daemon"
            ALL_CHECKS_PASSED=false
        fi
    else
        print_message $RED "✗ Docker is not installed"
        ALL_CHECKS_PASSED=false
    fi
else
    print_message $YELLOW "⚠ Skipping Docker check (not needed for this deployment)"
fi

echo ""

# 2. Check AWS credentials
print_message $YELLOW "Checking AWS credentials..."
if aws sts get-caller-identity &> /dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    print_message $GREEN "✓ AWS credentials are configured"
    print_message $GREEN "  Account: $ACCOUNT_ID"
    print_message $GREEN "  Identity: $CALLER_ARN"
else
    print_message $RED "✗ AWS credentials are not configured"
    print_message $YELLOW "  Run: aws configure"
    ALL_CHECKS_PASSED=false
fi

echo ""

# 3. Check required files
print_message $YELLOW "Checking required files..."

# Dockerfile.aws (only if not skipping Docker)
if [ "$SKIP_DOCKER" = false ] && [ "$SKIP_PHASE3" = false ]; then
    if [ -f "$REPO_ROOT/Dockerfile.aws" ]; then
        print_message $GREEN "✓ Dockerfile.aws exists"
    else
        print_message $RED "✗ Dockerfile.aws not found in repository root"
        ALL_CHECKS_PASSED=false
    fi
fi

# Parameters file (if environment and region specified)
if [ -n "$ENVIRONMENT" ] && [ -n "$REGION" ]; then
    PARAMS_FILE="$SCRIPT_DIR/../parameters/${REGION}-${ENVIRONMENT}.json"
    PARAMS_TEMPLATE="${PARAMS_FILE}.template"
    
    if [ -f "$PARAMS_FILE" ]; then
        print_message $GREEN "✓ Parameters file exists: ${REGION}-${ENVIRONMENT}.json"
        
        # Validate JSON syntax
        if jq empty "$PARAMS_FILE" 2>/dev/null; then
            print_message $GREEN "✓ Parameters file has valid JSON syntax"
        else
            print_message $RED "✗ Parameters file has invalid JSON syntax"
            ALL_CHECKS_PASSED=false
        fi
    elif [ -f "$PARAMS_TEMPLATE" ]; then
        print_message $YELLOW "⚠ Parameters file not found, but template exists"
        print_message $YELLOW "  Processing template to create parameters file..."
        
        # Process the template
        if "$SCRIPT_DIR/lib/process-parameters.sh" "$PARAMS_TEMPLATE" "$PARAMS_FILE" >/dev/null 2>&1; then
            print_message $GREEN "✓ Successfully created parameters file from template"
            
            # Validate the generated JSON
            if jq empty "$PARAMS_FILE" 2>/dev/null; then
                print_message $GREEN "✓ Generated parameters file has valid JSON syntax"
            else
                print_message $RED "✗ Generated parameters file has invalid JSON syntax"
                ALL_CHECKS_PASSED=false
            fi
        else
            print_message $RED "✗ Failed to process parameter template"
            print_message $YELLOW "  Try running manually: $SCRIPT_DIR/lib/process-parameters.sh $PARAMS_TEMPLATE $PARAMS_FILE"
            ALL_CHECKS_PASSED=false
        fi
    else
        print_message $RED "✗ Neither parameters file nor template found: ${REGION}-${ENVIRONMENT}.json"
        print_message $YELLOW "  Expected locations:"
        print_message $YELLOW "    - $PARAMS_FILE"
        print_message $YELLOW "    - $PARAMS_TEMPLATE"
        ALL_CHECKS_PASSED=false
    fi
fi

# Check for .env file
ENV_FILE="$SCRIPT_DIR/../.env"
ENV_EXAMPLE="$SCRIPT_DIR/../.env.example"
if [ -f "$ENV_FILE" ]; then
    print_message $GREEN "✓ .env file exists"
elif [ -f "$ENV_EXAMPLE" ]; then
    print_message $YELLOW "⚠ .env file not found, creating from example..."
    if cp "$ENV_EXAMPLE" "$ENV_FILE"; then
        print_message $GREEN "✓ Successfully created .env file from example"
        print_message $YELLOW "  Note: Review and update values in $ENV_FILE as needed"
    else
        print_message $YELLOW "⚠ Could not create .env file (will use defaults)"
        print_message $YELLOW "  Create manually: cp $ENV_EXAMPLE $ENV_FILE"
    fi
else
    print_message $YELLOW "⚠ Neither .env nor .env.example found (will use defaults)"
fi

# Check required scripts
REQUIRED_SCRIPTS=(
    "lib/deploy-enhanced.sh"
    "build-and-push.sh"
)

ALL_SCRIPTS_EXIST=true
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        if [ -x "$SCRIPT_DIR/$script" ]; then
            print_message $GREEN "✓ $script exists and is executable"
        else
            print_message $YELLOW "⚠ $script exists but is not executable"
            print_message $YELLOW "  Run: chmod +x $SCRIPT_DIR/$script"
            ALL_SCRIPTS_EXIST=false
        fi
    else
        print_message $RED "✗ $script not found"
        ALL_SCRIPTS_EXIST=false
        ALL_CHECKS_PASSED=false
    fi
done

echo ""

# 4. Check AWS service limits (optional)
print_message $YELLOW "Checking AWS service availability..."

# Check if we can list S3 buckets (basic permission check)
if aws s3 ls &> /dev/null; then
    print_message $GREEN "✓ Basic AWS permissions verified"
else
    print_message $YELLOW "⚠ Could not list S3 buckets (may lack permissions)"
fi

# Check ECS service
if aws ecs list-clusters --region "${REGION:-us-west-2}" &> /dev/null; then
    print_message $GREEN "✓ ECS service is accessible"
else
    print_message $YELLOW "⚠ Could not access ECS service"
fi

echo ""

# 5. Summary
if [ "$ALL_CHECKS_PASSED" = true ]; then
    print_message $GREEN "=== All prerequisites checks passed! ==="
    exit 0
else
    print_message $RED "=== Some prerequisites are missing ==="
    print_message $YELLOW "Please install missing tools and fix issues before proceeding."
    exit 1
fi