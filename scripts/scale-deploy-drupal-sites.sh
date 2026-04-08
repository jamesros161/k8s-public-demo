#!/usr/bin/env bash
# Parallel Helm installs of Drupal site-template stacks (no Drush, no admin Secret).
# Intended to schedule enough requested memory to trigger cluster autoscaling.
#
# Required env: SITE_COUNT, HELM_PARALLEL, DOMAIN_BASE, DB_PASS, DB_ROOT,
#               DRUPAL_ADMIN_PASSWORD
# Optional: DRUPAL_ADMIN_USER (default admin), CHART_PATH (default ./helm/site-template),
#           SITE_ID_PREFIX (default scale-${RUN_ID}), RUN_ID (required if SITE_ID_PREFIX unset)
set -euo pipefail

SITE_COUNT="${SITE_COUNT:?}"
HELM_PARALLEL="${HELM_PARALLEL:?}"
if ! [[ "${SITE_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SITE_COUNT must be a positive integer (got ${SITE_COUNT})" >&2
  exit 1
fi
if ! [[ "${HELM_PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
  echo "HELM_PARALLEL must be a positive integer (got ${HELM_PARALLEL})" >&2
  exit 1
fi
DOMAIN_BASE="${DOMAIN_BASE:-k8sdemo.example.com}"
DB_PASS="${DB_PASS:?}"
DB_ROOT="${DB_ROOT:?}"
DRUPAL_ADMIN_PASSWORD="${DRUPAL_ADMIN_PASSWORD:?}"
DRUPAL_ADMIN_USER="${DRUPAL_ADMIN_USER:-admin}"
CHART_PATH="${CHART_PATH:-./helm/site-template}"

if [ -z "${SITE_ID_PREFIX:-}" ]; then
  RUN_ID="${RUN_ID:?}"
  SITE_ID_PREFIX="scale-${RUN_ID}-"
fi

export PREFIX="${SITE_ID_PREFIX}"
export DOMAIN_BASE DB_PASS DB_ROOT DRUPAL_ADMIN_PASSWORD DRUPAL_ADMIN_USER CHART_PATH

seq 1 "${SITE_COUNT}" | xargs -P "${HELM_PARALLEL}" -n 1 bash -c '
  set -euo pipefail
  i="$1"
  SITE_ID="${PREFIX}$(printf "%03d" "$i")"
  echo "Helm install ${SITE_ID} -> namespace ${SITE_ID}-drupal"
  helm upgrade --install "$SITE_ID" "${CHART_PATH}" \
    --namespace "${SITE_ID}-drupal" \
    --create-namespace \
    --set "siteId=${SITE_ID}" \
    --set "appType=drupal" \
    --set "domainBase=${DOMAIN_BASE}" \
    --set-string "db.password=${DB_PASS}" \
    --set-string "db.rootPassword=${DB_ROOT}" \
    --set-string "drupal.adminPassword=${DRUPAL_ADMIN_PASSWORD}" \
    --set-string "drupal.adminUser=${DRUPAL_ADMIN_USER}"
' bash

echo "Done. ${SITE_COUNT} Drupal releases installed (Helm only). Admin password is unchanged from Bitnami env until you run drupal-drush-bootstrap or redeploy via full deploy-site workflow."
