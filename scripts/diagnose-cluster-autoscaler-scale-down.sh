#!/usr/bin/env bash
# Print nodes, workload layout, and cluster-autoscaler deployment metadata (no CA log dump).
# Run after deleting burst namespaces (or anytime). Does not change the cluster.
#
# Optional env: CA_NAMESPACE (default kube-system)
set -euo pipefail

CA_NAMESPACE="${CA_NAMESPACE:-kube-system}"

echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Running pods outside kube-system (autoscaler only removes nodes it considers empty enough) ==="
kubectl get pods -A --field-selector=status.phase=Running -o wide 2>/dev/null | awk 'NR==1 || $1!="kube-system"' | head -50 || true
echo "(truncated; use kubectl get pods -A -o wide for full list)"

echo ""
echo "=== cluster-autoscaler Deployment ==="
if kubectl get deploy cluster-autoscaler -n "$CA_NAMESPACE" &>/dev/null; then
  CA_DEPLOY=cluster-autoscaler
else
  CA_DEPLOY=$(kubectl get deploy -n "$CA_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'autoscaler' | head -1 || true)
fi
if [[ -z "${CA_DEPLOY:-}" ]]; then
  echo "No deployment matching cluster-autoscaler / *autoscaler* in ${CA_NAMESPACE}."
else
  echo "Using ${CA_NAMESPACE}/${CA_DEPLOY}"
  echo ""
  echo "=== API server vs cluster-autoscaler image ==="
  srv_git=""
  srv_minor=""
  srv_git=$(kubectl version -o jsonpath='{.serverVersion.gitVersion}' 2>/dev/null || true)
  srv_minor=$(kubectl version -o jsonpath='{.serverVersion.minor}' 2>/dev/null | tr -d '+' || true)
  echo "Server: gitVersion=${srv_git:-unknown} minor=${srv_minor:-unknown}"
  echo -n "CA images: "
  kubectl get deploy "$CA_DEPLOY" -n "$CA_NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{" "}{end}' 2>/dev/null || echo "(unknown)"
  echo ""
  if [[ "${srv_minor}" =~ ^[0-9]+$ ]] && (( srv_minor >= 25 )); then
    echo "NOTE: Kubernetes 1.25+ removed policy/v1beta1 PodDisruptionBudget. If CA logs show"
    echo "  'Failed to list *v1beta1.PodDisruptionBudget: the server could not find the requested resource'"
    echo "the cluster-autoscaler image is too old for this API server. Upgrade CA to the same MINOR as"
    echo "the server (e.g. registry.k8s.io/autoscaling/cluster-autoscaler:v1.26.x for Kubernetes 1.26),"
    echo "via a newer Magnum cluster template or by patching the Deployment image (ops/demo only)."
    echo ""
  fi
  echo "--- args (scale-down timers) ---"
  kubectl get deploy "$CA_DEPLOY" -n "$CA_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | tr ' ' '\n' | grep -E '^--scale-down' \
    || echo "(no --scale-down-* args on container 0; defaults are often ~10m)"
fi

echo ""
echo "=== Hints ==="
echo "1. Scale-down is delayed by --scale-down-unneeded-time and --scale-down-delay-after-add (often ~10m each unless you run workflow tune-cluster-autoscaler-demo)."
echo "2. Magnum min_node_count (Terraform autoscaler_min_nodes, often 2) is a floor — extra workers should shrink toward that, not below."
echo "3. CA often will not remove a node that still runs non-DaemonSet pods it cannot move (kube-system, Traefik, monitoring, etc.)."
echo "4. For CA messages: kubectl logs -n ${CA_NAMESPACE} deploy/${CA_DEPLOY:-cluster-autoscaler} --tail=100"
echo "5. PDB v1beta1 list errors + no scale-up: see NOTE under 'API server vs cluster-autoscaler image' above."
