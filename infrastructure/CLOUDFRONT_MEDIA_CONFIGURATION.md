# CloudFront Media Configuration for Strapi AWS Deployment

This guide explains how to configure Strapi to use CloudFront CDN URLs for media files instead of serving them through the Application Load Balancer.

## Overview

By default, Strapi generates media URLs using the main application URL (ALB endpoint). This configuration enables Strapi to use CloudFront URLs for all uploaded media files, providing:

- Better performance through global CDN edge locations
- Reduced load on the Application Load Balancer
- Lower data transfer costs
- Improved user experience with faster media loading

## Implementation Steps

### Step 1: Update ECS Task Definition

Add the CloudFront URL as an environment variable in the ECS task definition.

**File**: `infrastructure/cloudformation/03-ecs.yaml`

**Location**: Around line 241, after the `AWS_BUCKET_NAME` environment variable

```yaml
- Name: AWS_BUCKET_NAME
  Value:
    Fn::ImportValue: !Sub ${ProjectName}-${Environment}-MediaBucketName
# Add this new environment variable
- Name: CDN_URL
  Value:
    Fn::ImportValue: !Sub ${ProjectName}-${Environment}-CloudFrontURL
```

### Step 2: Update S3 Upload Provider Configuration

Configure the S3 upload provider to use the CloudFront URL as the base URL for media files.

**File**: `examples/getstarted/config/env/production/plugins.js`

**Current Configuration**:
```javascript
module.exports = ({ env }) => ({
  // Inherit from base production config
  ...require('../../plugins.production')(),
  
  // Add S3 upload configuration if AWS credentials are provided
  ...(env('AWS_BUCKET_NAME') ? {
    upload: {
      config: {
        provider: 'aws-s3',
        providerOptions: {
          accessKeyId: env('AWS_ACCESS_KEY_ID'),
          secretAccessKey: env('AWS_ACCESS_SECRET'),
          region: env('AWS_REGION'),
          params: {
            Bucket: env('AWS_BUCKET_NAME'),
          },
        },
        actionOptions: {
          upload: {},
          uploadStream: {},
          delete: {},
        },
      },
    },
  } : {}),
});
```

**Updated Configuration**:
```javascript
module.exports = ({ env }) => ({
  // Inherit from base production config
  ...require('../../plugins.production')(),
  
  // Add S3 upload configuration if AWS credentials are provided
  ...(env('AWS_BUCKET_NAME') ? {
    upload: {
      config: {
        provider: 'aws-s3',
        providerOptions: {
          baseUrl: env('CDN_URL'), // Add this line - CloudFront URL for media files
          accessKeyId: env('AWS_ACCESS_KEY_ID'),
          secretAccessKey: env('AWS_ACCESS_SECRET'),
          region: env('AWS_REGION'),
          params: {
            Bucket: env('AWS_BUCKET_NAME'),
          },
        },
        actionOptions: {
          upload: {},
          uploadStream: {},
          delete: {},
        },
      },
    },
  } : {}),
});
```

### Step 3: (Optional) Update Content Security Policy

If you have strict Content Security Policy settings, you may need to allow the CloudFront domain for media sources.

**File**: `examples/getstarted/config/env/production/middlewares.js`

Create this file if it doesn't exist:

```javascript
module.exports = ({ env }) => [
  'strapi::errors',
  'strapi::security',
  'strapi::cors',
  'strapi::poweredBy',
  'strapi::logger',
  'strapi::query',
  'strapi::body',
  'strapi::session',
  'strapi::favicon',
  'strapi::public',
  {
    name: 'strapi::security',
    config: {
      contentSecurityPolicy: {
        useDefaults: true,
        directives: {
          'connect-src': ["'self'", 'https:'],
          'img-src': ["'self'", 'data:', 'blob:', env('CDN_URL')],
          'media-src': ["'self'", 'data:', 'blob:', env('CDN_URL')],
          upgradeInsecureRequests: null,
        },
      },
    },
  },
];
```

## How It Works

1. **Upload Process**: When files are uploaded, they are still sent directly to S3 through Strapi
2. **URL Generation**: The S3 provider uses the `baseUrl` to construct public URLs
3. **Media Access**: When media URLs are requested, they are served through CloudFront

### URL Format Examples

**Before Configuration**:
```
http://strapi-production-alb-12345678.us-west-2.elb.amazonaws.com/uploads/thumbnail_image_a1b2c3.jpg
```

**After Configuration**:
```
https://d1234567890.cloudfront.net/uploads/thumbnail_image_a1b2c3.jpg
```

## Deployment Process

1. **Update CloudFormation Templates**: Make the changes to `03-ecs.yaml`
2. **Update Application Configuration**: Make the changes to `plugins.js` (and optionally `middlewares.js`)
3. **Commit Changes**:
   ```bash
   git add infrastructure/cloudformation/03-ecs.yaml
   git add examples/getstarted/config/env/production/plugins.js
   git add examples/getstarted/config/env/production/middlewares.js  # if created
   git commit -m "feat: Configure CloudFront CDN for media files"
   ```
4. **Deploy Updates**:
   ```bash
   cd infrastructure/scripts
   ./deploy-three-phase.sh --skip-phase1 --skip-phase2
   ```

This will rebuild the Docker image with the new configuration and update the ECS service.

## Verification

After deployment, verify the configuration:

1. **Upload a Test Image**: Use the Strapi admin panel to upload an image
2. **Check the URL**: Right-click the image and copy the image address
3. **Verify CloudFront Domain**: The URL should start with your CloudFront distribution domain

### Using the API

```bash
# Upload an image (requires authentication)
curl -X POST http://your-alb-url/api/upload \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -F "files=@test-image.jpg"

# Response should include CloudFront URL:
# {
#   "url": "https://d1234567890.cloudfront.net/uploads/test_image_abc123.jpg"
# }
```

## Rollback

To rollback this change:

1. Remove the `baseUrl: env('CDN_URL'),` line from `plugins.js`
2. Remove the `CDN_URL` environment variable from `03-ecs.yaml`
3. Redeploy using the three-phase script

## Benefits

1. **Performance**: Global CDN edge locations serve media files with low latency
2. **Scalability**: CloudFront handles media traffic, reducing load on ECS tasks
3. **Cost**: CloudFront data transfer is typically cheaper than ALB data transfer
4. **Caching**: Static media files are cached at edge locations
5. **Security**: CloudFront provides additional DDoS protection

## Troubleshooting

### Media URLs Still Using ALB

1. **Check Environment Variable**: Ensure `CDN_URL` is set in ECS task definition
2. **Verify Export**: Check that CloudFormation exports `CloudFrontURL` correctly
3. **Restart Service**: Force a new deployment of the ECS service

### CORS Issues

If you encounter CORS errors, ensure CloudFront is configured to forward appropriate headers:
- The CloudFormation template should already handle this in `04-s3-cloudfront.yaml`

### Images Not Loading

1. **Check S3 Bucket Policy**: Ensure CloudFront can access the S3 bucket
2. **Verify Origin Path**: CloudFront should be configured with the correct origin
3. **Cache Invalidation**: May need to invalidate CloudFront cache for existing files

## Notes

- This configuration only affects newly generated URLs
- Existing media URLs in the database will continue using the old format
- The change is backward compatible - if `CDN_URL` is not set, it falls back to default behavior
- No upstream Strapi code is modified - all changes are in deployment-specific files