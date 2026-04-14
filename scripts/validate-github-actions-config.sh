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

# --- Kubernetes access (for non-provision scenarios) ---
if [ "$SCENARIO" != "provision" ]; then
  require_nonempty "KUBECONFIG_ARTIFACT_PASSPHRASE" "${KUBECONFIG_ARTIFACT_PASSPHRASE:-}"
fi

# --- Provision / Destroy (Terraform + remote state) ---
if [ "$SCENARIO" = "provision" ]; then
  # OpenStack endpoint (provision-only)
  require_nonempty "Variable OS_AUTH_URL" "${OS_AUTH_URL:-}"
  require_nonempty "Variable OS_REGION_NAME" "${OS_REGION_NAME:-}"
  require_nonempty "Variable OS_INTERFACE" "${OS_INTERFACE:-}"
  require_nonempty "Variable OS_IDENTITY_API_VERSION" "${OS_IDENTITY_API_VERSION:-}"
  require_nonempty "Variable OS_AUTH_TYPE" "${OS_AUTH_TYPE:-}"

  if [ -n "${OS_AUTH_URL:-}" ] && [[ ! "${OS_AUTH_URL}" =~ ^https?:// ]]; then
    err "OS_AUTH_URL should start with http:// or https:// (got: ${OS_AUTH_URL:0:20}...)"
  fi

  # Auth: application credential only
  require_nonempty "OS_APPLICATION_CREDENTIAL_ID" "${OS_APPLICATION_CREDENTIAL_ID:-}"
  require_nonempty "OS_APPLICATION_CREDENTIAL_SECRET" "${OS_APPLICATION_CREDENTIAL_SECRET:-}"

  if [ "${OS_AUTH_TYPE:-}" = "v3applicationcredential" ] && [ -n "${OS_PROJECT_ID:-}" ]; then
    warn "OS_PROJECT_ID is set while OS_AUTH_TYPE is v3applicationcredential — this often breaks Keystone. Unset OS_PROJECT_ID for application credentials."
  fi

  require_nonempty "Variable LETSENCRYPT_EMAIL" "${LETSENCRYPT_EMAIL:-}"
  if [[ "${LETSENCRYPT_EMAIL:-}" == *@* ]]; then
    :
  else
    err "LETSENCRYPT_EMAIL should look like an email address."
  fi

  require_nonempty "Variable TF_STATE_S3_BUCKET" "${TF_STATE_S3_BUCKET:-}"
  require_nonempty "Variable TF_STATE_S3_ENDPOINT" "${TF_STATE_S3_ENDPOINT:-}"
  # Workflows map GitHub Secrets TF_STATE_S3_* → AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (Terraform S3 backend).
  require_nonempty "AWS_ACCESS_KEY_ID" "${AWS_ACCESS_KEY_ID:-}"
  require_nonempty "AWS_SECRET_ACCESS_KEY" "${AWS_SECRET_ACCESS_KEY:-}"
  require_nonempty "K8S_IMAGE_NAME" "${K8S_IMAGE_NAME:-}"
  require_nonempty "K8S_FLAVOR_NAME" "${K8S_FLAVOR_NAME:-}"
  require_nonempty "KUBECONFIG_ARTIFACT_PASSPHRASE" "${KUBECONFIG_ARTIFACT_PASSPHRASE:-}"
  if [ -n "${AS_NODES_MIN_SIZE:-}" ] && ! [[ "${AS_NODES_MIN_SIZE}" =~ ^[0-9]+$ ]]; then
    err "AS_NODES_MIN_SIZE must be an integer when set."
  fi
  if [ -n "${AS_NODES_MAX_SIZE:-}" ] && ! [[ "${AS_NODES_MAX_SIZE}" =~ ^[0-9]+$ ]]; then
    err "AS_NODES_MAX_SIZE must be an integer when set."
  fi
  if [ -n "${CINDER_CSI_SET_DEFAULT_SC:-}" ] && [ "${CINDER_CSI_SET_DEFAULT_SC}" != "true" ] && [ "${CINDER_CSI_SET_DEFAULT_SC}" != "false" ]; then
    err "CINDER_CSI_SET_DEFAULT_SC must be true or false when set."
  fi

  if [ -n "${TF_STATE_S3_ENDPOINT:-}" ] && [[ ! "${TF_STATE_S3_ENDPOINT}" =~ ^https?:// ]]; then
    err "TF_STATE_S3_ENDPOINT should start with http:// or https://"
  fi
fi

# --- Site deploy / scale (MariaDB secrets) ---
if [ "$SCENARIO" = "site-deploy" ]; then
  require_nonempty "DEMO_DB_PASSWORD" "${DEMO_DB_PASSWORD:-}"
  require_nonempty "DEMO_DB_ROOT_PASSWORD" "${DEMO_DB_ROOT_PASSWORD:-}"
  if [ -z "${DEMO_DOMAIN_BASE:-}" ]; then
    warn "Variable DEMO_DOMAIN_BASE is unset — workflows will fall back to the chart default. Set it to your DNS apex (e.g. k8sdemo.example.com)."
  fi
fi

# --- Optional UUID shape (non-fatal) ---
for vname in EXISTING_ROUTER_ID EXISTING_NETWORK_ID; do
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

if [ "$SCENARIO" = "provision" ] && { [ "$RUN_OPENSTACK" = "true" ] || [ "$RUN_OPENSTACK" = "True" ] || [ "$RUN_OPENSTACK" = "1" ]; }; then
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

elif [ "$SCENARIO" = "provision" ]; then
  notice "Skipping live OpenStack check (RUN_OPENSTACK_CHECK=false)."
fi

echo "=== Validation complete ==="
