#!/usr/bin/env bash
# GitHub Actions: enforce app credential auth for OpenStack.
set -euo pipefail

GITHUB_ENV="${GITHUB_ENV:?GITHUB_ENV must be set (run inside GitHub Actions)}"
if [ -z "${OS_APPLICATION_CREDENTIAL_ID:-}" ] || [ -z "${OS_APPLICATION_CREDENTIAL_SECRET:-}" ]; then
  echo "::error::Missing OS_APPLICATION_CREDENTIAL_ID/OS_APPLICATION_CREDENTIAL_SECRET."
  echo "::error::Set these values in CLOUD_ADMIN_CONFIG_B64."
  exit 1
fi

{
  echo "OS_AUTH_TYPE=v3applicationcredential"
  echo "OS_USERNAME="
  echo "OS_PASSWORD="
  echo "OS_USER_DOMAIN_NAME="
  echo "OS_PROJECT_ID="
  echo "OS_PROJECT_NAME="
  echo "OS_PROJECT_DOMAIN_ID="
} >>"$GITHUB_ENV"

echo "::notice::OpenStack auth: using application credentials only."
