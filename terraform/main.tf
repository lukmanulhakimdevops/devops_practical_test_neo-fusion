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
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC
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

# Security Groups
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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

# S3 Configuration
resource "aws_s3_bucket" "app_bucket" {
  bucket_prefix = "devops-test-bucket-"
  force_destroy = true
  tags = { Name = "App Artifacts" }
}

resource "aws_s3_bucket_ownership_controls" "app_bucket_ownership" {
  bucket = aws_s3_bucket.app_bucket.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "app_bucket_block" {
  bucket                  = aws_s3_bucket.app_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# RDS Subnet Group
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

# IAM Roles
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
    Statement = [
      {
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.app_bucket.arn,
          "${aws_s3_bucket.app_bucket.arn}/artifacts/sources/*",
          "${aws_s3_bucket.app_bucket.arn}/artifacts/binaries/*"
        ]
      },
      {
        Action   = ["s3:PutObject"]
        Effect   = "Allow"
        Resource = [
          "${aws_s3_bucket.app_bucket.arn}/artifacts/binaries/*",
          "${aws_s3_bucket.app_bucket.arn}/artifacts/sources/*",
          "${aws_s3_bucket.app_bucket.arn}/sql/*"
        ]
      }
    ]
  })
}

# Elastic IP
resource "aws_eip" "web_eip" {
  domain = "vpc"
  tags = { Name = "webapp-eip" }
}

# RDS
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
  tags = { Name = "devops-test-mysql" }
}

# EC2 User Data
locals {
  user_data = <<-USERDATA
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

exec > >(tee /var/log/user-data.log|logger -t user-data) 2>&1
echo "=== Bootstrapping EC2: $(date) ==="

sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial
sudo -E apt-get update --fix-missing -y
sudo -E apt-get upgrade -y
sudo -E apt-get install -y wget awscli mysql-client p7zip-full dotnet-runtime-6.0

# CloudWatch Agent
sudo wget -q https://s3.amazonaws.com/amazoncloudwatchagent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb
sudo rm -f amazon-cloudwatch-agent.deb

sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'CWEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {"file_path": "/var/log/webapp.log",    "log_group_name": "/aws/ec2/webapp",     "log_stream_name": "{instance_id}", "retention_in_days": 7},
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
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

BUCKET_NAME="${aws_s3_bucket.app_bucket.id}"
# Wait for binary artifact (seed from bootstrap) up to 5 minutes
for i in {1..30}; do
  if aws s3 ls "s3://$BUCKET_NAME/artifacts/binaries/webapp-binaries.7z" &>/dev/null; then
    aws s3 cp s3://$BUCKET_NAME/artifacts/binaries/webapp-binaries.7z /tmp/webapp.7z
    sudo mkdir -p /var/www/webapp
    sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y
    sudo chown -R www-data:www-data /var/www/webapp

    MAIN_DLL=$(find /var/www/webapp \( -name "TodoWebAPI.dll" -o -name "WebApp.dll" \) | head -1)
    if [ -z "$MAIN_DLL" ]; then
      echo "ERROR: Main DLL not found"; exit 1
    fi
    APP_DIR=$(dirname "$MAIN_DLL")
    echo "Main DLL: $MAIN_DLL"

    RDS_ENDPOINT="${aws_db_instance.mysql_db.endpoint}"
    RDS_HOST=$(echo "$RDS_ENDPOINT" | cut -d':' -f1)
    CONN_STRING="Server=$RDS_HOST;Database=${var.db_name};User=${var.db_username};Password=${var.db_password}"
    sudo sed -i "s|\"DefaultConnection\": \".*\"|\"DefaultConnection\": \"$CONN_STRING\"|" \
      "$APP_DIR/appsettings.json" || true

    sudo tee /etc/systemd/system/webapp.service > /dev/null <<EOF
[Unit]
Description=DotNet Web API
After=network.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/dotnet $MAIN_DLL
Restart=always
User=www-data
StandardOutput=append:/var/log/webapp.log
StandardError=append:/var/log/webapp.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable webapp
    sudo systemctl start webapp

    sleep 10
    if curl -sf http://localhost:80/swagger/index.html > /dev/null; then
      echo "App started successfully."
    else
      echo "WARNING: App not responding — check /var/log/webapp.log"
      sudo systemctl status webapp --no-pager || true
    fi
    break
  fi
  echo "Waiting for binary artifact... $i/30"
  sleep 10
done

echo "=== Bootstrap complete: $(date) ==="
USERDATA
}

# Launch Template & ASG
resource "aws_launch_template" "web_lt" {
  name_prefix   = "web-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  key_name      = var.key_name
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
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
  instance_tags = {
    Name = "WebAppEC2"
  }
  depends_on = [aws_autoscaling_group.web_asg]
}

resource "aws_eip_association" "web_eip_assoc" {
  instance_id   = data.aws_instances.web_instances.ids[0]
  allocation_id = aws_eip.web_eip.id
}

# CloudFront
resource "aws_cloudfront_distribution" "web_cdn" {
  enabled = true
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
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "webapp-origin"
    viewer_protocol_policy = "redirect-to-https"
    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies {
        forward = "all"
      }
    }
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  tags = { Name = "webapp-cdn" }
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "high-cpu-asg"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EC2 CPU > 80% for 10 min"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web_asg.name
  }
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
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.mysql_db.id
  }
}

output "ec2_public_ip" {
  value = aws_eip.web_eip.public_ip
}
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.web_cdn.domain_name
}
output "rds_endpoint" {
  value = aws_db_instance.mysql_db.endpoint
}
output "s3_bucket_name" {
  value = aws_s3_bucket.app_bucket.id
}
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions_role.arn
}
