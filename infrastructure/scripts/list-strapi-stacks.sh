#!/bin/bash

# Script to list CloudFormation stacks containing "strapi" in us-east-1, us-east-2 and us-west-2

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== CloudFormation Stacks containing 'strapi' ==="
echo
echo -e "${YELLOW}Note: Showing all stack states including failed and in-progress${NC}"
echo

# Define regions to check
regions=("us-east-1" "us-east-2" "us-west-2")

# Loop through each region
for region in "${regions[@]}"; do
    echo "Region: $region"
    echo "----------------------------------------"
    
    # List stacks and filter for those containing "strapi" (case-insensitive)
    # Include all relevant statuses including failed and in-progress states
    stacks=$(aws cloudformation list-stacks \
        --region "$region" \
        --stack-status-filter \
            CREATE_COMPLETE \
            CREATE_IN_PROGRESS \
            CREATE_FAILED \
            DELETE_FAILED \
            DELETE_IN_PROGRESS \
            ROLLBACK_COMPLETE \
            ROLLBACK_FAILED \
            ROLLBACK_IN_PROGRESS \
            UPDATE_COMPLETE \
            UPDATE_IN_PROGRESS \
            UPDATE_ROLLBACK_COMPLETE \
            UPDATE_ROLLBACK_FAILED \
            UPDATE_ROLLBACK_IN_PROGRESS \
        --query 'StackSummaries[?contains(StackName, `strapi`) || contains(StackName, `Strapi`) || contains(StackName, `STRAPI`)].{Name:StackName,Status:StackStatus,Created:CreationTime}' \
        --output table 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        if [[ $stacks == *"Name"* ]]; then
            echo "$stacks"
        else
            echo "No stacks containing 'strapi' found in $region"
        fi
    else
        echo "Error: Unable to list stacks in $region. Check your AWS credentials and permissions."
    fi
    
    echo
done

echo "=== Summary Complete ==="
echo
echo -e "${YELLOW}Status Legend:${NC}"
echo -e "${GREEN}CREATE_COMPLETE / UPDATE_COMPLETE${NC} - Stack is active and healthy"
echo -e "${YELLOW}CREATE_IN_PROGRESS / UPDATE_IN_PROGRESS${NC} - Stack operation in progress"
echo -e "${RED}CREATE_FAILED / DELETE_FAILED / ROLLBACK_FAILED${NC} - Stack operation failed"
echo -e "${BLUE}DELETE_IN_PROGRESS${NC} - Stack is being deleted"
