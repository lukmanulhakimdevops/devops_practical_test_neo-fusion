#!/bin/bash
set -e

BUCKET="devops-test-bucket-lukmanulhakim"
echo "[INFO] Menginisiasi upload logistik ke S3 bucket: $BUCKET"

# 1. Pastikan p7zip dan zip terinstal di lokal
if ! command -v 7z &> /dev/null || ! command -v zip &> /dev/null; then
    echo "[ERROR] Perintah '7z' atau 'zip' tidak ditemukan. Silakan install p7zip-full dan zip terlebih dahulu."
    exit 1
fi

# 2. Re-packaging: Ekstrak 7z dan kompres ulang menjadi ZIP
echo "[PROCESS] Konversi format .7z menjadi .zip agar kompatibel dengan EC2..."
mkdir -p /tmp/webapp_extract
7z x "artifacts/binaries/Binary-linux-x64.7z" -o/tmp/webapp_extract >/dev/null
cd /tmp/webapp_extract && zip -r webapp-binaries.zip . >/dev/null && cd -

# 3. Upload file ZIP ke S3 (dengan nama yang diekspektasikan deploy.sh)
echo "[UPLOAD] Mengirim webapp-binaries.zip ke S3..."
aws s3 cp /tmp/webapp_extract/webapp-binaries.zip s3://$BUCKET/artifacts/latest/webapp-binaries.zip

# 4. Upload SQL
echo "[UPLOAD] Mengirim DDL SQL ke S3..."
aws s3 cp artifacts/sql/TodoItem_DDL.sql s3://$BUCKET/sql/TodoItem_DDL.sql

# 5. Housekeeping (Pembersihan memori sementara)
rm -rf /tmp/webapp_extract

echo "[OK] Seluruh logistik berhasil diunggah dengan format yang tepat."
