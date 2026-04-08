#!/usr/bin/env bash
# Reapply the common Magnum / Flannel workaround when Quay blocks pulls of coreos/* images
# (401 anonymous, egress, etc.). Run as soon as you have a working kubeconfig for the cluster.
#
# Default: only the init container that most often fails first.
# If the main flannel image also fails from Quay, run:  PATCH_FLANNEL_MAIN=true bash scripts/patch-flannel-quay-to-dockerhub.sh
#
# Ref: internal operator runbooks (Flannel / Quay); Launchpad #2119662
set -euo pipefail

NS=kube-system
DS=kube-flannel-ds

echo "Waiting for DaemonSet ${NS}/${DS} (Magnum often creates it shortly after API is up)..."
found=0
for i in $(seq 1 120); do
  if kubectl get "daemonset/${DS}" -n "${NS}" >/dev/null 2>&1; then
    found=1
    break
  fi
  echo "  ($i/120) ${DS} not yet present, sleeping 10s..."
  sleep 10
done
if [ "$found" != 1 ]; then
  echo "::error::${NS}/${DS} not found after ~20m — not a Flannel cluster, or addons very delayed. Set SKIP_FLANNEL_QUAY_PATCH=true if you use Calico, or fix the cluster."
  exit 1
fi

echo "Patching ${NS}/${DS} init container install-cni-plugins → docker.io/rancher/coreos-flannel-cni:v0.3.0"
kubectl -n "${NS}" set image "daemonset/${DS}" \
  install-cni-plugins=docker.io/rancher/coreos-flannel-cni:v0.3.0

if [[ "${PATCH_FLANNEL_MAIN:-}" == "true" ]]; then
  echo "Patching main container kube-flannel → docker.io/rancher/flannel:v0.15.1"
  kubectl -n "${NS}" set image "daemonset/${DS}" \
    kube-flannel=docker.io/rancher/flannel:v0.15.1
fi

echo "Rollout status:"
kubectl -n "${NS}" rollout status "daemonset/${DS}" --timeout=5m || true
echo "Done. Check: kubectl get pods -n ${NS} -l app=flannel && kubectl get nodes"
