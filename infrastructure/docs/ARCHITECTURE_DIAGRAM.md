# Strapi AWS High Availability Architecture Diagram

## Detailed Architecture Diagram

This diagram shows the complete high-availability architecture for Strapi on AWS.

```mermaid
graph TB
    subgraph "Internet Users"
        Users[Users Worldwide]
        Admins[Content Administrators]
        APIs[API Consumers]
    end
    
    subgraph "AWS Global Infrastructure"
        subgraph "CloudFront Edge Network"
            CF[CloudFront CDN<br/>400+ Global Edge Locations<br/>Caching & Compression]
            WAF_CF[WAF for CloudFront<br/>- DDoS Protection<br/>- Geo-blocking<br/>- Rate Limiting]
        end
    end
    
    subgraph "AWS Region: us-west-2"
        subgraph "VPC (10.0.0.0/16)"
            subgraph "Public Subnets"
                subgraph "us-west-2a"
                    ALB_AZ1[ALB Node<br/>Public Subnet 1<br/>10.0.1.0/24]
                    NAT1[NAT Gateway 1<br/>Elastic IP]
                end
                subgraph "us-west-2b"
                    ALB_AZ2[ALB Node<br/>Public Subnet 2<br/>10.0.2.0/24]
                    NAT2[NAT Gateway 2<br/>Elastic IP]
                end
                subgraph "us-west-2c"
                    ALB_AZ3[ALB Node<br/>Public Subnet 3<br/>10.0.3.0/24]
                end
                WAF_ALB[WAF for ALB<br/>- Admin IP Whitelist<br/>- SQL Injection Protection<br/>- XSS Protection]
            end
            
            subgraph "Private Subnets - Application Tier"
                subgraph "us-west-2a "
                    ECS1[ECS Fargate Task 1<br/>Strapi Container<br/>1 vCPU / 2GB RAM<br/>Private Subnet 1<br/>10.0.11.0/24]
                end
                subgraph "us-west-2b "
                    ECS2[ECS Fargate Task 2<br/>Strapi Container<br/>1 vCPU / 2GB RAM<br/>Private Subnet 2<br/>10.0.12.0/24]
                end
                subgraph "us-west-2c "
                    ECS3[ECS Fargate Task 3<br/>Strapi Container<br/>(Auto-scaled)<br/>Private Subnet 3<br/>10.0.13.0/24]
                end
                
                ASG[Auto Scaling Group<br/>Min: 2, Max: 10<br/>Target: 70% CPU]
            end
            
            subgraph "Database Subnets - Data Tier"
                subgraph "us-west-2a  "
                    RDS_Primary[(Aurora PostgreSQL<br/>Primary Writer<br/>db.t3.medium<br/>DB Subnet 1<br/>10.0.21.0/24)]
                end
                subgraph "us-west-2b  "
                    RDS_Standby[(Aurora PostgreSQL<br/>Standby Reader<br/>db.t3.medium<br/>DB Subnet 2<br/>10.0.22.0/24)]
                end
                
                RDS_Cluster[Aurora Cluster<br/>- Automated Backups (7 days)<br/>- Point-in-time Recovery<br/>- Encryption at Rest]
            end
            
            IGW[Internet Gateway]
            RTB_Public[Route Table - Public<br/>0.0.0.0/0 → IGW]
            RTB_Private1[Route Table - Private AZ1<br/>0.0.0.0/0 → NAT1]
            RTB_Private2[Route Table - Private AZ2<br/>0.0.0.0/0 → NAT2]
        end
        
        subgraph "AWS Managed Services"
            subgraph "Storage Services"
                S3_Media[S3 Bucket - Media<br/>- Versioning Enabled<br/>- Lifecycle Policies<br/>- CloudFront OAC]
                S3_Logs[S3 Bucket - Logs<br/>- ALB Access Logs<br/>- VPC Flow Logs<br/>- CloudFront Logs]
            end
            
            subgraph "Security & Secrets"
                SM[Secrets Manager<br/>- DB Password<br/>- App Keys<br/>- JWT Secrets<br/>Auto-rotation]
                SG_ALB[Security Group - ALB<br/>Inbound: 80, 443<br/>Outbound: 1337]
                SG_ECS[Security Group - ECS<br/>Inbound: 1337 from ALB<br/>Outbound: 443, 5432]
                SG_RDS[Security Group - RDS<br/>Inbound: 5432 from ECS<br/>Outbound: None]
            end
            
            subgraph "Container Services"
                ECR[ECR Registry<br/>Docker Images<br/>Vulnerability Scanning]
                ECS_Service[ECS Service<br/>- Rolling Updates<br/>- Health Checks<br/>- Service Discovery]
            end
            
            subgraph "Monitoring"
                CW[CloudWatch<br/>- Metrics & Alarms<br/>- Container Logs<br/>- RDS Performance]
                CW_Dashboard[CloudWatch Dashboard<br/>- Service Health<br/>- Performance Metrics<br/>- Cost Tracking]
            end
        end
    end
    
    %% User Flow
    Users -->|HTTPS| CF
    Admins -->|HTTPS/Admin| WAF_ALB
    APIs -->|HTTPS/API| CF
    
    %% CloudFront Flow
    CF --> WAF_CF
    WAF_CF -->|Origin Request| ALB_AZ1
    WAF_CF -->|Origin Request| ALB_AZ2
    WAF_CF -->|Origin Request| ALB_AZ3
    CF -->|Media Requests| S3_Media
    
    %% Load Balancer Flow
    WAF_ALB --> ALB_AZ1
    WAF_ALB --> ALB_AZ2
    WAF_ALB --> ALB_AZ3
    
    ALB_AZ1 -->|Target Group| ECS1
    ALB_AZ1 -->|Target Group| ECS2
    ALB_AZ1 -->|Target Group| ECS3
    ALB_AZ2 -->|Target Group| ECS1
    ALB_AZ2 -->|Target Group| ECS2
    ALB_AZ2 -->|Target Group| ECS3
    ALB_AZ3 -->|Target Group| ECS1
    ALB_AZ3 -->|Target Group| ECS2
    ALB_AZ3 -->|Target Group| ECS3
    
    %% Application Flow
    ECS1 -->|Read/Write| RDS_Primary
    ECS2 -->|Read/Write| RDS_Primary
    ECS3 -->|Read/Write| RDS_Primary
    ECS1 -->|Upload| S3_Media
    ECS2 -->|Upload| S3_Media
    ECS3 -->|Upload| S3_Media
    ECS1 -->|Secrets| SM
    ECS2 -->|Secrets| SM
    ECS3 -->|Secrets| SM
    ECS1 -->|Logs| CW
    ECS2 -->|Logs| CW
    ECS3 -->|Logs| CW
    ECS1 -->|Pull Image| ECR
    ECS2 -->|Pull Image| ECR
    ECS3 -->|Pull Image| ECR
    
    %% Database Flow
    RDS_Primary -.->|Sync Replication| RDS_Standby
    RDS_Primary --> RDS_Cluster
    RDS_Standby --> RDS_Cluster
    
    %% Internet Access
    ECS1 -->|Outbound| NAT1
    ECS2 -->|Outbound| NAT2
    NAT1 --> IGW
    NAT2 --> IGW
    
    %% Auto Scaling
    ASG -->|Manages| ECS1
    ASG -->|Manages| ECS2
    ASG -->|Manages| ECS3
    CW -->|Metrics| ASG
    
    %% Service Management
    ECS_Service -->|Controls| ECS1
    ECS_Service -->|Controls| ECS2
    ECS_Service -->|Controls| ECS3
    
    %% Logging
    ALB_AZ1 -->|Access Logs| S3_Logs
    ALB_AZ2 -->|Access Logs| S3_Logs
    ALB_AZ3 -->|Access Logs| S3_Logs
    CF -->|Access Logs| S3_Logs
    
    %% Styling
    classDef users fill:#4A90E2,stroke:#2E5C8A,stroke-width:2px,color:#fff
    classDef aws fill:#FF9900,stroke:#232F3E,stroke-width:2px,color:#232F3E
    classDef network fill:#7B68EE,stroke:#4B0082,stroke-width:2px,color:#fff
    classDef compute fill:#48C774,stroke:#257942,stroke-width:2px,color:#fff
    classDef database fill:#FF6B6B,stroke:#C92A2A,stroke-width:2px,color:#fff
    classDef storage fill:#4ECDC4,stroke:#1A8B84,stroke-width:2px,color:#fff
    classDef security fill:#FFD93D,stroke:#F39C12,stroke-width:2px,color:#232F3E
    
    class Users,Admins,APIs users
    class CF,WAF_CF,WAF_ALB,ALB_AZ1,ALB_AZ2,ALB_AZ3,IGW,NAT1,NAT2 network
    class ECS1,ECS2,ECS3,ASG,ECS_Service,ECR compute
    class RDS_Primary,RDS_Standby,RDS_Cluster database
    class S3_Media,S3_Logs storage
    class SM,SG_ALB,SG_ECS,SG_RDS security
    class CW,CW_Dashboard aws
```

## High Availability Features Highlighted

### 1. **Multi-AZ Application Deployment**
- ECS tasks distributed across 3 availability zones
- Minimum 2 tasks always running
- Auto-scaling based on CPU/memory metrics

### 2. **Multi-AZ Database with Automatic Failover**
- Aurora primary in AZ1 with synchronous standby in AZ2
- Automatic failover in <30 seconds
- No data loss during failover

### 3. **Redundant Network Paths**
- Multiple ALB nodes across AZs
- Multiple NAT Gateways for outbound traffic
- No single point of failure in network path

### 4. **Global Content Delivery**
- CloudFront serves cached content even if origin fails
- S3 serves media files with 99.999999999% durability
- Automatic failover between origins

### 5. **Security Layers**
- WAF at CloudFront edge (global protection)
- WAF at ALB (regional protection)
- Private subnets isolate compute resources
- Security groups provide defense in depth

## Failure Scenarios Handled

### Scenario 1: Single Container Failure
- ALB health checks detect failure
- Traffic routed to healthy containers
- ECS service launches replacement
- **Impact**: Zero downtime

### Scenario 2: Availability Zone Failure
- ALB stops routing to failed AZ
- Remaining AZs handle all traffic
- Auto-scaling launches more containers
- Database continues from standby
- **Impact**: Zero downtime

### Scenario 3: Database Primary Failure
- Aurora detects primary failure
- Standby promoted to primary in <30s
- Applications reconnect automatically
- **Impact**: <30 seconds of write unavailability

### Scenario 4: Region-wide S3 Outage
- CloudFront serves cached media
- New uploads may fail temporarily
- Application remains functional
- **Impact**: Limited to new media uploads

## Scalability Metrics

- **Horizontal Scaling**: 2-10 containers (configurable)
- **Database Scaling**: Up to 15 read replicas
- **CDN Capacity**: Unlimited
- **Storage Capacity**: Unlimited (S3)
- **Network Throughput**: 10 Gbps per AZ