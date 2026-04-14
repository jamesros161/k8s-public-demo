#!/usr/bin/env bash
# Writes terraform/backend.auto.hcl for GitHub Actions (Swift S3-compatible API).
# Required env: TF_STATE_S3_BUCKET, TF_STATE_S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
# Optional: TF_STATE_S3_KEY (default k8s-demo/terraform.tfstate)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${TF_STATE_S3_BUCKET:-}" ] || [ -z "${TF_STATE_S3_ENDPOINT:-}" ]; then
  echo "::error::Set TF_STATE_S3_BUCKET and TF_STATE_S3_ENDPOINT in CLOUD_ADMIN_CONFIG_B64 (Swift S3 API). See README § Single secret setup."
  exit 1
fi
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "::error::Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in CLOUD_ADMIN_CONFIG_B64 (S3 API keys for state bucket—not the OS_* application credential)."
  exit 1
fi

KEY="${TF_STATE_S3_KEY:-k8s-demo/terraform.tfstate}"

cat > terraform/backend.auto.hcl <<EOF
bucket = "${TF_STATE_S3_BUCKET}"
key    = "${KEY}"
region = "us-east-1"

endpoints = { s3 = "${TF_STATE_S3_ENDPOINT}" }

skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
use_path_style              = true
use_lockfile                = true
EOF

echo "Wrote terraform/backend.auto.hcl (bucket=${TF_STATE_S3_BUCKET}, key=${KEY})"
