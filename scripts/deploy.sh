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
