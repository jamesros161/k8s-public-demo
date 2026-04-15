#!/usr/bin/env bash
set -euo pipefail

CAPI_CLUSTERCTL_VERSION="${CAPI_CLUSTERCTL_VERSION:-v1.11.3}"
CAPI_CORE_PROVIDER_VERSION="${CAPI_CORE_PROVIDER_VERSION:-v1.11.0}"
CAPI_BOOTSTRAP_PROVIDER_VERSION="${CAPI_BOOTSTRAP_PROVIDER_VERSION:-v1.11.0}"
CAPI_CONTROL_PLANE_PROVIDER_VERSION="${CAPI_CONTROL_PLANE_PROVIDER_VERSION:-v1.11.0}"
CAPO_PROVIDER_VERSION="${CAPO_PROVIDER_VERSION:-v0.14.2}"
CAPI_IPAM_PROVIDER_VERSION="${CAPI_IPAM_PROVIDER_VERSION:-v1.1.0-rc.1}"
CAPI_NAMESPACE="${CAPI_NAMESPACE:-capo-system}"

require_nonempty() {
  local name="$1"
  local value="${2:-}"
  if [ -z "${value}" ]; then
    echo "::error::Missing ${name}."
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "::error::Missing command '${cmd}'."
    exit 1
  fi
}

require_nonempty "OS_AUTH_URL" "${OS_AUTH_URL:-}"
require_nonempty "OS_REGION_NAME" "${OS_REGION_NAME:-}"
require_nonempty "OS_APPLICATION_CREDENTIAL_ID" "${OS_APPLICATION_CREDENTIAL_ID:-}"
require_nonempty "OS_APPLICATION_CREDENTIAL_SECRET" "${OS_APPLICATION_CREDENTIAL_SECRET:-}"
require_cmd curl
require_cmd kubectl

if [[ "${OS_AUTH_URL}" =~ /v3$ ]]; then
  AUTH_URL="${OS_AUTH_URL}"
else
  AUTH_URL="${OS_AUTH_URL}/v3"
fi

INTERFACE="${OS_INTERFACE:-public}"
IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}"

if ! command -v clusterctl >/dev/null 2>&1; then
  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      echo "::error::Unsupported architecture '${ARCH}' for clusterctl."
      exit 1
      ;;
  esac
  URL="https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_CLUSTERCTL_VERSION}/clusterctl-${OS}-${ARCH}"
  curl -fsSL "${URL}" -o /usr/local/bin/clusterctl
  chmod +x /usr/local/bin/clusterctl
fi

clusterctl version

INIT_ARGS=(
  init
  --core cluster-api
  --bootstrap kubeadm
  --control-plane kubeadm
  --ipam in-cluster
  --infrastructure openstack
  --wait-providers
)

if [ -n "${CAPI_CORE_PROVIDER_VERSION}" ]; then
  INIT_ARGS+=(--core "cluster-api:${CAPI_CORE_PROVIDER_VERSION}")
fi
if [ -n "${CAPI_BOOTSTRAP_PROVIDER_VERSION}" ]; then
  INIT_ARGS+=(--bootstrap "kubeadm:${CAPI_BOOTSTRAP_PROVIDER_VERSION}")
fi
if [ -n "${CAPI_CONTROL_PLANE_PROVIDER_VERSION}" ]; then
  INIT_ARGS+=(--control-plane "kubeadm:${CAPI_CONTROL_PLANE_PROVIDER_VERSION}")
fi
if [ -n "${CAPI_IPAM_PROVIDER_VERSION}" ]; then
  INIT_ARGS+=(--ipam "in-cluster:${CAPI_IPAM_PROVIDER_VERSION}")
fi
if [ -n "${CAPO_PROVIDER_VERSION}" ]; then
  INIT_ARGS+=(--infrastructure "openstack:${CAPO_PROVIDER_VERSION}")
fi

clusterctl "${INIT_ARGS[@]}"

kubectl create namespace "${CAPI_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

CLOUD_CONF_FILE="$(mktemp)"
cat > "${CLOUD_CONF_FILE}" <<EOF
clouds:
  openstack:
    auth:
      auth_url: ${AUTH_URL}
      application_credential_id: ${OS_APPLICATION_CREDENTIAL_ID}
      application_credential_secret: ${OS_APPLICATION_CREDENTIAL_SECRET}
    region_name: ${OS_REGION_NAME}
    interface: ${INTERFACE}
    identity_api_version: "${IDENTITY_API_VERSION}"
    auth_type: v3applicationcredential
EOF

kubectl -n "${CAPI_NAMESPACE}" create secret generic capo-cloud-config \
  --from-file=clouds.yaml="${CLOUD_CONF_FILE}" \
  --dry-run=client \
  -o yaml | kubectl apply -f -

echo "::notice::Cluster API + CAPO bootstrap complete in namespace '${CAPI_NAMESPACE}'."
