#!/bin/bash
set -e

# Process parameter templates and replace placeholders
# Usage: process-parameters.sh <template-file> <output-file>

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Check arguments
if [ $# -ne 2 ]; then
    print_message $RED "Error: Invalid number of arguments"
    echo "Usage: $0 <template-file> <output-file>"
    exit 1
fi

TEMPLATE_FILE=$1
OUTPUT_FILE=$2

# Check if template file exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    print_message $RED "Error: Template file not found: $TEMPLATE_FILE"
    exit 1
fi

# Get AWS account ID
print_message $YELLOW "Getting AWS account ID..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    print_message $RED "Error: Failed to get AWS account ID"
    exit 1
fi
print_message $GREEN "AWS Account ID: $AWS_ACCOUNT_ID"

# Process template
print_message $YELLOW "Processing template: $TEMPLATE_FILE"

# Replace placeholders
# Using sed with different delimiter to handle potential slashes in values
sed -e "s|{{ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{WAF_ARN}}||g" \
    "$TEMPLATE_FILE" > "$OUTPUT_FILE"

# Validate the output is valid JSON
if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
    print_message $RED "Error: Generated file is not valid JSON"
    rm -f "$OUTPUT_FILE"
    exit 1
fi

print_message $GREEN "✓ Successfully processed parameter template"
print_message $GREEN "  Output: $OUTPUT_FILE"