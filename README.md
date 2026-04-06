# Neo Fusion DevOps Practical Test

## 📌 Submission Overview

This repository contains the complete solution for the **Intermediate DevOps For AWS** practical test. All tasks (0–5) are implemented with a strong focus on **AWS Free Tier compliance**, security best practices, and operational simplicity.

- **Task 0:** Git version control with semantic commits
- **Task 1:** Architecture diagram (draw.io) + explanation
- **Task 2:** Terraform IaC (VPC, EC2, RDS, S3, IAM, CloudFront, Auto Scaling)
- **Task 3:** Deployment script (embedded in user_data) – installs .NET runtime, pulls artifact from S3, starts systemd service
- **Task 4:** CloudWatch monitoring & logging (basic metrics + application logs)
- **Task 5:** CI/CD pipeline concept (GitHub Actions + OIDC)

All resources stay within **AWS Free Tier** limits.

---

## 🧭 Step 0: Version Control

The repository was initialized with meaningful commits following Git best practices.

```bash
# Initialize repository
git init

# Add all files
git add .

# First commit
git commit -m "feat: initial commit with architecture diagram and bootstrap script"

# Add remote and push
git remote add origin https://github.com/lukmanulhakimdevops/devops_practical_test_neo-fusion.git
git branch -M main
git push -u origin main
```

Every subsequent task was committed with descriptive messages (e.g., `feat: add Terraform infrastructure code`, `feat: add deployment script`, `docs: update README with monitoring setup`).

---

## 🏗️ Step 1: AWS Architecture (Free Tier Optimized)

### Architecture Diagram

![Architecture Diagram](./https://github.com/lukmanulhakimdevops/devops_practical_test_neo-fusion/blob/main/diagram/lukmanulhakim_devops_practical_test_neo-fusion.drawio.png)

*Source file: `https://github.com/lukmanulhakimdevops/devops_practical_test_neo-fusion/blob/main/diagram/lukmanulhakim_devops_practical_test_neo-fusion.drawio`*

### Components & Rationale

| Component | Resource | Purpose | Free Tier Status |
|-----------|----------|---------|------------------|
| Network | VPC (10.0.0.0/16) | Isolated network | Free |
| Subnets | Public + Private (2 AZs) | EC2 in public, RDS in private | Free |
| Internet Gateway | IGW | Internet access for public subnet | Free |
| Security Groups | App-SG, DB-SG | Firewall rules (HTTP/HTTPS/SSH, MySQL only from App-SG) | Free |
| Compute | EC2 t2.micro (Ubuntu) + Auto Scaling Group (min=1) | Hosts DotNet Web API | 750h/month |
| Database | RDS MySQL db.t3.micro | Application database | 750h/month |
| Storage | S3 bucket (<5GB) | Artifact storage (binaries, SQL) | 5GB free |
| CDN | CloudFront | Caching & HTTPS (optional) | 1TB/month free |
| Monitoring | CloudWatch | Basic metrics + logs | 5GB logs free |
| IAM | Roles for EC2 (S3 read) & GitHub Actions (OIDC) | Least privilege access | Free |

### Why This Architecture?

- **FinOps First** – No NAT Gateway, no ALB, no unnecessary services. All resources are within free tier caps.
- **Security** – RDS in private subnet, DB-SG only accepts MySQL from App-SG. SSH restricted (can be further limited to admin IP).
- **Resilience** – Auto Scaling Group with min=1 ensures automatic recovery if EC2 fails.
- **Observability** – CloudWatch basic monitoring + application logs (sent to CloudWatch Logs).

---

## ⚙️ Step 2: Infrastructure as Code (Terraform)

The Terraform configuration (`terraform/main.tf`) provisions:

- VPC, public & private subnets, Internet Gateway, route tables
- Security groups (`app-sg`, `db-sg`)
- S3 bucket for artifacts (public access blocked)
- IAM roles: EC2 role to read S3, GitHub Actions OIDC role to write S3
- Launch template + Auto Scaling Group (min=1, max=1)
- Elastic IP (attached to the instance from ASG)
- CloudFront distribution (CDN for caching)
- RDS MySQL (db.t3.micro, 20GB, backup retention 7 days)

**Key features:**
- User data script embedded (full deployment automation – no separate `deploy.sh` file needed)
- Database credentials passed via Terraform variables (no hardcoding, marked `sensitive`)
- OIDC provider for GitHub Actions (secure, no long‑lived AWS keys)

### Deploy Infrastructure

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

Outputs:
- `ec2_public_ip` – Elastic IP of the web server
- `cloudfront_domain` – CloudFront domain name
- `rds_endpoint` – RDS endpoint (private)
- `s3_bucket_name` – Name of the S3 bucket
- `github_actions_role_arn` – IAM role ARN for GitHub Actions OIDC

---

## 📜 Step 3: Deployment Script

The deployment logic is **embedded in the EC2 user data**. No separate `deploy.sh` file is needed. The script does:

1. Wait for cloud-init and disable interactive needrestart prompts.
2. Update system packages.
3. Install dependencies: `wget`, `unzip`, `awscli`, `mysql-client`.
4. Install .NET 6 runtime (using Microsoft repository).
5. Download the application artifact from S3 (`artifacts/latest/webapp-binaries.7z`).
6. Create `/var/www/webapp` and extract the 7z archive.
7. Create systemd service file (`/etc/systemd/system/webapp.service`).
8. Start the service and enable it on boot.
9. Perform a health check (curl to `http://localhost:80/swagger/index.html`).

The script is part of the Terraform `user_data` block and runs automatically when the EC2 instance launches.

---

## 📊 Step 4: Monitoring and Logging

### CloudWatch Configuration

- **EC2 Basic Monitoring** – Enabled by default (5‑minute intervals, free).
- **RDS Basic Monitoring** – Enabled by default (free).
- **CloudWatch Logs** – The application logs are sent to `/var/log/webapp.log`. To centralise them, the CloudWatch agent can be installed (optional). However, for the scope of this test, basic monitoring and manual log inspection via SSH are sufficient.

To set up CloudWatch Logs, you can run the following on the EC2 instance (or include it in user data):

```bash
# Install CloudWatch agent
sudo apt-get update && sudo apt-get install -y amazon-cloudwatch-agent

# Create configuration (logs from /var/log/webapp.log)
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/webapp.log",
            "log_group_name": "/aws/ec2/webapp",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 7
          }
        ]
      }
    }
  }
}
EOF

# Start agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
```

### Alarms (Free Tier – 10 alarms free)

Example alarm for high CPU (you can create via CLI or Console):

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "high-cpu-ec2" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold
```

---

## 🚀 Step 5: CI/CD Pipeline (Conceptual)

### Pipeline Overview

```
Code Push → GitHub → GitHub Actions → Build → Test → Package → Upload to S3 → Deploy to EC2
```

### Tools & Justification

| Stage | Tool | Why |
|-------|------|-----|
| Version Control | GitHub | Free, integrated with Actions |
| CI/CD Engine | GitHub Actions | 2000 free minutes/month, no extra infra |
| Build & Test | `dotnet build`, `dotnet test` | Native .NET CLI |
| Artifact Storage | AWS S3 | Free tier 5GB, immutable |
| Deployment | SSH + systemctl | Simple, no extra agents |
| Authentication | AWS IAM OIDC | No long‑lived keys, secure |

### Pipeline Steps (as described in `.github/workflows/ci-cd.yml`)

1. **Trigger** – Push to `main` branch.
2. **Checkout** – Clone repository.
3. **Extract source** – Unpack `SOURCE TodoWebAPI.7z`.
4. **Build & publish** – `dotnet restore`, `build`, `publish`.
5. **Package** – Create `webapp-binaries.7z` from publish output.
6. **Configure AWS Credentials** – Using OIDC role (role ARN stored as secret `AWS_OIDC_ROLE_ARN`).
7. **Upload to S3** – Upload artifact to `s3://<bucket>/artifacts/latest/`.
8. **Deploy to EC2** – SSH into EC2, download artifact, extract, restart service.

### Rollback Strategy

- Previous versions are stored in S3 with timestamps.
- To rollback, manually copy an older `webapp-binaries.7z` to `artifacts/latest/` and re‑run the deployment step.

### Security

- OIDC authentication (no AWS keys stored in GitHub).
- SSH private key stored as GitHub secret.
- EC2 instance has an IAM role with **read‑only** access to the S3 bucket.

---

## ✅ Free Tier Compliance Summary

| Service | Free Tier Limit | Our Usage | Status |
|---------|----------------|-----------|--------|
| EC2 t2.micro | 750 hours/month | 720 hours | ✅ |
| RDS db.t3.micro | 750 hours/month | 720 hours | ✅ |
| EBS gp3 | 30 GB | 20 GB | ✅ |
| RDS Storage | 20 GB | 20 GB | ✅ |
| S3 Standard | 5 GB | ~100 MB | ✅ |
| CloudFront | 1 TB/month | negligible | ✅ |
| CloudWatch Logs | 5 GB ingestion | ~50 MB | ✅ |
| IAM & VPC | Always free | – | ✅ |

**Estimated monthly cost: $0.00**

---

## 📸 Screenshots

Place your AWS console screenshots in the `screenshots/` folder and reference them here:

- [EC2 Instance Running](./screenshots/ec2-running.png)
- [RDS Available](./screenshots/rds-available.png)
- [S3 Artifacts](./screenshots/s3-artifacts.png)
- [Security Groups (App-SG & DB-SG)](./screenshots/security-groups.png)
- [Swagger UI Accessible](./screenshots/swagger-ui.png)
- [CloudWatch Logs (optional)](./screenshots/cloudwatch-logs.png)
- [GitHub Actions Workflow (optional)](./screenshots/github-actions.png)

---

## 🛠️ How to Run the Complete Setup

1. **Clone this repository**
2. **Set environment variables** (replace with your actual values):
   ```bash
   export REPO="lukmanulhakimdevops/devops_practical_test_neo-fusion"
   export AWS_ACCESS_KEY_ID="AKIA..."
   export AWS_SECRET_ACCESS_KEY="..."
   export DB_NAME="todoapp"
   export DB_USERNAME="tempAdmin"
   export DB_PASSWORD='!tempAdmin954*'
   ```
3. **Run the bootstrap script** (automates everything: destroys old infra, installs tools, sets secrets, applies Terraform, uploads artifacts, adds SSH key):
   ```bash
   chmod +x scripts/bootstrap-all.sh
   ./scripts/bootstrap-all.sh
   ```
4. **After completion**, access your Swagger UI:
   - Via EC2 Elastic IP: `http://<ec2_public_ip>/swagger/index.html`
   - Via CloudFront: `https://<cloudfront_domain>/swagger/index.html`

---

## 📝 Author

Lukmanul Hakim – DevOps Engineer  
GitHub: [lukmanulhakimdevops](https://github.com/lukmanulhakimdevops)

---
*End of DevOps Practical Test Submission*
