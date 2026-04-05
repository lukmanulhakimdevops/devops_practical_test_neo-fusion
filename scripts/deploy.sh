#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "=== Konfigurasi needrestart agar otomatis ==="
sudo sed -i 's/#$nrconf{restart} = .*/$nrconf{restart} = "a";/' /etc/needrestart/needrestart.conf 2>/dev/null || true

echo "=== Membersihkan apt lists ==="
sudo rm -rf /var/lib/apt/lists/*
sudo mkdir -p /var/lib/apt/lists/partial

echo "=== Update system ==="
sudo -E apt-get update --fix-missing -y
sudo -E apt-get upgrade -y

echo "=== Install dependencies ==="
sudo -E apt-get install -y wget awscli mysql-client p7zip-full

echo "=== Install .NET 6 runtime ==="
wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo -E apt-get update --fix-missing -y
sudo -E apt-get install -y dotnet-runtime-6.0

echo "=== Download aplikasi dari S3 ==="
BUCKET_NAME="BUCKET_PLACEHOLDER"
aws s3 cp s3://$BUCKET_NAME/artifacts/latest/webapp-binaries.7z /tmp/webapp.7z

echo "=== Deploy aplikasi ==="
sudo mkdir -p /var/www/webapp
sudo 7z x /tmp/webapp.7z -o/var/www/webapp/ -y
sudo chmod +x /var/www/webapp/linux-x64/TodoWebAPI

echo "=== Buat systemd service ==="
sudo cat > /etc/systemd/system/webapp.service << 'SVC'
[Unit]
Description=DotNet Web API
After=network.target

[Service]
WorkingDirectory=/var/www/webapp/linux-x64
ExecStart=/var/www/webapp/linux-x64/TodoWebAPI
Restart=always
User=root
Environment=ASPNETCORE_ENVIRONMENT=Production
StandardOutput=append:/var/log/webapp.log
StandardError=append:/var/log/webapp.log

[Install]
WantedBy=multi-user.target
SVC

echo "=== Start aplikasi ==="
sudo systemctl daemon-reload
sudo systemctl enable webapp
sudo systemctl start webapp
sudo systemctl status webapp --no-pager

echo "=== Deployment selesai ==="
