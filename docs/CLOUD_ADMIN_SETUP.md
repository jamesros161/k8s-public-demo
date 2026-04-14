# Cloud setup and handoff (no Magnum)

This checklist prepares a tenant for the Magnum-free branch of this demo.

This branch now uses a **single handoff secret** in GitHub: `CLOUD_ADMIN_CONFIG_B64`.
Cloud admins prepare one env-style file, base64 encode it, and give that string to the user.

For a guided/automated handoff, run:

```bash
bash scripts/generate-cloud-admin-config.sh
```

The script reads `clouds.yaml` in the repository root, asks for customer/project-specific values, generates strong secrets, creates an application credential for the target user+project, and outputs:

- `cloud-admin-config.generated.env`
- `cloud-admin-config.generated.b64`

## 1) Tenant model and permissions

This branch assumes the user is a **project member** (not cloud admin). For full node autoscaling, the project must allow:

- create/delete compute instances
- create/delete/attach Neutron ports and security groups
- attach volumes (if node boot/storage needs it)
- enough quotas (instances, vCPU, RAM, ports, volumes, load balancers)

If those permissions are unavailable, run this demo in **fixed node pool** mode and rely on HPA only.

## 2) Kubernetes cluster provisioning inputs

This branch provisions the Kubernetes cluster during workflow `02 - Provision Cluster` (Terraform + cloud-init + kubeadm).

Provide these bundle keys:

- `K8S_IMAGE_NAME` (Ubuntu image recommended)
- `K8S_FLAVOR_NAME`
- `K8S_SSH_USER` (default `ubuntu`)
- Optional `K8S_KEYPAIR_NAME_PREFIX` (workflow generates and cleans up ephemeral keypair each run)
- `KUBECONFIG_ARTIFACT_PASSPHRASE`

## 3) OpenStack credentials for Terraform networking

`02 - Provision Cluster` and `11 - Destroy Full Cluster` still use Terraform for OpenStack networking resources.

Provide (in the bundle):

- `OS_AUTH_URL`, `OS_REGION_NAME`, `OS_INTERFACE`, `OS_IDENTITY_API_VERSION`, `OS_AUTH_TYPE`
- `OS_APPLICATION_CREDENTIAL_ID`, `OS_APPLICATION_CREDENTIAL_SECRET`

## 4) Terraform remote state

Provide S3-compatible state backend values (in the bundle):

- `TF_STATE_S3_BUCKET`
- `TF_STATE_S3_ENDPOINT`
- `TF_STATE_S3_KEY` (optional)
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## 5) Ingress, DNS, and ACME

- `LETSENCRYPT_EMAIL`
- `DEMO_DOMAIN_BASE`

Customer should point wildcard DNS (`*.DEMO_DOMAIN_BASE`) at Traefik service external IP.

## 6) App secrets

Required for site and burst workflows:

- `DEMO_DB_PASSWORD`
- `DEMO_DB_ROOT_PASSWORD`

## 7) Autoscaling stack handoff (required)

`02 - Provision Cluster` installs autoscaling stack by default, so provide:

- `TF_VAR_k8s_worker_count`, `TF_VAR_k8s_worker_max_count`
- Cluster/group names are derived automatically from `TF_VAR_cluster_name`
- Optional chart pinning: `METRICS_SERVER_CHART_VERSION`, `CLUSTER_AUTOSCALER_CHART_VERSION`
Workflow `12 - Repair Autoscaling Stack` is now mainly for repair/reinstall.

## 8) Optional Terraform networking overrides

- `EXISTING_ROUTER_ID` when no external gateway IPs remain
- `EXISTING_NETWORK_ID` to reuse pre-created tenant network
- `NETWORK_NAME_SUFFIX` to avoid name collisions

## 9) Final handoff checks

1. Populate [`cloud-admin-config.env.example`](../cloud-admin-config.env.example), then base64 encode it and provide that string.
2. Customer sets GitHub secret `CLOUD_ADMIN_CONFIG_B64`.
3. Customer runs `01 - Validate configuration` (scenario `provision`).
4. Customer runs `02 - Provision Cluster`.
5. Customer points DNS to Traefik and runs `03 - Deploy Single Site` (workflow auto-downloads/decrypts kubeconfig artifact).
6. For autoscaling PoC, customer can run `12 - Repair Autoscaling Stack` if autoscaling components need repair, then run `06` and `07` for KPI artifacts.
