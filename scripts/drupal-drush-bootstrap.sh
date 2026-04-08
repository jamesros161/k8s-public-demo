#!/usr/bin/env bash
# Run from CI or locally with kubeconfig. Syncs Bitnami Drupal admin password via Drush
# (Helm sets DRUPAL_PASSWORD on first install; redeploys need drush user:password).
# Required env: DEPLOY_NAMESPACE, SITE_ID, APP_TYPE, DOMAIN_BASE, DRUPAL_ADMIN_PASSWORD,
#               DRUPAL_ADMIN_USER, MARIADB_ROOT_PASSWORD, DB_APP_PASSWORD
# Optional: DB_APP_USER (default admin), DB_APP_NAME (default drupal)
set -euo pipefail

: "${DEPLOY_NAMESPACE:?}"
: "${SITE_ID:?}"
: "${APP_TYPE:?}"
: "${DOMAIN_BASE:?}"
: "${DRUPAL_ADMIN_PASSWORD:?}"
: "${DRUPAL_ADMIN_USER:?}"
: "${MARIADB_ROOT_PASSWORD:?}"
: "${DB_APP_PASSWORD:?}"

DB_APP_USER="${DB_APP_USER:-admin}"
DB_APP_NAME="${DB_APP_NAME:-drupal}"

if [ "${APP_TYPE}" != "drupal" ]; then
  echo "APP_TYPE must be drupal (got ${APP_TYPE})"
  exit 1
fi

DEPLOY_NAME="${APP_TYPE}"
SITE_URL="https://${SITE_ID}.${APP_TYPE}.${DOMAIN_BASE}/"

echo "Waiting for MariaDB pod ready..."
kubectl wait --for=condition=ready "pod/mariadb-0" -n "${DEPLOY_NAMESPACE}" --timeout=600s

echo "Waiting for MariaDB to accept connections (root ping)..."
for _ in $(seq 1 120); do
  if kubectl exec -n "${DEPLOY_NAMESPACE}" "mariadb-0" -- \
    mariadb-admin ping -uroot -p"${MARIADB_ROOT_PASSWORD}" --silent 2>/dev/null; then
    break
  fi
  sleep 2
done

echo "Waiting for application user and database..."
app_ok=0
for _ in $(seq 1 120); do
  if kubectl exec -n "${DEPLOY_NAMESPACE}" "mariadb-0" -- \
    env MYSQL_PWD="${DB_APP_PASSWORD}" \
    mariadb -u"${DB_APP_USER}" -D "${DB_APP_NAME}" -e "SELECT 1" --silent 2>/dev/null; then
    app_ok=1
    break
  fi
  sleep 2
done
if [ "${app_ok}" != 1 ]; then
  echo "::error::Timed out waiting for DB user/database on mariadb-0."
  exit 1
fi

echo "Waiting for Drupal deployment rollout..."
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${DEPLOY_NAMESPACE}" --timeout=600s

echo "Waiting for Drupal bootstrap + Drush (Bitnami install can take several minutes)..."
ready=0
for attempt in $(seq 1 120); do
  if kubectl exec -n "${DEPLOY_NAMESPACE}" "deployment/${DEPLOY_NAME}" -- \
    bash -ec 'cd /opt/bitnami/drupal && \
      if command -v drush >/dev/null 2>&1; then D=drush; \
      elif [ -x vendor/bin/drush ]; then D="php vendor/bin/drush"; \
      else D="php vendor/bin/drush.php"; fi; \
      $D status 2>/dev/null | grep -qiE "bootstrap.*successful"'; then
    ready=1
    break
  fi
  echo "  Drupal not fully bootstrapped yet (${attempt}/120), sleeping 10s..."
  sleep 10
done
if [ "${ready}" != 1 ]; then
  echo "::error::Timed out waiting for Drupal to finish installing."
  kubectl exec -n "${DEPLOY_NAMESPACE}" "deployment/${DEPLOY_NAME}" -- \
    bash -ec 'cd /opt/bitnami/drupal && (command -v drush && drush status) || ls -la vendor/bin/ 2>&1 || true' || true
  exit 1
fi

echo "Setting Drupal admin password via Drush (idempotent)..."
kubectl exec -n "${DEPLOY_NAMESPACE}" "deployment/${DEPLOY_NAME}" -- \
  env DRUPAL_NEW_PASS="${DRUPAL_ADMIN_PASSWORD}" DRUPAL_ADMIN_NAME="${DRUPAL_ADMIN_USER}" \
  bash -ec 'cd /opt/bitnami/drupal && \
    if command -v drush >/dev/null 2>&1; then D=drush; \
    elif [ -x vendor/bin/drush ]; then D="php vendor/bin/drush"; \
    else D="php vendor/bin/drush.php"; fi; \
    $D user:password "$DRUPAL_ADMIN_NAME" "$DRUPAL_NEW_PASS" -y'

echo "Done. Site URL: ${SITE_URL}"
