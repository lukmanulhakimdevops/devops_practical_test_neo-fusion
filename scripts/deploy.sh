#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/* && sudo mkdir -p /var/lib/apt/lists/partial
sudo -E apt-get update --fix-missing -y
sudo -E apt-get upgrade -y
sudo -E apt-get install -y wget awscli mysql-client unzip
wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh
sudo chmod +x /tmp/dotnet-install.sh
sudo /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet
sudo ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
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
BUCKET_NAME="BUCKET_PLACEHOLDER"
aws s3 cp s3://$BUCKET_NAME/artifacts/binaries/webapp-binaries.zip /tmp/webapp.zip
sudo mkdir -p /var/www/webapp
sudo unzip -o /tmp/webapp.zip -d /var/www/webapp/
sudo chown -R root:root /var/www/webapp
RUNTIME_CONF=$(find /var/www/webapp -maxdepth 1 -name "*.runtimeconfig.json" | head -1)
[ -z "$RUNTIME_CONF" ] && { echo "ERROR: .runtimeconfig.json not found"; exit 1; }
MAIN_DLL="${RUNTIME_CONF%.runtimeconfig.json}.dll"
APP_DIR=$(dirname "$MAIN_DLL")
printf '%s\n' \
'[Unit]' 'Description=DotNet Web API' 'After=network.target' '' \
'[Service]' \
"WorkingDirectory=$APP_DIR" \
"ExecStart=/usr/bin/dotnet $MAIN_DLL" \
'Restart=always' 'User=root' \
'Environment=ASPNETCORE_URLS=http://+:80' \
'Environment=ASPNETCORE_HTTPS_PORT=' \
'Environment=ASPNETCORE_Kestrel__Certificates__Default__Path=' \
'StandardOutput=append:/var/log/webapp.log' \
'StandardError=append:/var/log/webapp.log' '' \
'[Install]' 'WantedBy=multi-user.target' \
| sudo tee /etc/systemd/system/webapp.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable webapp
sudo systemctl start webapp
