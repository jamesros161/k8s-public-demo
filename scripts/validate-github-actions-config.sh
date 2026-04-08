#!/usr/bin/env bash
# Validates GitHub repository Variables/Secrets expected by workflows.
# Run in Actions after scripts/configure-gha-openstack-auth.sh (so OS_* matches Provision/Destroy).
# Env: VALIDATE_SCENARIO = core | provision | site-deploy
# Env: RUN_OPENSTACK_CHECK = true | false (default true)
set -euo pipefail

SCENARIO="${VALIDATE_SCENARIO:-provision}"
RUN_OPENSTACK="${RUN_OPENSTACK_CHECK:-true}"

ERRORS=0

err() {
  echo "::error::$*"
  ERRORS=$((ERRORS + 1))
}

warn() {
  echo "::warning::$*"
}

notice() {
  echo "::notice::$*"
}

require_nonempty() {
  local name=$1
  local value=${2:-}
  if [ -z "$value" ]; then
    err "Missing or empty: $name (set the repository Variable or Secret named in the README)."
  fi
}

echo "=== Configuration validation (scenario: $SCENARIO) ==="

# --- OpenStack endpoint (all scenarios) ---
require_nonempty "Variable OS_AUTH_URL" "${OS_AUTH_URL:-}"
require_nonempty "Variable OS_REGION_NAME" "${OS_REGION_NAME:-}"
require_nonempty "Variable OS_INTERFACE" "${OS_INTERFACE:-}"
require_nonempty "Variable OS_IDENTITY_API_VERSION" "${OS_IDENTITY_API_VERSION:-}"
require_nonempty "Variable OS_AUTH_TYPE" "${OS_AUTH_TYPE:-}"

if [ -n "${OS_AUTH_URL:-}" ] && [[ ! "${OS_AUTH_URL}" =~ ^https?:// ]]; then
  err "OS_AUTH_URL should start with http:// or https:// (got: ${OS_AUTH_URL:0:20}...)"
fi

# --- Auth: application credential OR password path for Terraform jobs ---
if [ -n "${TERRAFORM_OPENSTACK_PASSWORD:-}" ]; then
  require_nonempty "Secret TERRAFORM_OPENSTACK_USERNAME" "${TERRAFORM_OPENSTACK_USERNAME:-}"
  require_nonempty "Variable TERRAFORM_OPENSTACK_PROJECT_ID" "${TERRAFORM_OPENSTACK_PROJECT_ID:-}"
  notice "Terraform-style password auth is configured (Magnum trust / Keystone)."
else
  require_nonempty "Secret OS_APPLICATION_CREDENTIAL_ID" "${OS_APPLICATION_CREDENTIAL_ID:-}"
  require_nonempty "Secret OS_APPLICATION_CREDENTIAL_SECRET" "${OS_APPLICATION_CREDENTIAL_SECRET:-}"
fi

if [ "${OS_AUTH_TYPE:-}" = "v3applicationcredential" ] && [ -n "${OS_PROJECT_ID:-}" ]; then
  warn "OS_PROJECT_ID is set while OS_AUTH_TYPE is v3applicationcredential — this often breaks Keystone. Unset OS_PROJECT_ID for application credentials."
fi

# --- Provision / Destroy (Terraform + remote state) ---
if [ "$SCENARIO" = "provision" ]; then
  require_nonempty "Variable LETSENCRYPT_EMAIL" "${LETSENCRYPT_EMAIL:-}"
  if [[ "${LETSENCRYPT_EMAIL:-}" == *@* ]]; then
    :
  else
    err "LETSENCRYPT_EMAIL should look like an email address."
  fi

  require_nonempty "Variable TF_STATE_S3_BUCKET" "${TF_STATE_S3_BUCKET:-}"
  require_nonempty "Variable TF_STATE_S3_ENDPOINT" "${TF_STATE_S3_ENDPOINT:-}"
  require_nonempty "Secret TF_STATE_S3_ACCESS_KEY_ID" "${TF_STATE_S3_ACCESS_KEY_ID:-}"
  require_nonempty "Secret TF_STATE_S3_SECRET_ACCESS_KEY" "${TF_STATE_S3_SECRET_ACCESS_KEY:-}"

  if [ -n "${TF_STATE_S3_ENDPOINT:-}" ] && [[ ! "${TF_STATE_S3_ENDPOINT}" =~ ^https?:// ]]; then
    err "TF_STATE_S3_ENDPOINT should start with http:// or https://"
  fi
fi

# --- Site deploy / scale (MariaDB secrets) ---
if [ "$SCENARIO" = "site-deploy" ]; then
  require_nonempty "Secret DEMO_DB_PASSWORD" "${DEMO_DB_PASSWORD:-}"
  require_nonempty "Secret DEMO_DB_ROOT_PASSWORD" "${DEMO_DB_ROOT_PASSWORD:-}"
  if [ -z "${DEMO_DOMAIN_BASE:-}" ]; then
    warn "Variable DEMO_DOMAIN_BASE is unset — workflows will fall back to the chart default. Set it to your DNS apex (e.g. k8sdemo.example.com)."
  fi
fi

# --- Optional UUID shape (non-fatal) ---
for vname in EXISTING_ROUTER_ID EXISTING_NETWORK_ID TERRAFORM_OPENSTACK_PROJECT_ID; do
  eval "v=\${${vname}:-}"
  if [ -n "$v" ]; then
    trimmed="$(echo -n "$v" | tr -d ' \t\r\n')"
    if [ "$v" != "$trimmed" ]; then
      warn "$vname has leading/trailing whitespace — re-save the Variable with only the raw UUID."
    fi
  fi
done

if [ "$ERRORS" -gt 0 ]; then
  echo "::error::Validation failed with $ERRORS error(s). Fix the items above, then re-run **Validate configuration** or your workflow."
  exit 1
fi

echo "Static checks passed."

if [ "$RUN_OPENSTACK" = "true" ] || [ "$RUN_OPENSTACK" = "True" ] || [ "$RUN_OPENSTACK" = "1" ]; then
  if ! command -v openstack >/dev/null 2>&1; then
    err "openstack CLI not found — install python-openstackclient before the live check."
    exit 1
  fi
  echo "Running OpenStack token issue (smoke test)..."
  if openstack token issue -f value -c id >/dev/null 2>&1; then
    notice "OpenStack authentication succeeded."
  else
    err "OpenStack authentication failed. Check OS_* variables and credentials; compare with values from your cloud administrator."
    openstack token issue 2>&1 | head -30 || true
    exit 1
  fi

  if [ "$SCENARIO" = "provision" ] || [ "$SCENARIO" = "site-deploy" ]; then
    echo "Checking Magnum API (cluster template list)..."
    if openstack coe cluster template list >/dev/null 2>&1; then
      notice "Magnum API responded."
    else
      warn "openstack coe cluster template list failed — confirm Magnum is enabled and your user has access."
    fi
  fi
else
  notice "Skipping live OpenStack check (RUN_OPENSTACK_CHECK=false)."
fi

echo "=== Validation complete ==="
