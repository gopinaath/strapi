# WAF IP Whitelist Management

This document explains how to manage IP whitelisting for the Strapi admin panel.

## Overview

The Strapi deployment uses AWS WAF to restrict access to the `/admin` paths. Only whitelisted IP addresses can access the admin panel.

## Configuration

IP addresses are configured in the `.env` file:

```bash
# Edit the .env file in the infrastructure directory
# Add or update the ADMIN_IPS variable with your IP
ADMIN_IPS=YOUR_IP_HERE/32
```

**Note**: 
- The `.env` file is git-ignored and should NOT be committed
- Always include `/32` for single IP addresses
- For IP ranges, use CIDR notation (e.g., `10.0.0.0/24`)

## Initial Deployment

When deploying the infrastructure:

```bash
# Ensure .env file exists with ADMIN_IP set
cd ../scripts
./deploy-three-phase.sh --project-name strapi --environment production --region us-west-2
```

The deployment script will:
1. Load the IP from `.env` file
2. Configure both Regional WAF (for ALB) and CloudFront WAF
3. Restrict `/admin` access to the whitelisted IP

## Updating IP Whitelist

To update the IP whitelist after deployment:

### Manual Update via AWS Console
```bash
# 1. Find the IP Set ID from the CloudFormation stack outputs
aws cloudformation describe-stacks \
  --stack-name strapi-production-waf-alb \
  --query 'Stacks[0].Outputs[?OutputKey==`AdminIPSetId`].OutputValue' \
  --output text

# 2. Update the IP Set with new addresses
aws wafv2 update-ip-set \
  --name strapi-production-admin-ips \
  --scope REGIONAL \
  --id <IP_SET_ID> \
  --addresses "192.168.1.100/32" "10.0.0.0/24" \
  --region us-west-2
```

### Update via CloudFormation
```bash
# Edit the parameters file to update AdminWhitelistIP
vim ../parameters/us-west-2-production.json

# Redeploy the WAF stack
cd ../scripts
./lib/deploy-enhanced.sh --stack-name strapi-production --params-file ../parameters/us-west-2-production.json
```

## Multiple IPs

To whitelist multiple IPs, you need to:
1. Edit the WAF templates (`05a-waf-regional.yaml` and `05b-waf-cloudfront.yaml`)
2. Add additional IPs to the `Addresses` array in the IP Set resources
3. Redeploy the WAF stacks

Example:
```yaml
Addresses:
  - !Ref AdminWhitelistIP
  - "192.168.1.100/32"
  - "10.0.0.0/24"
```

## Verification

After updating, verify the whitelist is working:

1. **From whitelisted IP**: Navigate to `http://ALB_DNS/admin` - should see login page
2. **From non-whitelisted IP**: Navigate to `http://ALB_DNS/admin` - should see 403 Forbidden

## Troubleshooting

### IP Not Working
- Ensure you're using your public IP (check at whatismyip.com)
- Include `/32` suffix for single IPs
- Wait 2-3 minutes for WAF changes to propagate

### Finding Your IP
```bash
# Get your current public IP
curl -s https://api.ipify.org
```

### Checking Current Whitelist
```bash
# Check Regional WAF IP Set
aws wafv2 get-ip-set \
  --name strapi-production-admin-ips \
  --scope REGIONAL \
  --id <IP_SET_ID> \
  --region us-west-2

# Check CloudFront WAF IP Set  
aws wafv2 get-ip-set \
  --name strapi-production-cloudfront-admin-ips \
  --scope CLOUDFRONT \
  --id <IP_SET_ID> \
  --region us-east-1
```

## Security Best Practices

1. **Never commit .env**: The file is git-ignored for security
2. **Use specific IPs**: Avoid broad IP ranges when possible
3. **Regular reviews**: Periodically review and remove old IPs
4. **VPN consideration**: If using VPN, whitelist the VPN exit IP
5. **Temporary access**: Remove temporary IPs after use