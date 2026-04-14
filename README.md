# OpenStack Kubernetes demo (no Magnum)

This branch is a **Magnum-free** OpenStack PoC for Kubernetes autoscaling.

The repository demonstrates:

- OpenStack tenant networking and Kubernetes VM provisioning with Terraform (cloud-init + kubeadm)
- Kubernetes access + cloud config via one bundled secret (`CLOUD_ADMIN_CONFIG_B64`)
- OpenStack Cinder CSI install for dynamic persistent volume provisioning
- App deployment with Helm (WordPress/Drupal)
- Kubernetes-native autoscaling path: HPA + metrics-server + cluster-autoscaler (installed during provisioning)

## Quick start

1. Fork this repository and enable GitHub Actions.
2. Prepare an OpenStack project with required quotas and API access.
3. Add one GitHub secret: `CLOUD_ADMIN_CONFIG_B64`.
4. Run `01 - Validate configuration`.
5. Run `02 - Provision Cluster` (Terraform network + VM cluster build + Traefik install).
6. Point DNS to Traefik and run `03 - Deploy Single Site` (workflows auto-download and decrypt kubeconfig artifact at runtime).

## Single secret setup

All workflows load environment values from one secret:

| Name | Type | Purpose |
|------|------|---------|
| `CLOUD_ADMIN_CONFIG_B64` | Secret | Base64-encoded `KEY=VALUE` bundle with OpenStack auth, state backend, DB, DNS, and autoscaling values |

Use [`cloud-admin-config.env.example`](cloud-admin-config.env.example) as template.

```bash
cp cloud-admin-config.env.example cloud-admin-config.env
# edit values in cloud-admin-config.env
base64 -w0 cloud-admin-config.env
```

Paste that output into GitHub secret `CLOUD_ADMIN_CONFIG_B64`.

Cloud admins can also generate this bundle interactively (from `clouds.yaml` in repo root):

```bash
bash scripts/generate-cloud-admin-config.sh
```

The provision workflow also requires cluster build keys in the bundle:

- `K8S_IMAGE_NAME`, `K8S_FLAVOR_NAME`
- `KUBECONFIG_ARTIFACT_PASSPHRASE` (encrypt kubeconfig artifact)
- `TF_VAR_k8s_worker_count`, `TF_VAR_k8s_worker_max_count` (autoscaler min/max defaults; names are auto-derived from `TF_VAR_cluster_name`)
- Optional Cinder CSI tuning: `CINDER_CSI_CHART_VERSION`, `CINDER_CSI_STORAGECLASS_NAME`, `CINDER_CSI_SET_DEFAULT_SC`

## Workflows

| Workflow | Purpose |
|----------|---------|
| `01 - Validate configuration` | Validate required values by scenario |
| `02 - Provision Cluster` | Terraform apply (networking + kubeadm cluster), fetch/encrypt kubeconfig artifact, install Cinder CSI + autoscaling stack + Traefik |
| `03 - Deploy Single Site` | Deploy WordPress or Drupal site |
| `04 - Destroy Single Site` | Delete one site namespace |
| `05 - Tune cluster autoscaler` | Patch scale-down timers in `kube-system` |
| `06 - Scale up Cluster` | Burst Drupal deployments and collect scale-up KPIs |
| `07 - Scale down Cluster` | Delete burst namespaces and collect scale-down KPIs |
| `08 - Toggle Traefik Dashboard` | Enable/disable Traefik dashboard route |
| `09 - Dashboards - Deploy Headlamp` | Deploy Headlamp UI |
| `10 - Destroy All Sites` | Delete all customer site namespaces |
| `11 - Destroy Full Cluster` | Terraform destroy of managed OpenStack resources |
| `12 - Repair Autoscaling Stack` | Re-install/repair autoscaling stack (same config as provision) |

## Kubeconfig artifact flow

`02 - Provision Cluster` now:

1. Creates control-plane and worker VMs with cloud-init + kubeadm.
2. Reads kubeconfig from control-plane cloud-init console output markers (no runner SSH required).
3. Encrypts kubeconfig with `KUBECONFIG_ARTIFACT_PASSPHRASE`.
4. Uploads artifact `kubeconfig-encrypted-<run_id>`.

Decrypt example (optional local troubleshooting):

```bash
gpg --output kubeconfig --decrypt kubeconfig.gpg
```

## Autoscaling model in this branch

- **Pod autoscaling:** Helm chart ships an HPA (`autoscaling/v2`) for app pods.
- **Metrics pipeline:** installed automatically in `02 - Provision Cluster`.
- **Node autoscaling:** cluster-autoscaler is installed automatically in `02 - Provision Cluster`.
- **Recovery path:** workflow `12` can re-install autoscaling components if needed.
- **Burst KPIs:** workflows `06` and `07` publish artifacts with timing, pending pods, and node churn metrics.

If tenant permissions do not allow compute/network create/delete operations, use fixed node pools and HPA-only scaling.

## DNS

After `02 - Provision Cluster`, point DNS at:

```bash
kubectl get svc -n traefik traefik
```

Recommended wildcard:

| Record | Type | Value |
|--------|------|--------|
| `*.your-demo-zone.example` | A/AAAA | Traefik external IP |

## Security

- Do not commit kubeconfig files, `.env`, or Terraform state.
- Rotate app credentials and S3 keys if exposed.
- Treat project-member credentials as sensitive CI secrets.
