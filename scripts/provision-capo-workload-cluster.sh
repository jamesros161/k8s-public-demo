#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${REPO_ROOT}/k8s/capi/workload-cluster.template.yaml"

CAPI_NAMESPACE="${CAPI_NAMESPACE:-capo-system}"
CAPI_WORKLOAD_CLUSTER_NAME="${CAPI_WORKLOAD_CLUSTER_NAME:-${TF_VAR_cluster_name:-vpc-demo}-workload}"
CAPI_WORKLOAD_CLUSTER_NAME="$(echo "${CAPI_WORKLOAD_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
CAPI_WORKLOAD_KUBERNETES_VERSION="${CAPI_WORKLOAD_KUBERNETES_VERSION:-v1.29.4}"
CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT="${CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT:-1}"
CAPI_WORKLOAD_WORKER_MACHINE_COUNT="${CAPI_WORKLOAD_WORKER_MACHINE_COUNT:-${TF_VAR_k8s_worker_count:-2}}"
CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR="${CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR:-${K8S_FLAVOR_NAME:-}}"
CAPI_WORKLOAD_WORKER_FLAVOR="${CAPI_WORKLOAD_WORKER_FLAVOR:-${K8S_FLAVOR_NAME:-}}"
CAPI_WORKLOAD_IMAGE_NAME="${CAPI_WORKLOAD_IMAGE_NAME:-${K8S_IMAGE_NAME:-}}"
CAPI_WORKLOAD_SSH_KEY_NAME="${CAPI_WORKLOAD_SSH_KEY_NAME:-}"
CAPI_WORKLOAD_POD_CIDR="${CAPI_WORKLOAD_POD_CIDR:-${TF_VAR_k8s_pod_cidr:-10.244.0.0/16}}"
CAPI_WORKLOAD_SERVICE_CIDR="${CAPI_WORKLOAD_SERVICE_CIDR:-10.96.0.0/12}"
CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME="${CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME:-External}"

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

require_nonempty "CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR or K8S_FLAVOR_NAME" "${CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR}"
require_nonempty "CAPI_WORKLOAD_WORKER_FLAVOR or K8S_FLAVOR_NAME" "${CAPI_WORKLOAD_WORKER_FLAVOR}"
require_nonempty "CAPI_WORKLOAD_IMAGE_NAME or K8S_IMAGE_NAME" "${CAPI_WORKLOAD_IMAGE_NAME}"
require_cmd kubectl
require_cmd terraform
require_cmd sed

if [ ! -f "${TEMPLATE_FILE}" ]; then
  echo "::error::Template not found: ${TEMPLATE_FILE}"
  exit 1
fi

if [ -z "${CAPI_WORKLOAD_NETWORK_ID:-}" ]; then
  CAPI_WORKLOAD_NETWORK_ID="$(terraform -chdir="${REPO_ROOT}/terraform" output -raw demo_network_id)"
fi
if [ -z "${CAPI_WORKLOAD_SUBNET_ID:-}" ]; then
  CAPI_WORKLOAD_SUBNET_ID="$(terraform -chdir="${REPO_ROOT}/terraform" output -raw demo_subnet_id)"
fi
if [ -z "${CAPI_WORKLOAD_EXTERNAL_NETWORK_ID:-}" ]; then
  if ! command -v openstack >/dev/null 2>&1; then
    echo "::error::CAPI_WORKLOAD_EXTERNAL_NETWORK_ID is unset and openstack CLI is not available."
    exit 1
  fi
  CAPI_WORKLOAD_EXTERNAL_NETWORK_ID="$(openstack network show "${CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME}" -f value -c id)"
fi

require_nonempty "CAPI_WORKLOAD_NETWORK_ID" "${CAPI_WORKLOAD_NETWORK_ID}"
require_nonempty "CAPI_WORKLOAD_SUBNET_ID" "${CAPI_WORKLOAD_SUBNET_ID}"
require_nonempty "CAPI_WORKLOAD_EXTERNAL_NETWORK_ID" "${CAPI_WORKLOAD_EXTERNAL_NETWORK_ID}"

if [ -z "${CAPI_WORKLOAD_SSH_KEY_NAME}" ]; then
  CAPI_WORKLOAD_SSH_KEY_NAME="null"
fi

rendered_file="$(mktemp)"
sed \
  -e "s|__NAMESPACE__|${CAPI_NAMESPACE}|g" \
  -e "s|__CLUSTER_NAME__|${CAPI_WORKLOAD_CLUSTER_NAME}|g" \
  -e "s|__KUBERNETES_VERSION__|${CAPI_WORKLOAD_KUBERNETES_VERSION}|g" \
  -e "s|__CONTROL_PLANE_REPLICAS__|${CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT}|g" \
  -e "s|__WORKER_REPLICAS__|${CAPI_WORKLOAD_WORKER_MACHINE_COUNT}|g" \
  -e "s|__CONTROL_PLANE_FLAVOR__|${CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR}|g" \
  -e "s|__WORKER_FLAVOR__|${CAPI_WORKLOAD_WORKER_FLAVOR}|g" \
  -e "s|__IMAGE_NAME__|${CAPI_WORKLOAD_IMAGE_NAME}|g" \
  -e "s|__SSH_KEY_NAME__|${CAPI_WORKLOAD_SSH_KEY_NAME}|g" \
  -e "s|__POD_CIDR__|${CAPI_WORKLOAD_POD_CIDR}|g" \
  -e "s|__SERVICE_CIDR__|${CAPI_WORKLOAD_SERVICE_CIDR}|g" \
  -e "s|__NETWORK_ID__|${CAPI_WORKLOAD_NETWORK_ID}|g" \
  -e "s|__SUBNET_ID__|${CAPI_WORKLOAD_SUBNET_ID}|g" \
  -e "s|__EXTERNAL_NETWORK_ID__|${CAPI_WORKLOAD_EXTERNAL_NETWORK_ID}|g" \
  "${TEMPLATE_FILE}" > "${rendered_file}"

kubectl apply -f "${rendered_file}"

echo "Waiting for CAPI Cluster resource to become provisioned..."
kubectl wait --namespace "${CAPI_NAMESPACE}" --for=condition=ControlPlaneInitialized "cluster/${CAPI_WORKLOAD_CLUSTER_NAME}" --timeout=45m
kubectl wait --namespace "${CAPI_NAMESPACE}" --for=condition=ControlPlaneReady "cluster/${CAPI_WORKLOAD_CLUSTER_NAME}" --timeout=45m
kubectl wait --namespace "${CAPI_NAMESPACE}" --for=condition=InfrastructureReady "cluster/${CAPI_WORKLOAD_CLUSTER_NAME}" --timeout=45m

echo "Waiting for workload kubeconfig secret..."
for i in $(seq 1 180); do
  if kubectl -n "${CAPI_NAMESPACE}" get secret "${CAPI_WORKLOAD_CLUSTER_NAME}-kubeconfig" >/dev/null 2>&1; then
    break
  fi
  echo "[$i/180] waiting for ${CAPI_WORKLOAD_CLUSTER_NAME}-kubeconfig secret..."
  sleep 10
done

kubectl -n "${CAPI_NAMESPACE}" get secret "${CAPI_WORKLOAD_CLUSTER_NAME}-kubeconfig" >/dev/null
kubectl get cluster,machinedeployment,kubeadmcontrolplane -n "${CAPI_NAMESPACE}"
echo "::notice::CAPO workload cluster '${CAPI_WORKLOAD_CLUSTER_NAME}' is ready."
