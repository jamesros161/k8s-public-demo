#!/usr/bin/env bash
# Remove namespaces created by scale-deploy-drupal-sites.sh / scale-cluster-drupal workflow.
# Namespace shape: scale-<github_run_id>-<nnn>-drupal
#
# Optional env:
#   RUN_ID_FILTER  — if set (digits only), only namespaces for that run id
#   DRY_RUN=1      — print matches only, do not delete
set -euo pipefail

PATTERN='^scale-[0-9]+-[0-9]+-drupal$'
if [ -n "${RUN_ID_FILTER:-}" ]; then
  if ! [[ "${RUN_ID_FILTER}" =~ ^[0-9]+$ ]]; then
    echo "RUN_ID_FILTER must contain digits only (got ${RUN_ID_FILTER})" >&2
    exit 1
  fi
  PATTERN="^scale-${RUN_ID_FILTER}-[0-9]+-drupal$"
fi

mapfile -t NS_LIST < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "${PATTERN}" || true)

if [ "${#NS_LIST[@]}" -eq 0 ]; then
  echo "No namespaces matched pattern: ${PATTERN}"
  exit 0
fi

echo "Matched ${#NS_LIST[@]} namespace(s):"
printf '  %s\n' "${NS_LIST[@]}"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN=1 — no changes made."
  exit 0
fi

kubectl delete namespace "${NS_LIST[@]}" --wait=false
echo "Delete issued for ${#NS_LIST[@]} namespace(s) (--wait=false). Pods will terminate asynchronously; cluster-autoscaler scale-down follows its usual delay."
