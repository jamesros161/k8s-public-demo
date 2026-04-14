#!/usr/bin/env bash
# Remove all customer site namespaces from Site - Deploy: names ending in -wordpress or -drupal.
# Excludes burst demo namespaces (scale-<run_id>-<nnn>-drupal) and core cluster namespaces.
#
# Optional env: DRY_RUN=1 — list matches only, do not delete
set -euo pipefail

BURST_RE='^scale-[0-9]+-[0-9]+-drupal$'
DENY_REGEX='^(default|kube-system|kube-public|kube-node-lease|traefik|headlamp)$'

mapfile -t ALL_NS < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

MATCHED=()
for ns in "${ALL_NS[@]}"; do
  [[ -z "${ns}" ]] && continue
  [[ "${ns}" =~ ${DENY_REGEX} ]] && continue
  [[ "${ns}" =~ ${BURST_RE} ]] && continue
  if [[ "${ns}" == *-wordpress ]] || [[ "${ns}" == *-drupal ]]; then
    MATCHED+=("${ns}")
  fi
done

if [ "${#MATCHED[@]}" -eq 0 ]; then
  echo "No customer site namespaces matched (*-wordpress / *-drupal, excluding burst pattern)."
  exit 0
fi

echo "Matched ${#MATCHED[@]} namespace(s):"
printf '  %s\n' "${MATCHED[@]}"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN=1 — no changes made."
  exit 0
fi

kubectl delete namespace "${MATCHED[@]}" --wait=false
echo "Delete issued for ${#MATCHED[@]} namespace(s) (--wait=false). Burst Drupal namespaces (scale-*-drupal) were not selected."
