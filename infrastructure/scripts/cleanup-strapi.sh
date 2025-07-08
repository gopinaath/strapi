#!/bin/bash

# Script to clean up all Strapi-related resources in AWS
# This ensures a clean slate for deployment
# Enhanced with better error handling and resource cleanup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to retry a command with exponential backoff
retry_command() {
    local max_attempts=3
    local timeout=1
    local attempt=1
    local exitCode=0

    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        else
            exitCode=$?
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            return $exitCode
        fi

        print_message $YELLOW "  Retry attempt $attempt/$max_attempts failed. Retrying in ${timeout}s..."
        sleep $timeout
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
    done
}

print_message $YELLOW "=== Strapi AWS Cleanup Script ==="
print_message $YELLOW "This will remove ALL Strapi-related resources from your AWS account"
echo

# Confirm with user
read -p "Are you sure you want to delete all Strapi resources? Type 'yes' to confirm: " -r
echo
if [[ ! $REPLY == "yes" ]]; then
    print_message $RED "Cleanup cancelled."
    exit 1
fi

# Define regions to clean
REGIONS=("us-east-1" "us-west-2")

# Track overall success
OVERALL_SUCCESS=true

for REGION in "${REGIONS[@]}"; do
    print_message $BLUE "╔═══════════════════════════════════════╗"
    print_message $BLUE "║ Cleaning up resources in $REGION"
    print_message $BLUE "╚═══════════════════════════════════════╝"
    
    # 0. Pre-cleanup: Disassociate WAF from CloudFront distributions
    if [ "$REGION" == "us-east-1" ]; then
        print_message $YELLOW "Checking CloudFront distributions for WAF associations..."
        
        # Get all CloudFront distributions
        DISTRIBUTIONS=$(aws cloudfront list-distributions \
            --query "DistributionList.Items[?contains(Comment, 'strapi') || contains(Origins.Items[0].DomainName, 'strapi')].{Id:Id,WebACLId:WebACLId}" \
            --output json 2>/dev/null || echo "[]")
        
        if [ "$DISTRIBUTIONS" != "[]" ] && [ -n "$DISTRIBUTIONS" ]; then
            echo "$DISTRIBUTIONS" | jq -r '.[] | select(.WebACLId != null and .WebACLId != "") | @base64' | while read -r dist; do
                _jq() {
                    echo "${dist}" | base64 --decode | jq -r "${1}"
                }
                DIST_ID=$(_jq '.Id')
                WACL_ID=$(_jq '.WebACLId')
                
                if [[ $WACL_ID == *"strapi"* ]]; then
                    print_message $YELLOW "  Disassociating WAF from CloudFront distribution: $DIST_ID"
                    
                    # Get distribution config
                    CONFIG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query "{Config:DistributionConfig,ETag:ETag}" --output json 2>/dev/null || echo "")
                    
                    if [ -n "$CONFIG" ]; then
                        ETAG=$(echo "$CONFIG" | jq -r '.ETag')
                        
                        # Remove WebACLId from config
                        UPDATED_CONFIG=$(echo "$CONFIG" | jq '.Config.WebACLId = ""' | jq '.Config')
                        
                        # Update distribution
                        echo "$UPDATED_CONFIG" > /tmp/dist-config.json
                        retry_command aws cloudfront update-distribution \
                            --id "$DIST_ID" \
                            --distribution-config file:///tmp/dist-config.json \
                            --if-match "$ETAG" 2>/dev/null || {
                                print_message $RED "    Failed to disassociate WAF from $DIST_ID"
                            }
                        rm -f /tmp/dist-config.json
                    fi
                fi
            done
        fi
    fi
    
    # 1. Clean up ECR repositories BEFORE trying to delete stacks
    print_message $YELLOW "Cleaning up ECR repositories..."
    REPOS=$(aws ecr describe-repositories --region "$REGION" \
        --query "repositories[?contains(repositoryName, 'strapi')].repositoryName" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$REPOS" ]; then
        for REPO in $REPOS; do
            print_message $YELLOW "  Deleting all images from ECR repository: $REPO"
            
            # List all images
            IMAGES=$(aws ecr list-images --repository-name "$REPO" --region "$REGION" \
                --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
            
            if [ "$IMAGES" != "[]" ] && [ -n "$IMAGES" ]; then
                # Delete all images
                echo "$IMAGES" > /tmp/images.json
                retry_command aws ecr batch-delete-image \
                    --repository-name "$REPO" \
                    --region "$REGION" \
                    --image-ids file:///tmp/images.json 2>/dev/null || {
                        print_message $RED "    Failed to delete images from $REPO"
                    }
                rm -f /tmp/images.json
            fi
            
            print_message $YELLOW "  Deleting ECR repository: $REPO"
            retry_command aws ecr delete-repository --repository-name "$REPO" --force --region "$REGION" 2>/dev/null || {
                print_message $RED "    Failed to delete repository $REPO"
                OVERALL_SUCCESS=false
            }
        done
    fi
    
    # 2. Delete CloudFormation stacks in dependency order
    print_message $YELLOW "Analyzing CloudFormation stack dependencies..."
    
    # Get all stacks
    ALL_STACKS=$(aws cloudformation list-stacks \
        --region "$REGION" \
        --stack-status-filter CREATE_COMPLETE CREATE_FAILED DELETE_FAILED UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        --query "StackSummaries[?contains(StackName, 'strapi')].StackName" \
        --output text)
    
    if [ -n "$ALL_STACKS" ]; then
        # Separate root and nested stacks
        ROOT_STACKS=""
        NESTED_STACKS=""
        
        for STACK in $ALL_STACKS; do
            # Check if it's a nested stack
            PARENT=$(aws cloudformation describe-stacks \
                --stack-name "$STACK" \
                --region "$REGION" \
                --query "Stacks[0].ParentId" \
                --output text 2>/dev/null || echo "None")
            
            if [ "$PARENT" == "None" ] || [ -z "$PARENT" ]; then
                ROOT_STACKS="$ROOT_STACKS $STACK"
            else
                NESTED_STACKS="$NESTED_STACKS $STACK"
            fi
        done
        
        # Delete nested stacks first
        if [ -n "$NESTED_STACKS" ]; then
            print_message $YELLOW "Deleting nested CloudFormation stacks..."
            for STACK in $NESTED_STACKS; do
                print_message $YELLOW "  Deleting nested stack: $STACK"
                retry_command aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || {
                    print_message $RED "    Failed to initiate deletion of $STACK"
                }
            done
            
            # Wait for nested stack deletions
            for STACK in $NESTED_STACKS; do
                print_message $YELLOW "  Waiting for $STACK to be deleted..."
                aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || {
                    print_message $RED "    Stack $STACK deletion incomplete or failed"
                    OVERALL_SUCCESS=false
                }
            done
        fi
        
        # Delete root stacks
        if [ -n "$ROOT_STACKS" ]; then
            print_message $YELLOW "Deleting root CloudFormation stacks..."
            for STACK in $ROOT_STACKS; do
                print_message $YELLOW "  Deleting root stack: $STACK"
                retry_command aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || {
                    print_message $RED "    Failed to initiate deletion of $STACK"
                }
            done
            
            # Wait for root stack deletions
            for STACK in $ROOT_STACKS; do
                print_message $YELLOW "  Waiting for $STACK to be deleted..."
                aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || {
                    print_message $RED "    Stack $STACK deletion incomplete or failed"
                    OVERALL_SUCCESS=false
                }
            done
        fi
    fi
    
    # 3. Clean up WAF WebACLs (only in us-east-1 for CloudFront)
    if [ "$REGION" == "us-east-1" ]; then
        print_message $YELLOW "Cleaning up CloudFront WAF WebACLs..."
        WACLS=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
            --query "WebACLs[?contains(Name, 'strapi')].{Name:Name,Id:Id}" \
            --output json 2>/dev/null || echo "[]")
        
        if [ "$WACLS" != "[]" ] && [ -n "$WACLS" ]; then
            echo "$WACLS" | jq -r '.[] | @base64' | while read -r wacl; do
                _jq() {
                    echo "${wacl}" | base64 --decode | jq -r "${1}"
                }
                NAME=$(_jq '.Name')
                ID=$(_jq '.Id')
                print_message $YELLOW "  Deleting WAF: $NAME"
                
                # Get lock token
                LOCK_TOKEN=$(aws wafv2 get-web-acl --name "$NAME" --id "$ID" --scope CLOUDFRONT --region us-east-1 --query LockToken --output text 2>/dev/null || echo "")
                
                if [ -n "$LOCK_TOKEN" ]; then
                    retry_command aws wafv2 delete-web-acl \
                        --name "$NAME" \
                        --id "$ID" \
                        --scope CLOUDFRONT \
                        --region us-east-1 \
                        --lock-token "$LOCK_TOKEN" 2>/dev/null || {
                            print_message $RED "    Failed to delete WAF $NAME"
                            OVERALL_SUCCESS=false
                        }
                else
                    print_message $RED "    Could not get lock token for WAF $NAME"
                fi
            done
        fi
    fi
    
    # 4. Clean up S3 buckets
    print_message $YELLOW "Cleaning up S3 buckets..."
    BUCKETS=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'strapi')].Name" --output text)
    
    if [ -n "$BUCKETS" ]; then
        for BUCKET in $BUCKETS; do
            # Check if bucket is in this region
            BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text 2>/dev/null || echo "skip")
            
            # Handle us-east-1 special case (returns null)
            if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ]; then
                BUCKET_REGION="us-east-1"
            fi
            
            if [ "$BUCKET_REGION" == "$REGION" ] || [ "$BUCKET_REGION" == "skip" ]; then
                print_message $YELLOW "  Emptying and deleting bucket: $BUCKET"
                
                # Delete all object versions (for versioned buckets)
                aws s3api delete-objects \
                    --bucket "$BUCKET" \
                    --delete "$(aws s3api list-object-versions \
                        --bucket "$BUCKET" \
                        --output json \
                        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
                
                # Delete all delete markers
                aws s3api delete-objects \
                    --bucket "$BUCKET" \
                    --delete "$(aws s3api list-object-versions \
                        --bucket "$BUCKET" \
                        --output json \
                        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
                
                # Empty bucket (non-versioned objects)
                retry_command aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
                
                # Delete bucket
                retry_command aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || {
                    print_message $RED "    Failed to delete bucket $BUCKET"
                    OVERALL_SUCCESS=false
                }
            fi
        done
    fi
    
    # 5. Clean up CloudWatch Log Groups
    print_message $YELLOW "Cleaning up CloudWatch Log Groups..."
    LOG_GROUPS=$(aws logs describe-log-groups --region "$REGION" \
        --query "logGroups[?contains(logGroupName, 'strapi')].logGroupName" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$LOG_GROUPS" ]; then
        for LOG_GROUP in $LOG_GROUPS; do
            print_message $YELLOW "  Deleting log group: $LOG_GROUP"
            retry_command aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION" 2>/dev/null || {
                print_message $RED "    Failed to delete log group $LOG_GROUP"
            }
        done
    fi
    
    print_message $GREEN "✓ Cleanup complete for $REGION"
    echo
done

# Reset parameters files
print_message $YELLOW "Resetting CloudFrontWebACLArn in all parameters files..."
PARAMS_DIR="$(dirname "$0")/../parameters"
if [ -d "$PARAMS_DIR" ]; then
    for params_file in "$PARAMS_DIR"/*.json; do
        if [ -f "$params_file" ] && grep -q "CloudFrontWebACLArn" "$params_file" 2>/dev/null; then
            # Reset CloudFrontWebACLArn to empty
            jq '(.[] | select(.ParameterKey == "CloudFrontWebACLArn") | .ParameterValue) = ""' \
                "$params_file" > "${params_file}.tmp" && mv "${params_file}.tmp" "$params_file"
            print_message $GREEN "✓ Reset $(basename "$params_file")"
        fi
    done
else
    print_message $YELLOW "Parameters directory not found, skipping reset"
fi

# Final status
echo
if [ "$OVERALL_SUCCESS" = true ]; then
    print_message $GREEN "╔════════════════════════════════════════╗"
    print_message $GREEN "║       Cleanup Complete!                ║"
    print_message $GREEN "╚════════════════════════════════════════╝"
    print_message $YELLOW "All Strapi-related resources have been removed."
    print_message $YELLOW "You can now run a fresh deployment with deploy-three-phase.sh"
else
    print_message $RED "╔════════════════════════════════════════╗"
    print_message $RED "║    Cleanup Completed with Errors       ║"
    print_message $RED "╚════════════════════════════════════════╝"
    print_message $YELLOW "Some resources could not be deleted automatically."
    print_message $YELLOW "Please check the AWS console for remaining resources:"
    print_message $YELLOW "  - CloudFormation stacks in DELETE_FAILED state"
    print_message $YELLOW "  - ECR repositories with images"
    print_message $YELLOW "  - S3 buckets with versioning/policies"
    print_message $YELLOW "  - WAF WebACLs still associated with distributions"
    echo
    print_message $YELLOW "You may need to manually delete these resources before running a fresh deployment."
fi