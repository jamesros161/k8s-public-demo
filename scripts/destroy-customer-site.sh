#!/usr/bin/env bash
# Remove one site deployed by Site - Deploy (namespace {site_id}-{wordpress|drupal}).
#
# Required env: SITE_ID, APP_TYPE (wordpress|drupal)
# Optional: DRY_RUN=1 — print action only, do not delete
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_SITE_ID="${SITE_ID:?}"
SITE_ID="$("${SCRIPT_DIR}/normalize-site-id.sh" "${RAW_SITE_ID}")"
APP_TYPE="${APP_TYPE:?}"

if [[ "${APP_TYPE}" != "wordpress" && "${APP_TYPE}" != "drupal" ]]; then
  echo "APP_TYPE must be wordpress or drupal (got ${APP_TYPE})" >&2
  exit 1
fi

NS="${SITE_ID}-${APP_TYPE}"

if ! kubectl get ns "${NS}" &>/dev/null; then
  echo "Namespace ${NS} does not exist — nothing to do."
  exit 0
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN=1 — would delete namespace ${NS}"
  exit 0
fi

kubectl delete namespace "${NS}" --wait=false
echo "Delete issued for namespace ${NS} (--wait=false). Helm release metadata, PVCs, and data are removed with the namespace."
