#!/usr/bin/env bash
set -euo pipefail

CINDER_CSI_CHART_VERSION="${CINDER_CSI_CHART_VERSION:-}"
CINDER_CSI_STORAGECLASS_NAME="${CINDER_CSI_STORAGECLASS_NAME:-cinder-csi}"
CINDER_CSI_SET_DEFAULT_SC="${CINDER_CSI_SET_DEFAULT_SC:-true}"

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

if [ "${CINDER_CSI_SET_DEFAULT_SC}" != "true" ] && [ "${CINDER_CSI_SET_DEFAULT_SC}" != "false" ]; then
  echo "::error::CINDER_CSI_SET_DEFAULT_SC must be true or false."
  exit 1
fi

if [[ "${OS_AUTH_URL}" =~ /v3$ ]]; then
  AUTH_URL="${OS_AUTH_URL}"
else
  AUTH_URL="${OS_AUTH_URL}/v3"
fi

INTERFACE="${OS_INTERFACE:-public}"

CLOUD_CONF_FILE="$(mktemp)"
cat > "${CLOUD_CONF_FILE}" <<EOF
[Global]
auth-url=${AUTH_URL}
application-credential-id=${OS_APPLICATION_CREDENTIAL_ID}
application-credential-secret=${OS_APPLICATION_CREDENTIAL_SECRET}
region=${OS_REGION_NAME}
interface=${INTERFACE}
EOF

VALUES_FILE="$(mktemp)"
cat > "${VALUES_FILE}" <<EOF
secret:
  enabled: true
  hostMount: false
  create: true
  name: cinder-csi-cloud-config
  filename: cloud.conf
  data:
    cloud.conf: |-
$(sed 's/^/      /' "${CLOUD_CONF_FILE}")
storageClass:
  enabled: true
  delete:
    isDefault: ${CINDER_CSI_SET_DEFAULT_SC}
    allowVolumeExpansion: true
    name: ${CINDER_CSI_STORAGECLASS_NAME}
  retain:
    isDefault: false
    allowVolumeExpansion: true
    name: ${CINDER_CSI_STORAGECLASS_NAME}-retain
EOF

helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack >/dev/null 2>&1 || true
helm repo update

ARGS=(
  upgrade --install openstack-cinder-csi cpo/openstack-cinder-csi
  --namespace kube-system
  -f "${VALUES_FILE}"
  --wait
  --timeout 15m
)

if [ -n "${CINDER_CSI_CHART_VERSION}" ]; then
  ARGS+=(--version "${CINDER_CSI_CHART_VERSION}")
fi

helm "${ARGS[@]}"

echo "::notice::openstack-cinder-csi installed or updated."
kubectl get sc
