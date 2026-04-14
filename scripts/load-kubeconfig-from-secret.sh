#!/usr/bin/env bash
set -euo pipefail

if [ -z "${KUBECONFIG_B64:-}" ]; then
  echo "::error::Missing KUBECONFIG_B64 in environment."
  echo "::error::Set KUBECONFIG_B64 inside CLOUD_ADMIN_CONFIG_B64."
  exit 1
fi

mkdir -p "$HOME/.kube"
echo "${KUBECONFIG_B64}" | base64 -d >"$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
echo "KUBECONFIG=$HOME/.kube/config" >>"$GITHUB_ENV"

if ! kubectl config current-context >/dev/null 2>&1; then
  echo "::error::Loaded kubeconfig is invalid or does not contain a current-context."
  exit 1
fi

echo "::notice::Kubeconfig loaded from KUBECONFIG_B64."
