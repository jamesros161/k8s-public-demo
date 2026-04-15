#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLOUDS_FILE="${REPO_ROOT}/clouds.yaml"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' is required but not installed."
    exit 1
  fi
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local result=""
  read -r -p "${prompt} [${default_value}]: " result
  if [ -z "${result}" ]; then
    result="${default_value}"
  fi
  printf '%s' "${result}"
}

prompt_required() {
  local prompt="$1"
  local result=""
  while true; do
    read -r -p "${prompt}: " result
    if [ -n "${result}" ]; then
      printf '%s' "${result}"
      return
    fi
    echo "Value is required."
  done
}

prompt_optional() {
  local prompt="$1"
  local result=""
  read -r -p "${prompt} (optional): " result
  printf '%s' "${result}"
}

prompt_required_secret() {
  local prompt="$1"
  local result=""
  while true; do
    read -r -s -p "${prompt}: " result
    echo
    if [ -n "${result}" ]; then
      printf '%s' "${result}"
      return
    fi
    echo "Value is required."
  done
}

normalize_identity_v3_url() {
  local auth_url="${1%/}"
  if [[ "${auth_url}" =~ /v3$ ]]; then
    printf '%s' "${auth_url}"
  else
    printf '%s/v3' "${auth_url}"
  fi
}

generate_join_token() {
  local part1 part2
  part1="$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  part2="$(tr -dc 'a-z0-9' </dev/urandom | head -c 16)"
  printf '%s.%s' "${part1}" "${part2}"
}

create_app_credential() {
  local identity_v3_url="$1"
  local token="$2"
  local user_id="$3"
  local project_id="$4"
  local cred_name="$5"
  local cred_secret="$6"

  local payload
  payload="$(jq -n \
    --arg name "${cred_name}" \
    --arg secret "${cred_secret}" \
    --arg project_id "${project_id}" \
    --arg description "k8s-public-demo generated $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{application_credential:{name:$name,secret:$secret,project_id:$project_id,description:$description}}')"

  curl -sS -X POST \
    -H "X-Auth-Token: ${token}" \
    -H "Content-Type: application/json" \
    "${identity_v3_url}/users/${user_id}/application_credentials" \
    -d "${payload}"
}

delete_app_credential() {
  local identity_v3_url="$1"
  local token="$2"
  local user_id="$3"
  local app_cred_id="$4"

  curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "X-Auth-Token: ${token}" \
    "${identity_v3_url}/users/${user_id}/application_credentials/${app_cred_id}"
}

require_cmd openstack
require_cmd jq
require_cmd curl
require_cmd openssl
require_cmd base64

if [ ! -f "${CLOUDS_FILE}" ]; then
  echo "ERROR: clouds.yaml not found at ${CLOUDS_FILE}"
  echo "Place clouds.yaml in the repository root, then rerun this script."
  exit 1
fi

# Force clouds.yaml-driven auth by removing any pre-exported OS_* auth/scope variables.
# These can silently override clouds.yaml and cause unexpected project-scoped tokens.
SCRUBBED_OS_VARS=()
while IFS='=' read -r key _; do
  case "${key}" in
    OS_CLIENT_CONFIG_FILE|OS_CLOUD) continue ;;
    OS_*)
      if [ -n "${!key:-}" ]; then
        SCRUBBED_OS_VARS+=("${key}")
      fi
      unset "${key}"
      ;;
  esac
done < <(env)

export OS_CLIENT_CONFIG_FILE="${CLOUDS_FILE}"

echo "== Cloud-admin config bundle generator =="
echo "Using clouds file: ${CLOUDS_FILE}"
if [ "${#SCRUBBED_OS_VARS[@]}" -gt 0 ]; then
  echo "Cleared pre-existing OS_* environment overrides:"
  for v in "${SCRUBBED_OS_VARS[@]}"; do
    echo "  - ${v}"
  done
fi
echo

DEFAULT_CLOUD="${OS_CLOUD:-openstack}"
CLOUD_NAME="$(prompt_default "OpenStack cloud name from clouds.yaml" "${DEFAULT_CLOUD}")"

echo "Validating OpenStack access for cloud '${CLOUD_NAME}'..."
openstack --os-cloud "${CLOUD_NAME}" token issue -f value -c id >/dev/null
echo "OpenStack authentication succeeded."

TOKEN_JSON="$(openstack --os-cloud "${CLOUD_NAME}" token issue -f json)"
ADMIN_TOKEN="$(jq -r '.id // empty' <<<"${TOKEN_JSON}")"
if [ -z "${ADMIN_TOKEN}" ]; then
  ADMIN_TOKEN="$(openstack --os-cloud "${CLOUD_NAME}" token issue -f value -c id)"
fi

TOKEN_PROJECT_ID="$(jq -r '.project_id // empty' <<<"${TOKEN_JSON}")"
TOKEN_PROJECT_NAME="$(jq -r '.project_name // empty' <<<"${TOKEN_JSON}")"
TOKEN_SYSTEM_SCOPE="$(jq -r '.system // .system_scope // ."system_scope" // empty' <<<"${TOKEN_JSON}")"

if [ -n "${TOKEN_PROJECT_ID}" ]; then
  echo "Token scope: project-scoped"
  echo "  project_id: ${TOKEN_PROJECT_ID}"
  if [ -n "${TOKEN_PROJECT_NAME}" ]; then
    echo "  project_name: ${TOKEN_PROJECT_NAME}"
  fi
elif [ "${TOKEN_SYSTEM_SCOPE}" = "all" ]; then
  echo "Token scope: system-scoped (all)"
else
  echo "Token scope: unknown (could not detect project_id or system=all in token output)"
  echo "Raw token keys:"
  echo "${TOKEN_JSON}" | jq -r 'keys[]' | sed 's/^/  - /'
fi

CONFIG_JSON="$(openstack --os-cloud "${CLOUD_NAME}" configuration show -f json)"
OS_AUTH_URL="$(jq -r '."auth.auth_url" // .auth.auth_url // .auth_url // empty' <<<"${CONFIG_JSON}")"
OS_REGION_NAME="$(jq -r '.region_name // .region // "RegionOne"' <<<"${CONFIG_JSON}")"
OS_INTERFACE="$(jq -r '.interface // "public"' <<<"${CONFIG_JSON}")"
OS_IDENTITY_API_VERSION="$(jq -r '.identity_api_version // ."identity-api-version" // "3"' <<<"${CONFIG_JSON}")"
OS_AUTH_TYPE="v3applicationcredential"

if [ -z "${OS_AUTH_URL}" ]; then
  echo "ERROR: Could not determine auth URL from cloud config."
  exit 1
fi
IDENTITY_V3_URL="$(normalize_identity_v3_url "${OS_AUTH_URL}")"

echo
echo "== Customer target =="
CUSTOMER_PROJECT_ID="$(prompt_required "Customer project_id")"
CUSTOMER_USER_ID="$(prompt_required "Customer user_id")"

echo "Checking project/user visibility..."
openstack --os-cloud "${CLOUD_NAME}" project show "${CUSTOMER_PROJECT_ID}" -f value -c id >/dev/null
openstack --os-cloud "${CLOUD_NAME}" user show "${CUSTOMER_USER_ID}" -f value -c id >/dev/null

echo "Preflight: checking permission to create app credentials for this user/project..."
PREFLIGHT_CRED_NAME="preflight-k8s-demo-$(date +%Y%m%d%H%M%S)"
PREFLIGHT_CRED_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
PREFLIGHT_RESPONSE="$(create_app_credential \
  "${IDENTITY_V3_URL}" \
  "${ADMIN_TOKEN}" \
  "${CUSTOMER_USER_ID}" \
  "${CUSTOMER_PROJECT_ID}" \
  "${PREFLIGHT_CRED_NAME}" \
  "${PREFLIGHT_CRED_SECRET}")"

CAN_CREATE_APP_CRED=true
if ! jq -e '.application_credential.id' >/dev/null 2>&1 <<<"${PREFLIGHT_RESPONSE}"; then
  CAN_CREATE_APP_CRED=false
  echo "WARNING: cannot create application credential for this target."
  echo "Response from Keystone:"
  echo "${PREFLIGHT_RESPONSE}" | jq .
  echo
  echo "Hint: unrestricted app credentials are not full admin privileges."
  echo "Your token still needs Keystone policy permission for identity:create_application_credential on user ${CUSTOMER_USER_ID}."
  echo
  echo "Falling back to manual input."
  OS_APPLICATION_CREDENTIAL_ID="$(prompt_required "OS_APPLICATION_CREDENTIAL_ID (provided by customer/user)")"
  OS_APPLICATION_CREDENTIAL_SECRET="$(prompt_required_secret "OS_APPLICATION_CREDENTIAL_SECRET (provided by customer/user)")"
else
  PREFLIGHT_CRED_ID="$(jq -r '.application_credential.id' <<<"${PREFLIGHT_RESPONSE}")"
  DELETE_STATUS="$(delete_app_credential "${IDENTITY_V3_URL}" "${ADMIN_TOKEN}" "${CUSTOMER_USER_ID}" "${PREFLIGHT_CRED_ID}")"
  if [ "${DELETE_STATUS}" != "204" ]; then
    echo "WARNING: preflight app credential created but delete returned HTTP ${DELETE_STATUS}."
    echo "WARNING: credential id ${PREFLIGHT_CRED_ID} may need manual cleanup."
  fi
  echo "Preflight permission check passed."
fi

echo
echo "== Demo inputs =="
LETSENCRYPT_EMAIL="$(prompt_required "LETSENCRYPT_EMAIL")"
DEMO_DOMAIN_BASE="$(prompt_required "DEMO_DOMAIN_BASE (e.g. k8sdemo.example.com)")"
LETSENCRYPT_USE_STAGING="$(prompt_default "Use Let's Encrypt staging? (true/false)" "false")"
TRAEFIK_SERVICE_TYPE="$(prompt_default "TRAEFIK_SERVICE_TYPE" "LoadBalancer")"

echo
echo "== Kubernetes node inputs =="
K8S_IMAGE_NAME="$(prompt_required "K8S_IMAGE_NAME (OpenStack image name)")"
K8S_FLAVOR_NAME="$(prompt_required "K8S_FLAVOR_NAME (OpenStack flavor name)")"

TF_VAR_cluster_name="$(prompt_default "TF_VAR_cluster_name" "vpc-demo-cluster")"
TF_VAR_cluster_name="$(echo "${TF_VAR_cluster_name}" | tr '[:upper:]' '[:lower:]')"
echo "Using lowercase cluster name: ${TF_VAR_cluster_name}"
TF_VAR_k8s_worker_count="$(prompt_default "TF_VAR_k8s_worker_count" "2")"
TF_VAR_k8s_worker_max_count="$(prompt_default "TF_VAR_k8s_worker_max_count" "10")"
TF_VAR_k8s_repo_channel="$(prompt_default "TF_VAR_k8s_repo_channel" "v1.29")"
TF_VAR_k8s_pod_cidr="$(prompt_default "TF_VAR_k8s_pod_cidr" "10.244.0.0/16")"
TF_VAR_k8s_ssh_allowed_cidr="$(prompt_default "TF_VAR_k8s_ssh_allowed_cidr (single or comma-separated CIDRs)" "0.0.0.0/0")"
TF_VAR_k8s_api_allowed_cidr="$(prompt_default "TF_VAR_k8s_api_allowed_cidr (single or comma-separated CIDRs)" "0.0.0.0/0")"

echo
echo "== Terraform state backend inputs =="
TF_STATE_S3_BUCKET="$(prompt_required "TF_STATE_S3_BUCKET")"
TF_STATE_S3_KEY="$(prompt_default "TF_STATE_S3_KEY" "k8s-demo/terraform.tfstate")"
TF_STATE_S3_ENDPOINT="$(prompt_required "TF_STATE_S3_ENDPOINT")"
AWS_ACCESS_KEY_ID="$(prompt_required "AWS_ACCESS_KEY_ID")"
AWS_SECRET_ACCESS_KEY="$(prompt_required "AWS_SECRET_ACCESS_KEY")"

echo
echo "== Optional network override inputs =="
TF_VAR_attach_to_existing_router_id="$(prompt_optional "TF_VAR_attach_to_existing_router_id")"
TF_VAR_existing_network_id="$(prompt_optional "TF_VAR_existing_network_id")"
TF_VAR_network_name_suffix="$(prompt_optional "TF_VAR_network_name_suffix")"

CINDER_CSI_CHART_VERSION="$(prompt_optional "CINDER_CSI_CHART_VERSION")"
CINDER_CSI_STORAGECLASS_NAME="$(prompt_default "CINDER_CSI_STORAGECLASS_NAME" "cinder-csi")"
CINDER_CSI_SET_DEFAULT_SC="$(prompt_default "CINDER_CSI_SET_DEFAULT_SC (true/false)" "true")"
OPENSTACK_CCM_CHART_VERSION="$(prompt_optional "OPENSTACK_CCM_CHART_VERSION")"
OPENSTACK_CCM_USE_OCTAVIA="$(prompt_default "OPENSTACK_CCM_USE_OCTAVIA (true/false)" "true")"
CLUSTER_AUTOSCALER_IMAGE_REPOSITORY="$(prompt_default "CLUSTER_AUTOSCALER_IMAGE_REPOSITORY" "registry.k8s.io/autoscaling/cluster-autoscaler")"
CLUSTER_AUTOSCALER_IMAGE_TAG="$(prompt_optional "CLUSTER_AUTOSCALER_IMAGE_TAG (optional; default derived from k8s minor)")"
AUTOSCALER_MODE="$(prompt_default "AUTOSCALER_MODE (openstack/clusterapi)" "clusterapi")"

echo
echo "== Cluster API / CAPO inputs =="
CAPI_CLUSTERCTL_VERSION="$(prompt_default "CAPI_CLUSTERCTL_VERSION" "v1.8.5")"
CAPI_NAMESPACE="$(prompt_default "CAPI_NAMESPACE" "capo-system")"
CAPI_WORKLOAD_CLUSTER_NAME="$(prompt_default "CAPI_WORKLOAD_CLUSTER_NAME" "${TF_VAR_cluster_name}-workload")"
CAPI_WORKLOAD_CLUSTER_NAME="$(echo "${CAPI_WORKLOAD_CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"
echo "Using lowercase CAPI workload cluster name: ${CAPI_WORKLOAD_CLUSTER_NAME}"
CAPI_WORKLOAD_KUBERNETES_VERSION="$(prompt_default "CAPI_WORKLOAD_KUBERNETES_VERSION" "${TF_VAR_k8s_repo_channel}.4")"
CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT="$(prompt_default "CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT" "1")"
CAPI_WORKLOAD_WORKER_MACHINE_COUNT="$(prompt_default "CAPI_WORKLOAD_WORKER_MACHINE_COUNT" "${TF_VAR_k8s_worker_count}")"
CAPI_WORKLOAD_WORKER_MAX_MACHINE_COUNT="$(prompt_default "CAPI_WORKLOAD_WORKER_MAX_MACHINE_COUNT" "${TF_VAR_k8s_worker_max_count}")"
CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR="$(prompt_default "CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR" "${K8S_FLAVOR_NAME}")"
CAPI_WORKLOAD_WORKER_FLAVOR="$(prompt_default "CAPI_WORKLOAD_WORKER_FLAVOR" "${K8S_FLAVOR_NAME}")"
CAPI_WORKLOAD_IMAGE_NAME="$(prompt_default "CAPI_WORKLOAD_IMAGE_NAME" "${K8S_IMAGE_NAME}")"
CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME="$(prompt_default "CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME" "External")"
CAPI_WORKLOAD_EXTERNAL_NETWORK_ID="$(prompt_optional "CAPI_WORKLOAD_EXTERNAL_NETWORK_ID")"
CAPI_WORKLOAD_NETWORK_ID="$(prompt_optional "CAPI_WORKLOAD_NETWORK_ID")"
CAPI_WORKLOAD_SUBNET_ID="$(prompt_optional "CAPI_WORKLOAD_SUBNET_ID")"
CAPI_WORKLOAD_SSH_KEY_NAME="$(prompt_optional "CAPI_WORKLOAD_SSH_KEY_NAME")"
CAPI_WORKLOAD_SERVICE_CIDR="$(prompt_default "CAPI_WORKLOAD_SERVICE_CIDR" "10.96.0.0/12")"
CAPI_AUTOSCALER_NAMESPACE="$(prompt_default "CAPI_AUTOSCALER_NAMESPACE" "${CAPI_NAMESPACE}")"
CAPI_AUTOSCALER_CLUSTER_NAME="$(prompt_default "CAPI_AUTOSCALER_CLUSTER_NAME" "${CAPI_WORKLOAD_CLUSTER_NAME}")"

echo
if [ "${CAN_CREATE_APP_CRED}" = "true" ]; then
  echo "Creating application credential for user '${CUSTOMER_USER_ID}' in project '${CUSTOMER_PROJECT_ID}'..."
  APP_CRED_NAME="k8s-demo-${TF_VAR_cluster_name}-$(date +%Y%m%d%H%M%S)"
  APP_CRED_SECRET="$(openssl rand -base64 48 | tr -d '\n')"
  APP_CRED_RESPONSE="$(create_app_credential \
    "${IDENTITY_V3_URL}" \
    "${ADMIN_TOKEN}" \
    "${CUSTOMER_USER_ID}" \
    "${CUSTOMER_PROJECT_ID}" \
    "${APP_CRED_NAME}" \
    "${APP_CRED_SECRET}")"

  if ! jq -e '.application_credential.id' >/dev/null 2>&1 <<<"${APP_CRED_RESPONSE}"; then
    echo "ERROR: failed to create application credential via Keystone API."
    echo "Response:"
    echo "${APP_CRED_RESPONSE}" | jq .
    exit 1
  fi

  OS_APPLICATION_CREDENTIAL_ID="$(jq -r '.application_credential.id' <<<"${APP_CRED_RESPONSE}")"
  OS_APPLICATION_CREDENTIAL_SECRET="${APP_CRED_SECRET}"
  echo "Application credential created: ${APP_CRED_NAME}"
else
  echo "Using manually provided application credential values."
fi

KUBECONFIG_ARTIFACT_PASSPHRASE="$(openssl rand -base64 48 | tr -d '\n')"
DEMO_DB_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
DEMO_DB_ROOT_PASSWORD="$(openssl rand -base64 48 | tr -d '\n')"
TF_VAR_k8s_enabled="true"
TF_VAR_k8s_join_token="$(generate_join_token)"

OUTPUT_ENV="${REPO_ROOT}/cloud-admin-config.generated.env"
OUTPUT_B64="${REPO_ROOT}/cloud-admin-config.generated.b64"

cat >"${OUTPUT_ENV}" <<EOF
OS_AUTH_URL=${OS_AUTH_URL}
OS_REGION_NAME=${OS_REGION_NAME}
OS_INTERFACE=${OS_INTERFACE}
OS_IDENTITY_API_VERSION=${OS_IDENTITY_API_VERSION}
OS_AUTH_TYPE=${OS_AUTH_TYPE}
OS_APPLICATION_CREDENTIAL_ID=${OS_APPLICATION_CREDENTIAL_ID}
OS_APPLICATION_CREDENTIAL_SECRET=${OS_APPLICATION_CREDENTIAL_SECRET}

K8S_IMAGE_NAME=${K8S_IMAGE_NAME}
K8S_FLAVOR_NAME=${K8S_FLAVOR_NAME}
KUBECONFIG_ARTIFACT_PASSPHRASE=${KUBECONFIG_ARTIFACT_PASSPHRASE}
TF_VAR_cluster_name=${TF_VAR_cluster_name}
TF_VAR_k8s_enabled=${TF_VAR_k8s_enabled}
TF_VAR_k8s_worker_count=${TF_VAR_k8s_worker_count}
TF_VAR_k8s_worker_max_count=${TF_VAR_k8s_worker_max_count}
TF_VAR_k8s_repo_channel=${TF_VAR_k8s_repo_channel}
TF_VAR_k8s_join_token=${TF_VAR_k8s_join_token}
TF_VAR_k8s_pod_cidr=${TF_VAR_k8s_pod_cidr}
TF_VAR_k8s_ssh_allowed_cidr=${TF_VAR_k8s_ssh_allowed_cidr}
TF_VAR_k8s_api_allowed_cidr=${TF_VAR_k8s_api_allowed_cidr}

TF_VAR_attach_to_existing_router_id=${TF_VAR_attach_to_existing_router_id}
TF_VAR_existing_network_id=${TF_VAR_existing_network_id}
TF_VAR_network_name_suffix=${TF_VAR_network_name_suffix}

TF_STATE_S3_BUCKET=${TF_STATE_S3_BUCKET}
TF_STATE_S3_KEY=${TF_STATE_S3_KEY}
TF_STATE_S3_ENDPOINT=${TF_STATE_S3_ENDPOINT}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
LETSENCRYPT_USE_STAGING=${LETSENCRYPT_USE_STAGING}
TRAEFIK_SERVICE_TYPE=${TRAEFIK_SERVICE_TYPE}
DEMO_DOMAIN_BASE=${DEMO_DOMAIN_BASE}
DEMO_DB_PASSWORD=${DEMO_DB_PASSWORD}
DEMO_DB_ROOT_PASSWORD=${DEMO_DB_ROOT_PASSWORD}

METRICS_SERVER_CHART_VERSION=
CLUSTER_AUTOSCALER_CHART_VERSION=
CINDER_CSI_CHART_VERSION=${CINDER_CSI_CHART_VERSION}
CINDER_CSI_STORAGECLASS_NAME=${CINDER_CSI_STORAGECLASS_NAME}
CINDER_CSI_SET_DEFAULT_SC=${CINDER_CSI_SET_DEFAULT_SC}
OPENSTACK_CCM_CHART_VERSION=${OPENSTACK_CCM_CHART_VERSION}
OPENSTACK_CCM_USE_OCTAVIA=${OPENSTACK_CCM_USE_OCTAVIA}
CLUSTER_AUTOSCALER_IMAGE_REPOSITORY=${CLUSTER_AUTOSCALER_IMAGE_REPOSITORY}
CLUSTER_AUTOSCALER_IMAGE_TAG=${CLUSTER_AUTOSCALER_IMAGE_TAG}
AUTOSCALER_MODE=${AUTOSCALER_MODE}

CAPI_CLUSTERCTL_VERSION=${CAPI_CLUSTERCTL_VERSION}
CAPI_CORE_PROVIDER_VERSION=
CAPI_BOOTSTRAP_PROVIDER_VERSION=
CAPI_CONTROL_PLANE_PROVIDER_VERSION=
CAPI_IPAM_PROVIDER_VERSION=
CAPO_PROVIDER_VERSION=
CAPI_NAMESPACE=${CAPI_NAMESPACE}
CAPI_WORKLOAD_CLUSTER_NAME=${CAPI_WORKLOAD_CLUSTER_NAME}
CAPI_WORKLOAD_KUBERNETES_VERSION=${CAPI_WORKLOAD_KUBERNETES_VERSION}
CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT=${CAPI_WORKLOAD_CONTROL_PLANE_MACHINE_COUNT}
CAPI_WORKLOAD_WORKER_MACHINE_COUNT=${CAPI_WORKLOAD_WORKER_MACHINE_COUNT}
CAPI_WORKLOAD_WORKER_MAX_MACHINE_COUNT=${CAPI_WORKLOAD_WORKER_MAX_MACHINE_COUNT}
CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR=${CAPI_WORKLOAD_CONTROL_PLANE_FLAVOR}
CAPI_WORKLOAD_WORKER_FLAVOR=${CAPI_WORKLOAD_WORKER_FLAVOR}
CAPI_WORKLOAD_IMAGE_NAME=${CAPI_WORKLOAD_IMAGE_NAME}
CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME=${CAPI_WORKLOAD_EXTERNAL_NETWORK_NAME}
CAPI_WORKLOAD_EXTERNAL_NETWORK_ID=${CAPI_WORKLOAD_EXTERNAL_NETWORK_ID}
CAPI_WORKLOAD_NETWORK_ID=${CAPI_WORKLOAD_NETWORK_ID}
CAPI_WORKLOAD_SUBNET_ID=${CAPI_WORKLOAD_SUBNET_ID}
CAPI_WORKLOAD_SSH_KEY_NAME=${CAPI_WORKLOAD_SSH_KEY_NAME}
CAPI_WORKLOAD_SERVICE_CIDR=${CAPI_WORKLOAD_SERVICE_CIDR}
CAPI_AUTOSCALER_NAMESPACE=${CAPI_AUTOSCALER_NAMESPACE}
CAPI_AUTOSCALER_CLUSTER_NAME=${CAPI_AUTOSCALER_CLUSTER_NAME}
EOF

chmod 600 "${OUTPUT_ENV}"
base64 -w0 "${OUTPUT_ENV}" > "${OUTPUT_B64}"
chmod 600 "${OUTPUT_B64}"

echo
echo "Generated:"
echo "  ${OUTPUT_ENV}"
echo "  ${OUTPUT_B64}"
echo
echo "Set GitHub secret CLOUD_ADMIN_CONFIG_B64 to contents of:"
echo "  ${OUTPUT_B64}"
echo
echo "One-liner:"
echo "  gh secret set CLOUD_ADMIN_CONFIG_B64 --repo <owner>/<repo> < \"${OUTPUT_B64}\""
