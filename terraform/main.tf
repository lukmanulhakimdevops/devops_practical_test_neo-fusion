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

BUCKET_NAME="${aws_s3_bucket.app_bucket.id}"
echo "Bucket: $BUCKET_NAME"
aws s3 cp s3://$BUCKET_NAME/artifacts/latest/webapp-binaries.7z /tmp/webapp.7z

sudo mkdir -p /var/www/webapp
sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y

MAIN_DLL=$(find /var/www/webapp -name "TodoWebAPI.dll" -o -name "WebApp.dll" | head -1)
if [ -z "$MAIN_DLL" ]; then
    echo "ERROR: Could not find main DLL. Exiting."
    exit 1
fi
APP_DIR=$(dirname "$MAIN_DLL")
echo "Found main DLL: $MAIN_DLL"

sudo tee /etc/systemd/system/webapp.service > /dev/null << 'SVC'
[Unit]
Description=DotNet Web API
After=network.target

[Service]
WorkingDirectory=APP_DIR_PLACEHOLDER
ExecStart=/usr/bin/dotnet MAIN_DLL_PLACEHOLDER
Restart=always
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
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
    echo "Application started successfully on port 80."
else
    echo "WARNING: Application not responding on port 80 — check logs."
    sudo systemctl status webapp --no-pager || true
    sudo cat /var/log/webapp.log || true
fi

echo "=== Bootstrap completed ==="
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
  name               = "web-asg"
  min_size           = 1
  max_size           = 1
  desired_capacity   = 1
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
