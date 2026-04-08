#!/usr/bin/env bash
# Run from CI or locally with kubeconfig; bootstraps WordPress via WP-CLI inside the cluster.
# Required env: DEPLOY_NAMESPACE, SITE_ID, APP_TYPE, DOMAIN_BASE, WP_SITE_TITLE, WP_ADMIN_USER,
#               WP_ADMIN_EMAIL, WP_ADMIN_PASSWORD, MARIADB_ROOT_PASSWORD, DB_APP_PASSWORD
# Optional env: WP_TAGLINE (default empty), DB_APP_USER (default admin), DB_APP_NAME (default wordpress)
set -euo pipefail

: "${DEPLOY_NAMESPACE:?}"
: "${SITE_ID:?}"
: "${APP_TYPE:?}"
: "${DOMAIN_BASE:?}"
: "${WP_SITE_TITLE:?}"
: "${WP_ADMIN_USER:?}"
: "${WP_ADMIN_EMAIL:?}"
: "${WP_ADMIN_PASSWORD:?}"
: "${MARIADB_ROOT_PASSWORD:?}"
: "${DB_APP_PASSWORD:?}"

DB_APP_USER="${DB_APP_USER:-admin}"
DB_APP_NAME="${DB_APP_NAME:-wordpress}"

WP_TAGLINE="${WP_TAGLINE:-}"

if [ "${APP_TYPE}" != "wordpress" ]; then
  echo "APP_TYPE must be wordpress (got ${APP_TYPE})"
  exit 1
fi

WP_URL="https://${SITE_ID}.${APP_TYPE}.${DOMAIN_BASE}/"
DEPLOY_NAME="${APP_TYPE}"

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

# On a fresh PVC, mysqld can answer root ping before the entrypoint finishes creating
# MARIADB_USER / MARIADB_DATABASE. WordPress then fails with "Error establishing a database connection".
echo "Waiting for application user and database (matches Helm db.user / app database name)..."
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
  echo "::error::Timed out waiting for DB user '${DB_APP_USER}' / database '${DB_APP_NAME}' on mariadb-0."
  echo "Check Helm db.user, db.password, and that this matches values.yaml defaults unless you override them."
  kubectl exec -n "${DEPLOY_NAMESPACE}" "mariadb-0" -- \
    env MYSQL_PWD="${DB_APP_PASSWORD}" \
    mariadb -u"${DB_APP_USER}" -D "${DB_APP_NAME}" -e "SELECT 1" 2>&1 || true
  exit 1
fi

echo "Waiting for WordPress deployment rollout..."
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${DEPLOY_NAMESPACE}" --timeout=600s

echo "Running WP-CLI bootstrap (idempotent if already installed)..."
kubectl exec -i -n "${DEPLOY_NAMESPACE}" "deployment/${DEPLOY_NAME}" -- \
  env \
  WP_URL="${WP_URL}" \
  WP_TITLE="${WP_SITE_TITLE}" \
  WP_TAGLINE="${WP_TAGLINE}" \
  WP_ADMIN_USER="${WP_ADMIN_USER}" \
  WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL}" \
  WP_ADMIN_PASSWORD="${WP_ADMIN_PASSWORD}" \
  sh -s <<'ENDREMOTE'
set -e
cd /var/www/html
# DB can be reachable before docker-entrypoint finishes copying core from /usr/src/wordpress (race if pod has no readiness probe).
echo "Waiting for WordPress core files under /var/www/html..."
core_ok=0
for attempt in $(seq 1 120); do
  if [ -f wp-load.php ] && [ -f wp-includes/version.php ]; then
    core_ok=1
    break
  fi
  echo "WordPress core not present yet (attempt ${attempt}/120); entrypoint copy may still be running..."
  sleep 2
done
if [ "${core_ok}" != 1 ]; then
  echo "::error::Timed out waiting for WordPress files. If this persists, check the app pod logs (docker-entrypoint copy step)."
  ls -la
  exit 1
fi
if [ ! -f wp-cli.phar ]; then
  curl -fsSL -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
fi
export PAGER=cat
echo "Checking database connectivity from WordPress pod (mysqli; official image has no mysqlcheck)..."
ok=0
for attempt in $(seq 1 45); do
  if php -r '
    $h = getenv("WORDPRESS_DB_HOST") ?: "";
    $u = getenv("WORDPRESS_DB_USER") ?: "";
    $p = getenv("WORDPRESS_DB_PASSWORD");
    $n = getenv("WORDPRESS_DB_NAME") ?: "";
    if ($h === "" || $u === "" || $n === "") { fwrite(STDERR, "missing WORDPRESS_DB_* env\n"); exit(1); }
    $m = @new mysqli($h, $u, $p ?: "", $n);
    if ($m->connect_errno) { fwrite(STDERR, $m->connect_error . "\n"); exit(1); }
    $m->close();
    exit(0);
  ' 2>/dev/null; then
    ok=1
    break
  fi
  echo "DB not reachable from app pod (attempt ${attempt}/45), retrying..."
  php -r '
    $h = getenv("WORDPRESS_DB_HOST") ?: "";
    $u = getenv("WORDPRESS_DB_USER") ?: "";
    $p = getenv("WORDPRESS_DB_PASSWORD");
    $n = getenv("WORDPRESS_DB_NAME") ?: "";
    $m = @new mysqli($h, $u, $p ?: "", $n);
    if ($m->connect_errno) { fwrite(STDERR, $m->connect_error . "\n"); }
    if ($m) { $m->close(); }
  ' 2>&1 || true
  sleep 2
done
if [ "$ok" != 1 ]; then
  echo "WordPress still cannot reach the database. Common causes:"
  echo "  - DEMO_DB_PASSWORD / Helm db.password changed after MariaDB first ran (app user password is in the PVC; use ALTER USER or delete the MariaDB PVC)."
  echo "  - MariaDB not ready or Service mariadb has no endpoints."
  exit 1
fi
if php wp-cli.phar core is-installed --allow-root 2>/dev/null; then
  echo "WordPress already installed; syncing admin password, title, and tagline."
  php wp-cli.phar user update "${WP_ADMIN_USER}" --user_pass="${WP_ADMIN_PASSWORD}" --allow-root
  php wp-cli.phar option update blogname "${WP_TITLE}" --allow-root
  php wp-cli.phar option update blogdescription "${WP_TAGLINE}" --allow-root
  exit 0
fi
php wp-cli.phar core install \
  --allow-root \
  --url="${WP_URL}" \
  --title="${WP_TITLE}" \
  --admin_user="${WP_ADMIN_USER}" \
  --admin_password="${WP_ADMIN_PASSWORD}" \
  --admin_email="${WP_ADMIN_EMAIL}" \
  --skip-email
php wp-cli.phar option update blogdescription "${WP_TAGLINE}" --allow-root
echo "WordPress core install finished."
ENDREMOTE

echo "Done. Site URL: ${WP_URL}"
