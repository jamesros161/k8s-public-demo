#!/usr/bin/env bash
set -euo pipefail

CAPI_NAMESPACE="${CAPI_NAMESPACE:-capo-system}"
CAPI_WORKLOAD_CLUSTER_NAME="${CAPI_WORKLOAD_CLUSTER_NAME:-${TF_VAR_cluster_name:-vpc-demo}-workload}"
CAPI_WORKLOAD_CLUSTER_NAME="$(echo "${CAPI_WORKLOAD_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
WORKLOAD_KUBECONFIG_SERVER_OVERRIDE="${WORKLOAD_KUBECONFIG_SERVER_OVERRIDE:-}"

if [ -z "${GITHUB_ENV:-}" ]; then
  echo "::error::GITHUB_ENV is not set. This script must run in GitHub Actions."
  exit 1
fi

if [ -z "${CAPI_NAMESPACE}" ] || [ -z "${CAPI_WORKLOAD_CLUSTER_NAME}" ]; then
  echo "::error::CAPI_NAMESPACE and CAPI_WORKLOAD_CLUSTER_NAME must be set."
  exit 1
fi

SECRET_NAME="${CAPI_WORKLOAD_CLUSTER_NAME}-kubeconfig"
RAW_B64="$(kubectl -n "${CAPI_NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.value}' 2>/dev/null || true)"
if [ -z "${RAW_B64}" ]; then
  echo "::error::Workload kubeconfig secret '${SECRET_NAME}' not found in namespace '${CAPI_NAMESPACE}'."
  exit 1
fi

TMP_KUBECONFIG="$(mktemp)"
echo "${RAW_B64}" | base64 -d > "${TMP_KUBECONFIG}"

if [ -n "${WORKLOAD_KUBECONFIG_SERVER_OVERRIDE}" ]; then
  sed -E "s#server: https://.*:6443#server: https://${WORKLOAD_KUBECONFIG_SERVER_OVERRIDE}:6443#" "${TMP_KUBECONFIG}" > "${TMP_KUBECONFIG}.rewritten"
  mv "${TMP_KUBECONFIG}.rewritten" "${TMP_KUBECONFIG}"
fi

WORKLOAD_KUBECONFIG_B64="$(base64 -w0 "${TMP_KUBECONFIG}")"

{
  echo "WORKLOAD_KUBECONFIG_B64=${WORKLOAD_KUBECONFIG_B64}"
  echo "KUBECONFIG_B64=${WORKLOAD_KUBECONFIG_B64}"
  echo "CAPI_AUTOSCALER_CLUSTER_NAME=${CAPI_WORKLOAD_CLUSTER_NAME}"
  echo "CAPI_AUTOSCALER_NAMESPACE=${CAPI_NAMESPACE}"
  echo "CAPI_AUTOSCALER_MACHINE_DEPLOYMENT_NAME=${CAPI_WORKLOAD_CLUSTER_NAME}-md-0"
} >> "${GITHUB_ENV}"

echo "::notice::Exported workload kubeconfig from '${SECRET_NAME}'."
