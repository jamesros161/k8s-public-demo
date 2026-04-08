#!/usr/bin/env bash
# GitHub Actions: append to GITHUB_ENV so OpenStack CLI + Terraform use either
# application credentials (job defaults) OR username/password when Magnum needs Keystone trusts.
#
# When TERRAFORM_OPENSTACK_PASSWORD is non-empty, switch to password auth and set project scope.
# Required env for password mode: TERRAFORM_OPENSTACK_USERNAME, TERRAFORM_OPENSTACK_PASSWORD,
# TERRAFORM_OPENSTACK_PROJECT_ID (GitHub Variables / Secrets — see README).
set -euo pipefail

GITHUB_ENV="${GITHUB_ENV:?GITHUB_ENV must be set (run inside GitHub Actions)}"

if [ -n "${TERRAFORM_OPENSTACK_PASSWORD:-}" ]; then
  if [ -z "${TERRAFORM_OPENSTACK_USERNAME:-}" ] || [ -z "${TERRAFORM_OPENSTACK_PROJECT_ID:-}" ]; then
    echo "::error::Set TERRAFORM_OPENSTACK_USERNAME secret and TERRAFORM_OPENSTACK_PROJECT_ID variable when using TERRAFORM_OPENSTACK_PASSWORD (see README)."
    exit 1
  fi
  echo "::notice::OpenStack auth: using OS_USERNAME/OS_PASSWORD for this job (Magnum trust / Keystone rejects application_credential for trusts)."
  {
    echo "OS_AUTH_TYPE=password"
    echo "OS_USERNAME=${TERRAFORM_OPENSTACK_USERNAME}"
    echo "OS_PASSWORD=${TERRAFORM_OPENSTACK_PASSWORD}"
    echo "OS_USER_DOMAIN_NAME=${TERRAFORM_OPENSTACK_USER_DOMAIN_NAME:-Default}"
    echo "OS_PROJECT_ID=${TERRAFORM_OPENSTACK_PROJECT_ID}"
    echo "OS_PROJECT_NAME="
    echo "OS_PROJECT_DOMAIN_ID=${TERRAFORM_OPENSTACK_PROJECT_DOMAIN_ID:-default}"
    echo "OS_APPLICATION_CREDENTIAL_ID="
    echo "OS_APPLICATION_CREDENTIAL_SECRET="
  } >>"$GITHUB_ENV"
else
  echo "::notice::OpenStack auth: using application credentials (OS_APPLICATION_CREDENTIAL_* from workflow env)."
fi
