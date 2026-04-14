#!/usr/bin/env bash
set -euo pipefail

OPENSTACK_CCM_CHART_VERSION="${OPENSTACK_CCM_CHART_VERSION:-}"
OPENSTACK_CCM_USE_OCTAVIA="${OPENSTACK_CCM_USE_OCTAVIA:-true}"
TF_CLUSTER_NAME="${TF_VAR_cluster_name:-kubernetes}"
CLUSTER_NAME="$(echo "${TF_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"

require_nonempty() {
  local name="$1"
  local value="${2:-}"
  if [ -z "${value}" ]; then
    echo "::error::Missing ${name}."
    exit 1
  fi
}

require_nonempty "OS_AUTH_URL" "${OS_AUTH_URL:-}"
require_nonempty "OS_REGION_NAME" "${OS_REGION_NAME:-}"
require_nonempty "OS_APPLICATION_CREDENTIAL_ID" "${OS_APPLICATION_CREDENTIAL_ID:-}"
require_nonempty "OS_APPLICATION_CREDENTIAL_SECRET" "${OS_APPLICATION_CREDENTIAL_SECRET:-}"

if [ "${OPENSTACK_CCM_USE_OCTAVIA}" != "true" ] && [ "${OPENSTACK_CCM_USE_OCTAVIA}" != "false" ]; then
  echo "::error::OPENSTACK_CCM_USE_OCTAVIA must be true or false."
  exit 1
fi

if [[ "${OS_AUTH_URL}" =~ /v3$ ]]; then
  AUTH_URL="${OS_AUTH_URL}"
else
  AUTH_URL="${OS_AUTH_URL}/v3"
fi

INTERFACE="${OS_INTERFACE:-public}"

VALUES_FILE="$(mktemp)"
cat > "${VALUES_FILE}" <<EOF
cluster:
  name: ${CLUSTER_NAME}
secret:
  enabled: true
  create: true
  name: cloud-config
cloudConfig:
  global:
    auth-url: ${AUTH_URL}
    application-credential-id: ${OS_APPLICATION_CREDENTIAL_ID}
    application-credential-secret: ${OS_APPLICATION_CREDENTIAL_SECRET}
    region: ${OS_REGION_NAME}
    interface: ${INTERFACE}
  loadBalancer:
    enabled: true
    use-octavia: ${OPENSTACK_CCM_USE_OCTAVIA}
EOF

helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack >/dev/null 2>&1 || true
helm repo update

ARGS=(
  upgrade --install openstack-cloud-controller-manager cpo/openstack-cloud-controller-manager
  --namespace kube-system
  -f "${VALUES_FILE}"
  --wait
  --timeout 15m
)

if [ -n "${OPENSTACK_CCM_CHART_VERSION}" ]; then
  ARGS+=(--version "${OPENSTACK_CCM_CHART_VERSION}")
fi

helm "${ARGS[@]}"

echo "::notice::openstack-cloud-controller-manager installed or updated."
kubectl -n kube-system get deploy openstack-cloud-controller-manager -o wide
