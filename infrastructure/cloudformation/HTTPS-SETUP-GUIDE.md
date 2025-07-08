# HTTPS Setup Guide for Strapi on AWS

This guide covers all options for enabling HTTPS on your Strapi deployment.

## Current Setup

- ALB configured to support both HTTP and HTTPS
- Automatically uses HTTPS when certificate is provided
- HTTP redirects to HTTPS when certificate is present

## Option 1: Domain in Same AWS Account

### Prerequisites
- Domain registered in Route53 or transferred to Route53
- Access to AWS account with domain

### Steps

1. **Request ACM Certificate**
```bash
# Request certificate with DNS validation
CERT_ARN=$(aws acm request-certificate \
  --domain-name "yourdomain.com" \
  --subject-alternative-names "*.yourdomain.com" \
  --validation-method DNS \
  --region us-west-2 \
  --query 'CertificateArn' \
  --output text)

echo "Certificate ARN: $CERT_ARN"
```

2. **Validate Certificate** (automatic with Route53)
```bash
# Wait for validation (usually automatic with Route53)
aws acm wait certificate-validated \
  --certificate-arn $CERT_ARN \
  --region us-west-2
```

3. **Update ECS Stack**
```bash
aws cloudformation update-stack \
  --stack-name strapi-production-ecs \
  --use-previous-template \
  --parameters \
    ParameterKey=CertificateArn,ParameterValue="$CERT_ARN" \
    ParameterKey=ProjectName,UsePreviousValue=true \
    ParameterKey=Environment,UsePreviousValue=true \
    ParameterKey=VPCStackName,UsePreviousValue=true \
    ParameterKey=RDSStackName,UsePreviousValue=true \
    ParameterKey=SecretsStackName,UsePreviousValue=true \
    ParameterKey=TaskCPU,UsePreviousValue=true \
    ParameterKey=TaskMemory,UsePreviousValue=true \
    ParameterKey=DesiredCount,UsePreviousValue=true \
    ParameterKey=MinCapacity,UsePreviousValue=true \
    ParameterKey=MaxCapacity,UsePreviousValue=true \
    ParameterKey=WAFWebACLArn,UsePreviousValue=true \
    ParameterKey=ImageUri,UsePreviousValue=true \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-west-2
```

4. **Create DNS Record**
```bash
# Get ALB DNS
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name strapi-production-ecs \
  --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerDNS`].OutputValue' \
  --output text \
  --region us-west-2)

# Create Route53 record pointing to ALB
# Use Route53 console or CLI to create CNAME/Alias record
```

## Option 2: Domain in Different AWS Account

### Use the provided script:

1. **Edit the script**
```bash
cd /home/ubuntu/dev/wrksp/strapi/strapi/infrastructure/cloudformation
nano setup-https-now.sh

# Update these lines:
SUBDOMAIN="api"
DOMAIN="yourdomain.com"
```

2. **Run the script**
```bash
./setup-https-now.sh
```

3. **Follow the prompts**
   - Add validation CNAME in your domain account
   - Wait for validation
   - Add final CNAME pointing to ALB

## Option 3: Using External Domain Registrar

### If your domain is with GoDaddy, Namecheap, etc:

1. **Request Certificate in AWS**
```bash
# Same as Option 1, step 1
```

2. **Get Validation Records**
```bash
aws acm describe-certificate \
  --certificate-arn $CERT_ARN \
  --region us-west-2 \
  --query 'Certificate.DomainValidationOptions[*].ResourceRecord'
```

3. **Add CNAME in Domain Registrar**
   - Log into your registrar (GoDaddy, Namecheap, etc)
   - Add the validation CNAME record
   - Wait for validation (5-30 minutes)

4. **Update Stack and Point Domain**
   - Same as Option 1, steps 3-4

## Option 4: Using CloudFront (Alternative)

If you want to use CloudFront's certificate:

1. **Update CloudFront Distribution**
   - Add ALB as additional origin
   - Create behaviors for `/api/*` and `/admin/*`
   - Use CloudFront's default certificate

2. **Access via CloudFront URL**
   - `https://your-cloudfront-id.cloudfront.net`

## Testing HTTPS

After setup:

```bash
# Test HTTPS endpoint
curl -I https://yourdomain.com/_health

# Test redirect (should return 301)
curl -I http://yourdomain.com

# Test with browser
# https://yourdomain.com/admin
```

## Troubleshooting

### Certificate Not Validating
- Check DNS propagation: `nslookup _validation.yourdomain.com`
- Ensure CNAME is exact (including trailing dot if shown)
- Wait up to 30 minutes

### HTTPS Not Working
- Check certificate is attached to ALB listener
- Verify security group allows port 443
- Check WAF rules aren't blocking HTTPS

### Browser Warnings
- Ensure using correct domain (not ALB DNS)
- Check certificate details in browser
- Clear browser cache

## Important Notes

1. **Certificate Auto-Renewal**: ACM certificates renew automatically
2. **Keep Validation Records**: Don't delete validation CNAMEs
3. **Security**: Once HTTPS is enabled, consider HSTS headers
4. **Costs**: ACM certificates are free, but data transfer applies

## Quick Reference

- **Check Certificate Status**:
  ```bash
  aws acm describe-certificate --certificate-arn $CERT_ARN
  ```

- **List Certificates**:
  ```bash
  aws acm list-certificates --region us-west-2
  ```

- **Check ALB Listeners**:
  ```bash
  aws elbv2 describe-listeners \
    --load-balancer-arn $(aws elbv2 describe-load-balancers \
      --names strapi-production-alb \
      --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text)
  ```