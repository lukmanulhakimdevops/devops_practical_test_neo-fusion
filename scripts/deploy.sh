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
MAIN_DLL=$(find /var/www/webapp -name "TodoWebAPI.dll" -o -name "WebApp.dll" | head -1)
if [ -z "$MAIN_DLL" ]; then
    echo "ERROR: Main DLL not found"
    exit 1
fi
APP_DIR=$(dirname "$MAIN_DLL")

echo "=== Buat systemd service ==="
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

echo "=== Start aplikasi ==="
sudo systemctl daemon-reload
sudo systemctl enable webapp
sudo systemctl start webapp
sudo systemctl status webapp --no-pager

echo "=== Deployment selesai ==="
