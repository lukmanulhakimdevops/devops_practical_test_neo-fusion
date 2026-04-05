#!/bin/bash
set -e

echo "============================================="
echo "Neo Fusion DevOps - Full Free Tier Solution"
echo "EC2 runs pre-built binary; CI/CD builds from source"
echo "============================================="

# ------------------------------
# Environment variables (wajib)
# ------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
REPO="${REPO}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}"
DB_NAME="${DB_NAME}"
DB_USERNAME="${DB_USERNAME}"
DB_PASSWORD="${DB_PASSWORD}"

if [ -z "$REPO" ] || [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "[ERROR] Missing required env vars. Set: REPO, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
    exit 1
fi

if [ -z "$DB_NAME" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ]; then
    echo "[ERROR] Missing database credentials. Set: DB_NAME, DB_USERNAME, DB_PASSWORD"
    exit 1
fi

export TF_VAR_db_name="$DB_NAME"
export TF_VAR_db_username="$DB_USERNAME"
export TF_VAR_db_password="$DB_PASSWORD"
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_github_repo="$REPO"

echo "[INFO] Region: $AWS_REGION | Repo: $REPO | DB: $DB_NAME (credentials hidden)"

cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "$(basename "$PWD")" == "scripts" ]]; then cd ..; fi
echo "[DIR] Working dir: $PWD"

# ------------------------------
# Git helpers (force push)
# ------------------------------
ensure_git_repo() {
    if [ ! -d ".git" ]; then
        echo "[GIT] Initializing git repository..."
        git init
        git checkout -b main
        git add .
        git commit -m "Initial commit from bootstrap script"
        git remote add origin "https://github.com/$REPO.git"
        git push -u origin main --force
        echo "[GIT] Repository initialized and pushed to GitHub."
    else
        echo "[GIT] Git repository already exists."
        current_branch=$(git branch --show-current)
        if [ "$current_branch" != "main" ]; then
            git checkout main 2>/dev/null || git checkout -b main
        fi
        if ! git remote | grep -q origin; then
            git remote add origin "https://github.com/$REPO.git"
        fi
    fi
}

commit_and_push() {
    echo "[GIT] Committing and pushing changes..."
    git checkout main 2>/dev/null || git checkout -b main
    git add .
    if git diff --cached --quiet; then
        echo "[GIT] No changes to commit."
    else
        git commit -m "Update infrastructure and workflows"
        if ! git remote | grep -q origin; then
            git remote add origin "https://github.com/$REPO.git"
        fi
        git push -u origin main --force
        echo "[GIT] Changes pushed to GitHub."
    fi
}

# ------------------------------
destroy_existing() {
    if [ -f "terraform/terraform.tfstate" ]; then
        echo "[WARN] Destroying existing infrastructure..."
        cd terraform && terraform init && terraform destroy -auto-approve && cd ..
    fi
}

install_prereqs() {
    for cmd in terraform gh aws; do
        if ! command -v $cmd &>/dev/null; then
            case $cmd in
                terraform)
                    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
                    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
                    sudo apt update && sudo apt install -y terraform
                    ;;
                gh)
                    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list
                    sudo apt update && sudo apt install -y gh
                    ;;
                aws)
                    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
                    unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/awscliv2.zip /tmp/aws
                    ;;
            esac
        fi
    done
    sudo apt install -y jq unzip p7zip-full zip >/dev/null
    echo "[OK] Prerequisites ready."
}

github_setup() {
    if ! gh auth status &>/dev/null; then
        echo "[AUTH] Please run 'gh auth login' manually first."
        exit 1
    fi
    echo "[OK] GitHub authenticated."
}

configure_aws() {
    export AWS_DEFAULT_REGION=$AWS_REGION
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    aws configure set region "$AWS_REGION"
    echo "[OK] AWS CLI configured."
}

setup_github_secrets() {
    echo "[AUTH] Setting GitHub Secrets..."
    SSH_KEY_PATH="$HOME/.ssh/github-actions-deploy"
    [ ! -f "$SSH_KEY_PATH" ] && ssh-keygen -t ed25519 -C "github-actions-deploy" -f "$SSH_KEY_PATH" -N ""
    SSH_PRIVATE_KEY=$(cat "$SSH_KEY_PATH")
    SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")

    for secret in \
        "AWS_ACCESS_KEY_ID:$AWS_ACCESS_KEY_ID" \
        "AWS_SECRET_ACCESS_KEY:$AWS_SECRET_ACCESS_KEY" \
        "SSH_PRIVATE_KEY:$SSH_PRIVATE_KEY" \
        "DB_NAME:$DB_NAME" \
        "DB_USER:$DB_USERNAME" \
        "DB_PASSWORD:$DB_PASSWORD" \
        "EC2_HOST:0.0.0.0"; do
        name="${secret%%:*}"
        value="${secret#*:}"
        echo "$value" | gh secret set "$name" --repo "$REPO"
    done
    echo "[OK] GitHub Secrets configured."
}

create_github_workflow() {
    mkdir -p .github/workflows
    cat > .github/workflows/ci-cd.yml << 'EOF'
name: CI/CD Pipeline (Build from Source)

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  AWS_REGION: 'us-east-1'

permissions:
  id-token: write
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '6.0.x'

      - name: Install compression tools
        run: sudo apt-get update && sudo apt-get install -y p7zip-full

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Download source code from S3
        run: |
          aws s3 cp s3://${{ secrets.S3_BUCKET }}/sources/SOURCE_TodoWebAPI.7z .
          7z x SOURCE_TodoWebAPI.7z -oextracted_source

      - name: Build and Publish
        working-directory: ./extracted_source
        run: |
          dotnet restore
          dotnet build --no-restore --configuration Release
          dotnet publish --no-build --configuration Release --output ./publish_output

      - name: Package to 7z
        run: |
          cd extracted_source/publish_output
          7z a ../../webapp-binaries.7z *

      - name: Upload to S3 (overwrite latest)
        run: |
          aws s3 cp webapp-binaries.7z s3://${{ secrets.S3_BUCKET }}/artifacts/latest/webapp-binaries.7z

      - name: Deploy to EC2
        uses: appleboy/ssh-action@v1.0.0
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            set -e
            sudo systemctl stop webapp || true
            sudo mkdir -p /var/www/webapp
            aws s3 cp s3://${{ secrets.S3_BUCKET }}/artifacts/latest/webapp-binaries.7z /tmp/webapp.7z
            sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y
            MAIN_DLL=$(find /var/www/webapp -name "TodoWebAPI.dll" -o -name "WebApp.dll" | head -1)
            if [ -z "$MAIN_DLL" ]; then
              echo "ERROR: Main DLL not found"
              exit 1
            fi
            APP_DIR=$(dirname "$MAIN_DLL")
            # Update connection string using secrets
            RDS_HOST=$(echo "${{ secrets.RDS_ENDPOINT }}" | cut -d':' -f1)
            CONN_STRING="Server=$RDS_HOST;Database=${{ secrets.DB_NAME }};User=${{ secrets.DB_USER }};Password=${{ secrets.DB_PASSWORD }}"
            sudo sed -i "s|\"DefaultConnection\": \".*\"|\"DefaultConnection\": \"$CONN_STRING\"|" "$APP_DIR/appsettings.json" || true
            sudo tee /etc/systemd/system/webapp.service > /dev/null << 'SVC'
[Unit]
Description=DotNet Web API
After=network.target
[Service]
WorkingDirectory=APP_DIR_PLACEHOLDER
ExecStart=/usr/bin/dotnet MAIN_DLL_PLACEHOLDER
Restart=always
User=root
StandardOutput=append:/var/log/webapp.log
StandardError=append:/var/log/webapp.log
[Install]
WantedBy=multi-user.target
SVC
            sudo sed -i "s|APP_DIR_PLACEHOLDER|$APP_DIR|g" /etc/systemd/system/webapp.service
            sudo sed -i "s|MAIN_DLL_PLACEHOLDER|$MAIN_DLL|g" /etc/systemd/system/webapp.service
            sudo systemctl daemon-reload
            sudo systemctl enable webapp
            sudo systemctl start webapp
            sleep 5
            sudo systemctl status webapp --no-pager
EOF
    echo "[OK] GitHub Actions workflow created."
}

create_deploy_script() {
    # Optional fallback script, not used by default because user_data handles everything.
    mkdir -p scripts
    cat > scripts/deploy.sh << 'EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo -E apt-get update --fix-missing -y
sudo -E apt-get upgrade -y
sudo -E apt-get install -y wget awscli mysql-client p7zip-full

wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo -E apt-get update --fix-missing -y
sudo -E apt-get install -y dotnet-runtime-6.0

# Install CloudWatch agent
sudo wget -q https://s3.amazonaws.com/amazoncloudwatchagent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
sudo rm -f amazon-cloudwatch-agent.deb

sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'CWEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {"file_path": "/var/log/webapp.log", "log_group_name": "/aws/ec2/webapp", "log_stream_name": "{instance_id}", "retention_in_days": 7},
          {"file_path": "/var/log/user-data.log", "log_group_name": "/aws/ec2/user-data", "log_stream_name": "{instance_id}", "retention_in_days": 7}
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "cpu": {"measurement": ["cpu_usage_idle", "cpu_usage_user"], "metrics_collection_interval": 60},
      "mem": {"measurement": ["mem_used_percent"], "metrics_collection_interval": 60}
    }
  }
}
CWEOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

BUCKET_NAME="BUCKET_PLACEHOLDER"
aws s3 cp s3://$BUCKET_NAME/artifacts/latest/webapp-binaries.7z /tmp/webapp.7z
sudo mkdir -p /var/www/webapp
sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y
MAIN_DLL=$(find /var/www/webapp -name "TodoWebAPI.dll" -o -name "WebApp.dll" | head -1)
if [ -z "$MAIN_DLL" ]; then
    echo "ERROR: Main DLL not found"
    exit 1
fi
APP_DIR=$(dirname "$MAIN_DLL")
sudo tee /etc/systemd/system/webapp.service > /dev/null << 'SVC'
[Unit]
Description=DotNet Web API
After=network.target
[Service]
WorkingDirectory=APP_DIR_PLACEHOLDER
ExecStart=/usr/bin/dotnet MAIN_DLL_PLACEHOLDER
Restart=always
User=root
StandardOutput=append:/var/log/webapp.log
StandardError=append:/var/log/webapp.log
[Install]
WantedBy=multi-user.target
SVC
sudo sed -i "s|APP_DIR_PLACEHOLDER|$APP_DIR|g" /etc/systemd/system/webapp.service
sudo sed -i "s|MAIN_DLL_PLACEHOLDER|$MAIN_DLL|g" /etc/systemd/system/webapp.service
sudo systemctl daemon-reload
sudo systemctl enable webapp
sudo systemctl start webapp
EOF
    chmod +x scripts/deploy.sh
    echo "[OK] scripts/deploy.sh created (fallback)."
}

create_main_tf() {
    mkdir -p terraform
    cat > terraform/main.tf << 'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}
variable "key_name" {
  default = "devops-test-key"
}
variable "private_key_path" {
  default = "~/.ssh/devops-test-key.pem"
}
variable "github_repo" {}
variable "db_name" {}
variable "db_username" {
  sensitive = true
}
variable "db_password" {
  sensitive = true
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "devops-test-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}b"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "app-sg" }
}

resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "db-sg" }
}

resource "aws_s3_bucket" "app_bucket" {
  bucket_prefix = "devops-test-bucket-"
  force_destroy = true
  tags = { Name = "App Artifacts" }
}

resource "aws_s3_bucket_public_access_block" "app_bucket_block" {
  bucket = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

resource "aws_iam_role" "ec2_s3_role" {
  name_prefix = "ec2-s3-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_policy" {
  name_prefix = "ec2-s3-policy-"
  role = aws_iam_role.ec2_s3_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name_prefix = "ec2-profile-"
  role = aws_iam_role.ec2_s3_role.name
}

resource "aws_iam_role_policy_attachment" "ec2_cw_policy" {
  role       = aws_iam_role.ec2_s3_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "github_actions_role" {
  name_prefix = "github-actions-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_policy" {
  name_prefix = "github-actions-policy-"
  role = aws_iam_role.github_actions_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:PutObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

resource "aws_eip" "web_eip" {
  domain = "vpc"
  tags = { Name = "webapp-eip" }
}

locals {
  user_data = <<-USERDATA
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

exec > >(tee /var/log/user-data.log|logger -t user-data) 2>&1
echo "=== Bootstrapping EC2 instance ==="

sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo -E apt-get update --fix-missing -y
sudo -E apt-get upgrade -y
sudo -E apt-get install -y wget awscli mysql-client p7zip-full

wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo -E apt-get update --fix-missing -y
sudo -E apt-get install -y dotnet-runtime-6.0

# Install CloudWatch Agent
sudo wget -q https://s3.amazonaws.com/amazoncloudwatchagent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
sudo rm -f amazon-cloudwatch-agent.deb
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'CWEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {"file_path": "/var/log/webapp.log", "log_group_name": "/aws/ec2/webapp", "log_stream_name": "{instance_id}", "retention_in_days": 7},
          {"file_path": "/var/log/user-data.log", "log_group_name": "/aws/ec2/user-data", "log_stream_name": "{instance_id}", "retention_in_days": 7}
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "cpu": {"measurement": ["cpu_usage_idle", "cpu_usage_user"], "metrics_collection_interval": 60},
      "mem": {"measurement": ["mem_used_percent"], "metrics_collection_interval": 60}
    }
  }
}
CWEOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

BUCKET_NAME="${aws_s3_bucket.app_bucket.id}"
aws s3 cp s3://$BUCKET_NAME/artifacts/latest/webapp-binaries.7z /tmp/webapp.7z
sudo mkdir -p /var/www/webapp
sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y

MAIN_DLL=$(find /var/www/webapp -name "TodoWebAPI.dll" -o -name "WebApp.dll" | head -1)
if [ -z "$MAIN_DLL" ]; then
    echo "ERROR: Main DLL not found"
    exit 1
fi
APP_DIR=$(dirname "$MAIN_DLL")
echo "Found main DLL: $MAIN_DLL"

RDS_ENDPOINT="${aws_db_instance.mysql_db.endpoint}"
RDS_HOST=$(echo "$RDS_ENDPOINT" | cut -d':' -f1)
CONN_STRING="Server=$RDS_HOST;Database=${var.db_name};User=${var.db_username};Password=${var.db_password}"
sudo sed -i "s|\"DefaultConnection\": \".*\"|\"DefaultConnection\": \"$CONN_STRING\"|" "$APP_DIR/appsettings.json" || true

sudo tee /etc/systemd/system/webapp.service > /dev/null << 'SVC'
[Unit]
Description=DotNet Web API
After=network.target
[Service]
WorkingDirectory=APP_DIR_PLACEHOLDER
ExecStart=/usr/bin/dotnet MAIN_DLL_PLACEHOLDER
Restart=always
User=root
StandardOutput=append:/var/log/webapp.log
StandardError=append:/var/log/webapp.log
[Install]
WantedBy=multi-user.target
SVC
sudo sed -i "s|APP_DIR_PLACEHOLDER|$APP_DIR|g" /etc/systemd/system/webapp.service
sudo sed -i "s|MAIN_DLL_PLACEHOLDER|$MAIN_DLL|g" /etc/systemd/system/webapp.service

sudo systemctl daemon-reload
sudo systemctl enable webapp
sudo systemctl start webapp

sleep 10
if curl -sf http://localhost:80/swagger/index.html > /dev/null; then
    echo "Application started successfully."
else
    echo "WARNING: App not responding, check logs."
    sudo systemctl status webapp --no-pager || true
    sudo cat /var/log/webapp.log || true
fi
USERDATA
}

resource "aws_launch_template" "web_lt" {
  name_prefix   = "web-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = var.key_name
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  user_data = base64encode(local.user_data)
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  tags = { Name = "WebAppEC2" }
}

resource "aws_autoscaling_group" "web_asg" {
  name                = "web-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public.id]
  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "WebAppEC2"
    propagate_at_launch = true
  }
}

data "aws_instances" "web_instances" {
  instance_tags = { Name = "WebAppEC2" }
  depends_on = [aws_autoscaling_group.web_asg]
}

resource "aws_eip_association" "web_eip_assoc" {
  instance_id   = data.aws_instances.web_instances.ids[0]
  allocation_id = aws_eip.web_eip.id
}

resource "aws_cloudfront_distribution" "web_cdn" {
  enabled = true
  default_root_object = "index.html"
  origin {
    domain_name = aws_eip.web_eip.public_dns
    origin_id   = "webapp-origin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "webapp-origin"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  tags = { Name = "webapp-cdn" }
}

resource "aws_db_instance" "mysql_db" {
  allocated_storage       = 20
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  parameter_group_name    = "default.mysql8.0"
  skip_final_snapshot     = true
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.db_subnet_group.name
  backup_retention_period = 7
  tags                    = { Name = "devops-test-mysql" }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "high-cpu-ec2"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  dimensions = { InstanceId = data.aws_instances.web_instances.ids[0] }
}

resource "aws_cloudwatch_metric_alarm" "high_db_connections" {
  alarm_name          = "high-db-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 50
  dimensions = { DBInstanceIdentifier = aws_db_instance.mysql_db.id }
}

output "ec2_public_ip" { value = aws_eip.web_eip.public_ip }
output "cloudfront_domain" { value = aws_cloudfront_distribution.web_cdn.domain_name }
output "rds_endpoint" { value = aws_db_instance.mysql_db.endpoint }
output "s3_bucket_name" { value = aws_s3_bucket.app_bucket.id }
output "github_actions_role_arn" { value = aws_iam_role.github_actions_role.arn }
EOF
    echo "[OK] terraform/main.tf created."
}

prepare_key_pair() {
    KEY_NAME="devops-test-key"
    PRIVATE_KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
    if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
        echo "[KEY] Creating key pair: $KEY_NAME"
        aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$PRIVATE_KEY_FILE"
        chmod 400 "$PRIVATE_KEY_FILE"
    fi
}

run_terraform() {
    echo "[RUN] Running Terraform Apply..."
    cd terraform
    terraform init
    terraform apply -auto-approve
    EC2_IP=$(terraform output -raw ec2_public_ip 2>/dev/null || echo "")
    S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    GHA_ROLE=$(terraform output -raw github_actions_role_arn 2>/dev/null || echo "")
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
    cd ..
    [ -n "$EC2_IP" ] && echo "$EC2_IP" | gh secret set EC2_HOST --repo "$REPO"
    [ -n "$S3_BUCKET" ] && echo "$S3_BUCKET" | gh secret set S3_BUCKET --repo "$REPO"
    [ -n "$GHA_ROLE" ] && echo "$GHA_ROLE" | gh secret set AWS_OIDC_ROLE_ARN --repo "$REPO"
    [ -n "$RDS_ENDPOINT" ] && echo "$RDS_ENDPOINT" | gh secret set RDS_ENDPOINT --repo "$REPO"
    echo "$EC2_IP" > /tmp/ec2_ip.txt
    echo "$S3_BUCKET" > /tmp/s3_bucket.txt
}

upload_artifacts() {
    S3_BUCKET=$(cat /tmp/s3_bucket.txt 2>/dev/null)
    [ -z "$S3_BUCKET" ] && return
    echo "[S3] Uploading artifacts to s3://$S3_BUCKET..."

    # Upload pre-built binary (seed)
    if [ -f "artifacts/binaries/Binary-linux-x64.7z" ]; then
        echo "[UPLOAD] Pre-built binary (seed)"
        aws s3 cp "artifacts/binaries/Binary-linux-x64.7z" "s3://$S3_BUCKET/artifacts/latest/webapp-binaries.7z"
    else
        echo "[WARN] No pre-built binary found."
    fi

    # Upload source code (required for CI/CD)
    if [ -f "artifacts/sources/SOURCE_TodoWebAPI.7z" ]; then
        echo "[UPLOAD] Source code archive"
        aws s3 cp "artifacts/sources/SOURCE_TodoWebAPI.7z" "s3://$S3_BUCKET/sources/SOURCE_TodoWebAPI.7z"
    else
        echo "[ERROR] Source code not found at artifacts/sources/SOURCE_TodoWebAPI.7z"
        exit 1
    fi

    # Upload SQL
    [ -f "artifacts/sql/TodoItem_DDL.sql" ] && aws s3 cp artifacts/sql/TodoItem_DDL.sql s3://$S3_BUCKET/sql/
    echo "[OK] Artifacts uploaded."
}

add_ssh_key_to_ec2() {
    EC2_IP=$(cat /tmp/ec2_ip.txt 2>/dev/null)
    [ -z "$EC2_IP" ] && return
    KEY_NAME="devops-test-key"
    PRIVATE_KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
    echo "[SSH] Adding GitHub Actions SSH key to EC2..."
    ssh -i "$PRIVATE_KEY_FILE" -o StrictHostKeyChecking=no ubuntu@$EC2_IP "echo '$SSH_PUB_KEY' >> ~/.ssh/authorized_keys"
}

# ------------------------------
# Main Execution Flow
# ------------------------------
destroy_existing
install_prereqs
github_setup
configure_aws
setup_github_secrets
ensure_git_repo
create_deploy_script
create_github_workflow
create_main_tf
prepare_key_pair
run_terraform
upload_artifacts
add_ssh_key_to_ec2
commit_and_push

echo ""
echo "============================================="
echo "[DONE] Bootstrap complete."
echo "EC2 Elastic IP: $(cat /tmp/ec2_ip.txt 2>/dev/null || echo 'unknown')"
echo "S3 Bucket: $(cat /tmp/s3_bucket.txt 2>/dev/null || echo 'unknown')"
echo ""
echo "👉 EC2 will run the pre-built binary from S3."
echo "👉 On each push, GitHub Actions will build from source (SOURCE_TodoWebAPI.7z) and update the binary."
echo "👉 CloudWatch monitors EC2, RDS, and logs application output."
echo "============================================="
