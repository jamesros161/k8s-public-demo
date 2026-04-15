#!/usr/bin/env bash
set -euo pipefail

CAPI_NAMESPACE="${CAPI_NAMESPACE:-capo-system}"
CAPI_WORKLOAD_CLUSTER_NAME="${CAPI_WORKLOAD_CLUSTER_NAME:-${TF_VAR_cluster_name:-vpc-demo}-workload}"
CAPI_WORKLOAD_CLUSTER_NAME="$(echo "${CAPI_WORKLOAD_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"

if ! kubectl get namespace "${CAPI_NAMESPACE}" >/dev/null 2>&1; then
  echo "::notice::Namespace '${CAPI_NAMESPACE}' not found; skipping CAPI workload delete."
  exit 0
fi

if ! kubectl -n "${CAPI_NAMESPACE}" get cluster "${CAPI_WORKLOAD_CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "::notice::Cluster '${CAPI_WORKLOAD_CLUSTER_NAME}' not found in '${CAPI_NAMESPACE}'; skipping."
  exit 0
fi

echo "Deleting CAPO workload Cluster ${CAPI_NAMESPACE}/${CAPI_WORKLOAD_CLUSTER_NAME}..."
kubectl -n "${CAPI_NAMESPACE}" delete cluster "${CAPI_WORKLOAD_CLUSTER_NAME}" --wait=false

echo "Waiting for OpenStack resources to drain from CAPO..."
kubectl wait --namespace "${CAPI_NAMESPACE}" --for=delete "openstackcluster/${CAPI_WORKLOAD_CLUSTER_NAME}" --timeout=45m || true
kubectl wait --namespace "${CAPI_NAMESPACE}" --for=delete "cluster/${CAPI_WORKLOAD_CLUSTER_NAME}" --timeout=45m || true

if kubectl -n "${CAPI_NAMESPACE}" get cluster "${CAPI_WORKLOAD_CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "::warning::Cluster ${CAPI_WORKLOAD_CLUSTER_NAME} still exists; Terraform destroy will continue."
else
  echo "::notice::CAPO workload cluster deleted."
fi
