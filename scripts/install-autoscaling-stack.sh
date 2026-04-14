#!/usr/bin/env bash
set -euo pipefail

METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-}"
CLUSTER_AUTOSCALER_CHART_VERSION="${CLUSTER_AUTOSCALER_CHART_VERSION:-}"
CLUSTER_AUTOSCALER_IMAGE_REPOSITORY="${CLUSTER_AUTOSCALER_IMAGE_REPOSITORY:-registry.k8s.io/autoscaling/cluster-autoscaler}"
K8S_REPO_CHANNEL="${TF_VAR_k8s_repo_channel:-v1.29}"
K8S_MINOR="$(echo "${K8S_REPO_CHANNEL}" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')"
DEFAULT_CA_IMAGE_TAG="v${K8S_MINOR}.0"
CLUSTER_AUTOSCALER_IMAGE_TAG="${CLUSTER_AUTOSCALER_IMAGE_TAG:-${DEFAULT_CA_IMAGE_TAG}}"
AS_CLUSTER_NAME_RAW="${AS_CLUSTER_NAME:-${TF_VAR_cluster_name:-vpc-demo-cluster}}"
AS_CLUSTER_NAME="$(echo "${AS_CLUSTER_NAME_RAW}" | tr '[:upper:]' '[:lower:]')"
AS_GROUP_NAME="${AS_GROUP_NAME:-${AS_CLUSTER_NAME}-worker}"
AS_NODES_MIN_SIZE="${AS_NODES_MIN_SIZE:-${TF_VAR_k8s_worker_count:-2}}"
AS_NODES_MAX_SIZE="${AS_NODES_MAX_SIZE:-${TF_VAR_k8s_worker_max_count:-${AS_NODES_MIN_SIZE}}}"

if ! [[ "${AS_NODES_MIN_SIZE}" =~ ^[0-9]+$ ]] || ! [[ "${AS_NODES_MAX_SIZE}" =~ ^[0-9]+$ ]]; then
  echo "::error::AS_NODES_MIN_SIZE and AS_NODES_MAX_SIZE must be integers."
  exit 1
fi

if [ "${AS_NODES_MIN_SIZE}" -gt "${AS_NODES_MAX_SIZE}" ]; then
  echo "::error::AS_NODES_MIN_SIZE cannot be greater than AS_NODES_MAX_SIZE."
  exit 1
fi

echo "::notice::Autoscaler config: cluster=${AS_CLUSTER_NAME} group=${AS_GROUP_NAME} min=${AS_NODES_MIN_SIZE} max=${AS_NODES_MAX_SIZE}"
echo "::notice::Autoscaler image: ${CLUSTER_AUTOSCALER_IMAGE_REPOSITORY}:${CLUSTER_AUTOSCALER_IMAGE_TAG}"

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update

METRICS_ARGS=(
  upgrade --install metrics-server metrics-server/metrics-server
  --namespace kube-system
  --set-json 'args=["--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"]'
  --wait
  --timeout 10m
)

if [ -n "${METRICS_SERVER_CHART_VERSION}" ]; then
  METRICS_ARGS+=(--version "${METRICS_SERVER_CHART_VERSION}")
fi

helm "${METRICS_ARGS[@]}"
echo "::notice::metrics-server installed or updated."

CA_VALUES_FILE="$(mktemp)"
cat >"${CA_VALUES_FILE}" <<EOF
cloudProvider: openstack

rbac:
  create: true

autoDiscovery:
  clusterName: "${AS_CLUSTER_NAME}"

autoscalingGroups:
  - name: "${AS_GROUP_NAME}"
    minSize: ${AS_NODES_MIN_SIZE}
    maxSize: ${AS_NODES_MAX_SIZE}

extraArgs:
  cloud-provider: openstack
  balance-similar-node-groups: "true"
  skip-nodes-with-local-storage: "false"
  expander: least-waste
image:
  repository: "${CLUSTER_AUTOSCALER_IMAGE_REPOSITORY}"
  tag: "${CLUSTER_AUTOSCALER_IMAGE_TAG}"
EOF

CA_ARGS=(
  upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler
  --namespace kube-system
  -f "${CA_VALUES_FILE}"
  --wait
  --timeout 10m
)

if [ -n "${CLUSTER_AUTOSCALER_CHART_VERSION}" ]; then
  CA_ARGS+=(--version "${CLUSTER_AUTOSCALER_CHART_VERSION}")
fi

helm "${CA_ARGS[@]}"
echo "::notice::cluster-autoscaler installed or updated."
