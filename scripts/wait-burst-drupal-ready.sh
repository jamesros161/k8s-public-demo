#!/usr/bin/env bash
# After scale-deploy-drupal-sites.sh: poll cluster until every burst
# namespace has StatefulSet/mariadb and Deployment/drupal fully ready (or timeout).
#
# Required env: RUN_ID
# Optional: MAX_WAIT_SECONDS (default 2400), POLL_SECONDS (default 15),
#           EXPECTED_SITE_COUNT (warn if namespace count differs)
set -euo pipefail

RUN_ID="${RUN_ID:?}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-2400}"
POLL_SECONDS="${POLL_SECONDS:-15}"

if ! [[ "${MAX_WAIT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${POLL_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "MAX_WAIT_SECONDS and POLL_SECONDS must be positive integers" >&2
  exit 1
fi

mapfile -t NS_LIST < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "^scale-${RUN_ID}-[0-9]+-drupal$" | sort -V || true)

if [ "${#NS_LIST[@]}" -eq 0 ]; then
  echo "::error::No burst namespaces found matching scale-${RUN_ID}-*-drupal"
  exit 1
fi

if [ -n "${EXPECTED_SITE_COUNT:-}" ]; then
  if [ "${#NS_LIST[@]}" -ne "${EXPECTED_SITE_COUNT}" ]; then
    echo "::warning::EXPECTED_SITE_COUNT=${EXPECTED_SITE_COUNT} but found ${#NS_LIST[@]} namespace(s); continuing with discovered list."
  fi
fi

echo "Waiting on ${#NS_LIST[@]} burst namespace(s) (timeout ${MAX_WAIT_SECONDS}s, poll ${POLL_SECONDS}s)."

is_sts_ready() {
  local ns="$1" r w
  r=$(kubectl get sts mariadb -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  w=$(kubectl get sts mariadb -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [[ -n "$w" && "$r" == "$w" ]]
}

is_drupal_available() {
  local ns="$1" st
  st=$(kubectl get deploy drupal -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
  [[ "$st" == "True" ]]
}

burst_pending_count() {
  local ns c sum=0
  for ns in "${NS_LIST[@]}"; do
    c=$(kubectl get pods -n "$ns" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
    sum=$((sum + c))
  done
  echo "$sum"
}

start_epoch=$(date +%s)
deadline=$((start_epoch + MAX_WAIT_SECONDS))
iteration=0

while true; do
  iteration=$((iteration + 1))
  echo "::group::Burst wait #${iteration} ($(date -u +%Y-%m-%dT%H:%M:%SZ))"

  echo "--- nodes ($(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') total) ---"
  kubectl get nodes -o wide 2>/dev/null || true

  pending_total=$(burst_pending_count)
  echo "--- burst Pending pod count (all burst namespaces): ${pending_total} ---"
  if [[ "$pending_total" -gt 0 ]]; then
    for ns in "${NS_LIST[@]}"; do
      kubectl get pods -n "$ns" --field-selector=status.phase=Pending -o wide 2>/dev/null || true
    done | head -80
    if [[ "$pending_total" -gt 5 ]]; then
      echo "(output may be truncated; ${pending_total} pending total in burst namespaces)"
    fi
  fi

  echo "--- burst workloads (replicas) ---"
  for ns in "${NS_LIST[@]}"; do
    printf '  %s: ' "$ns"
    kubectl get sts/mariadb -n "$ns" --no-headers 2>/dev/null | tr '\n' ' '
    kubectl get deploy/drupal -n "$ns" --no-headers 2>/dev/null | tr '\n' ' '
    echo
  done

  all_ready=true
  for ns in "${NS_LIST[@]}"; do
    if ! is_sts_ready "$ns"; then
      all_ready=false
      break
    fi
    if ! is_drupal_available "$ns"; then
      all_ready=false
      break
    fi
  done

  echo "::endgroup::"

  if $all_ready; then
    echo "::notice::All ${#NS_LIST[@]} burst sites report MariaDB StatefulSet ready and Drupal Deployment Available."
    echo "--- final node list ---"
    kubectl get nodes -o wide
    echo "--- final pod summary (burst namespaces) ---"
    for ns in "${NS_LIST[@]}"; do
      echo "# ${ns}"
      kubectl get pods -n "$ns" -o wide
    done
    exit 0
  fi

  now=$(date +%s)
  if (( now >= deadline )); then
    echo "::error::Timed out after ${MAX_WAIT_SECONDS}s — burst sites or autoscaling did not reach ready state."
    kubectl get pods -A --field-selector=status.phase=Pending -o wide 2>/dev/null | head -60 || true
    exit 1
  fi

  echo "Not all ready yet; sleeping ${POLL_SECONDS}s (${pending_total} pending in burst ns) ..."
  sleep "$POLL_SECONDS"
done
