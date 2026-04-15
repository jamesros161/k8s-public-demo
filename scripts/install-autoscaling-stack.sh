#!/usr/bin/env bash
set -euo pipefail

AUTOSCALER_MODE="${AUTOSCALER_MODE:-openstack}"
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
CAPI_AUTOSCALER_NAMESPACE="${CAPI_AUTOSCALER_NAMESPACE:-${CAPI_NAMESPACE:-capo-system}}"
CAPI_AUTOSCALER_CLUSTER_NAME="${CAPI_AUTOSCALER_CLUSTER_NAME:-${CAPI_WORKLOAD_CLUSTER_NAME:-${TF_VAR_cluster_name:-vpc-demo}-workload}}"
CAPI_MANAGEMENT_KUBECONFIG_B64="${CAPI_MANAGEMENT_KUBECONFIG_B64:-}"

recover_pending_release() {
  local release="$1"
  local ns="$2"
  local status
  local deployed_rev

  if ! status="$(helm status "${release}" -n "${ns}" -o json 2>/dev/null | jq -r '.info.status // empty')"; then
    return 0
  fi

  case "${status}" in
    pending-install|pending-upgrade|pending-rollback)
      echo "::warning::Helm release ${release} is in ${status}; attempting recovery."
      deployed_rev="$(helm history "${release}" -n "${ns}" -o json | jq -r '[.[] | select(.status=="deployed")][-1].revision // empty')"
      if [ -n "${deployed_rev}" ]; then
        helm rollback "${release}" "${deployed_rev}" -n "${ns}" --wait --timeout 5m || true
      else
        helm uninstall "${release}" -n "${ns}" || true
      fi
      ;;
    *)
      ;;
  esac
}

run_helm_with_retry() {
  local release="$1"
  local ns="$2"
  shift 2
  local attempt=1
  local max_attempts=3
  local output

  while [ "${attempt}" -le "${max_attempts}" ]; do
    set +e
    output="$(helm "$@" 2>&1)"
    rc=$?
    set -e

    if [ "${rc}" -eq 0 ]; then
      echo "${output}"
      return 0
    fi

    echo "${output}"
    if echo "${output}" | grep -q "another operation (install/upgrade/rollback) is in progress"; then
      echo "::warning::Helm release lock detected for ${release} (attempt ${attempt}/${max_attempts})."
      recover_pending_release "${release}" "${ns}"
      attempt=$((attempt + 1))
      sleep 5
      continue
    fi

    return "${rc}"
  done

  echo "::error::Failed Helm operation for ${release} after ${max_attempts} attempts."
  return 1
}

install_clusterapi_autoscaler() {
  local mgmt_secret_name="clusterapi-management-kubeconfig"
  local discovery="clusterapi:namespace=${CAPI_AUTOSCALER_NAMESPACE},clusterName=${CAPI_AUTOSCALER_CLUSTER_NAME}"
  local kubeconfig_arg=""
  local volume_mount_block=""
  local volume_block=""

  if [ -n "${CAPI_MANAGEMENT_KUBECONFIG_B64}" ]; then
    local tmp_kcfg
    tmp_kcfg="$(mktemp)"
    echo "${CAPI_MANAGEMENT_KUBECONFIG_B64}" | base64 -d > "${tmp_kcfg}"
    kubectl -n kube-system create secret generic "${mgmt_secret_name}" \
      --from-file=value="${tmp_kcfg}" \
      --dry-run=client \
      -o yaml | kubectl apply -f -
    kubeconfig_arg="            - --kubeconfig=/etc/clusterapi/management-kubeconfig/value"
    volume_mount_block="$(cat <<'EOF'
          volumeMounts:
            - name: management-kubeconfig
              mountPath: /etc/clusterapi/management-kubeconfig
              readOnly: true
EOF
)"
    volume_block="$(cat <<EOF
      volumes:
        - name: management-kubeconfig
          secret:
            secretName: ${mgmt_secret_name}
EOF
)"
  else
    echo "::warning::CAPI_MANAGEMENT_KUBECONFIG_B64 not set; cluster-autoscaler assumes CAPI objects are reachable via in-cluster config."
  fi

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler
rules:
  - apiGroups: [""]
    resources: ["events", "endpoints"]
    verbs: ["create", "patch"]
  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/status"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["endpoints"]
    resourceNames: ["cluster-autoscaler"]
    verbs: ["get", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["watch", "list", "get", "update"]
  - apiGroups: [""]
    resources: ["pods", "services", "replicationcontrollers", "persistentvolumeclaims", "persistentvolumes"]
    verbs: ["watch", "list", "get"]
  - apiGroups: [""]
    resources: ["namespaces", "resourcequotas"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["extensions", "apps"]
    resources: ["replicasets", "daemonsets", "statefulsets"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["watch", "list"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["batch", "extensions"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create"]
  - apiGroups: ["coordination.k8s.io"]
    resourceNames: ["cluster-autoscaler"]
    resources: ["leases"]
    verbs: ["get", "update"]
  - apiGroups: ["cluster.x-k8s.io"]
    resources: ["machines", "machinesets", "machinedeployments", "machinepools"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: ["cluster.x-k8s.io"]
    resources: ["clusters", "machinehealthchecks"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["infrastructure.cluster.x-k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-autoscaler
subjects:
  - kind: ServiceAccount
    name: cluster-autoscaler
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    app.kubernetes.io/name: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cluster-autoscaler
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cluster-autoscaler
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
    spec:
      serviceAccountName: cluster-autoscaler
      priorityClassName: system-cluster-critical
      containers:
        - name: cluster-autoscaler
          image: ${CLUSTER_AUTOSCALER_IMAGE_REPOSITORY}:${CLUSTER_AUTOSCALER_IMAGE_TAG}
          command:
            - ./cluster-autoscaler
            - --v=4
            - --cloud-provider=clusterapi
            - --namespace=${CAPI_AUTOSCALER_NAMESPACE}
            - --node-group-auto-discovery=${discovery}
            - --balance-similar-node-groups=true
            - --skip-nodes-with-local-storage=false
            - --expander=least-waste
            - --stderrthreshold=info
            - --logtostderr=true
${kubeconfig_arg}
          resources:
            requests:
              cpu: 100m
              memory: 300Mi
            limits:
              cpu: 500m
              memory: 600Mi
${volume_mount_block}
${volume_block}
EOF

  kubectl -n kube-system rollout status deploy/cluster-autoscaler --timeout=10m
  echo "::notice::cluster-autoscaler (clusterapi mode) installed or updated."
}

if ! [[ "${AS_NODES_MIN_SIZE}" =~ ^[0-9]+$ ]] || ! [[ "${AS_NODES_MAX_SIZE}" =~ ^[0-9]+$ ]]; then
  echo "::error::AS_NODES_MIN_SIZE and AS_NODES_MAX_SIZE must be integers."
  exit 1
fi

if [ "${AS_NODES_MIN_SIZE}" -gt "${AS_NODES_MAX_SIZE}" ]; then
  echo "::error::AS_NODES_MIN_SIZE cannot be greater than AS_NODES_MAX_SIZE."
  exit 1
fi

echo "::notice::Autoscaler mode: ${AUTOSCALER_MODE}"
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

run_helm_with_retry "metrics-server" "kube-system" "${METRICS_ARGS[@]}"
echo "::notice::metrics-server installed or updated."

if [ "${AUTOSCALER_MODE}" = "clusterapi" ]; then
  install_clusterapi_autoscaler
  exit 0
fi

if [ "${AUTOSCALER_MODE}" != "openstack" ]; then
  echo "::error::AUTOSCALER_MODE must be 'openstack' or 'clusterapi'."
  exit 1
fi

CA_VALUES_FILE="$(mktemp)"
cat > "${CA_VALUES_FILE}" <<EOF
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

run_helm_with_retry "cluster-autoscaler" "kube-system" "${CA_ARGS[@]}"
echo "::notice::cluster-autoscaler installed or updated."
