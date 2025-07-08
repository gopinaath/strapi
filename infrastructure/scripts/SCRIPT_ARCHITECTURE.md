# Script Architecture

## Simplified Structure

After refactoring, the script architecture is now much simpler and clearer:

```
infrastructure/scripts/
│
├── 🎯 Primary User Scripts (What you use)
│   ├── deploy-three-phase.sh      # Complete deployment
│   ├── deploy-update-service.sh   # Code updates only
│   └── cleanup-strapi.sh          # Remove everything
│
├── 🔧 Utility Scripts (Called by primary scripts)
│   ├── build-and-push.sh          # Docker operations
│   ├── check-prerequisites.sh     # Environment validation
│   └── list-strapi-stacks.sh      # List stacks (optional utility)
│
└── 📁 lib/ (Internal only - don't call directly)
    └── deploy-enhanced.sh         # CloudFormation engine
```

## Script Dependencies

```
User Entry Points
│
├── deploy-three-phase.sh
│   ├── check-prerequisites.sh (once, exports STRAPI_PREREQ_CHECKED)
│   ├── Phase 1: WAF deployment (integrated, no external script)
│   ├── Phase 2: lib/deploy-enhanced.sh (skips prereq check)
│   └── Phase 3: build-and-push.sh → Updates with lib/deploy-enhanced.sh
│
├── deploy-update-service.sh
│   ├── check-prerequisites.sh (once, exports STRAPI_PREREQ_CHECKED)
│   └── build-and-push.sh (skips prereq check)
│
└── cleanup-strapi.sh (standalone, no dependencies)
```

## Key Improvements Made

### 1. Reduced Entry Points
- **Before**: 5 ways to deploy (confusing!)
- **After**: 2 clear options (deploy new vs update existing)

### 2. Eliminated Redundancy
- **Merged** WAF deployment logic directly into `deploy-three-phase.sh` (removed separate deploy-with-waf.sh)
- **Added** `STRAPI_PREREQ_CHECKED` environment variable to skip redundant checks
- **Moved** internal scripts to `lib/` directory

### 3. Clearer User Experience
- Only 3 scripts users need to know about
- Clear naming: what each script does is obvious
- Better documentation with examples

## Usage Flow

### Initial Deployment
```bash
deploy-three-phase.sh
    ↓
✓ Check prerequisites (once)
    ↓
Phase 1: Deploy WAF in us-east-1
    ↓
Phase 2: Deploy infrastructure
    ↓
Phase 3: Build & deploy service
```

### Routine Updates
```bash
deploy-update-service.sh
    ↓
✓ Check prerequisites (once)
    ↓
Build Docker image
    ↓
Push to ECR
    ↓
Update ECS service
```

## Design Principles

1. **Single Responsibility**: Each script has one clear purpose
2. **No Redundancy**: Prerequisite checks run only once per execution
3. **Clear Hierarchy**: User scripts → Utility scripts → Internal lib
4. **Fail Fast**: Prerequisites checked before any operations
5. **Idempotent**: Scripts can be run multiple times safely