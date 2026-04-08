# OpenStack Magnum + Kubernetes demo (GitHub Actions)

This repository shows how to use **GitHub Actions** with **OpenStack** to provision a tenant **VPC**, a **Magnum** Kubernetes cluster, **Traefik** with **Let’s Encrypt**, and optional **WordPress** or **Drupal** demo sites (Helm).

**Who this is for**

- **Customers / evaluators:** fork the repo, add the Variables and Secrets your cloud team gives you, run **Validate configuration**, then **Cluster - Provision** and **Site - Deploy**.
- **Cloud administrators:** use **[`docs/CLOUD_ADMIN_SETUP.md`](docs/CLOUD_ADMIN_SETUP.md)** to prepare the project and produce the exact values to hand off.

---

## Quick start

1. **Fork** this repository (or copy it into an organization repo) and enable **GitHub Actions**.
2. Ask your OpenStack administrator to complete **[`docs/CLOUD_ADMIN_SETUP.md`](docs/CLOUD_ADMIN_SETUP.md)** and send you the **Variables**, **Secrets**, and DNS instructions.
3. In GitHub: **Settings → Secrets and variables → Actions**, add everything from the tables below (your admin may use slightly different names; match the **exact** names Actions expect).
4. Run **Actions → Validate configuration**:
   - Scenario **provision** before **Cluster - Provision** or **Cluster - Destroy**.
   - Scenario **site-deploy** before **Site - Deploy** or **Scaling - Burst Up**.
   - Scenario **core** for other workflows (Headlamp, Traefik dashboard toggle, burst teardown, etc.).  
   Fix any reported errors, then re-run.
5. Run **Cluster - Provision** (long-running: cluster create, nodes ready, Traefik install). When it finishes, note the Traefik **EXTERNAL-IP** (or NodePorts if using NodePort).
6. Point DNS at Traefik as described in [DNS](#dns).
7. Run **Site - Deploy** with a `site_id` and `app_type` (`wordpress` or `drupal`).

If something fails after configuration looks correct (networking, Magnum, load balancers, certificates, etc.), work with your **cloud administrator**. Detailed operational runbooks are **not** part of this public repository; admins should use **your organization’s internal documentation**.

---

## Validate configuration

The **Validate configuration** workflow checks that required **Variables** and **Secrets** are present, flags common mistakes (for example whitespace in UUIDs), and optionally runs **`openstack token issue`** and **`openstack coe cluster template list`** against your cloud.

It runs **automatically as the first job** before the other workflows in this repo, so a missing secret fails fast with a clear message. You can also run it on demand from the **Actions** tab.

---

## Repository Variables and Secrets

### Required for OpenStack (almost all workflows)

| Name | Type | Purpose |
|------|------|---------|
| `OS_AUTH_URL` | Variable | Keystone auth URL |
| `OS_REGION_NAME` | Variable | Region name |
| `OS_INTERFACE` | Variable | Endpoint interface (often `public`) |
| `OS_IDENTITY_API_VERSION` | Variable | Usually `3` |
| `OS_AUTH_TYPE` | Variable | Often `v3applicationcredential` |
| `OS_APPLICATION_CREDENTIAL_ID` | Secret | Application credential ID |
| `OS_APPLICATION_CREDENTIAL_SECRET` | Secret | Application credential secret |

Do **not** set `OS_PROJECT_ID` in Actions when using `v3applicationcredential` unless your identity provider documents that as required—it often breaks scoped tokens.

### If Magnum / Keystone rejects application credentials for trusts

If **Cluster - Provision** fails with **`application_credential is not allowed for managing trusts`**, your administrator should supply password auth for Terraform only:

| Name | Type | Purpose |
|------|------|---------|
| `TERRAFORM_OPENSTACK_USERNAME` | Secret | Member user name |
| `TERRAFORM_OPENSTACK_PASSWORD` | Secret | Member user password |
| `TERRAFORM_OPENSTACK_PROJECT_ID` | Variable | Project UUID |
| `TERRAFORM_OPENSTACK_USER_DOMAIN_NAME` | Variable | Optional; default `Default` |
| `TERRAFORM_OPENSTACK_PROJECT_DOMAIN_ID` | Variable | Optional; default `default` |

See **`scripts/configure-gha-openstack-auth.sh`**. Magnum trust, Keystone policy, and **`magnum.conf`** are **not** documented here—operators should follow **internal documentation**.

### Required for Cluster - Provision / Cluster - Destroy (Terraform remote state)

Terraform state must live in a **remote S3-compatible** bucket so destroy runs in CI see the same state as provision.

| Name | Type | Purpose |
|------|------|---------|
| `LETSENCRYPT_EMAIL` | Variable | Email for ACME (Let’s Encrypt) |
| `TF_STATE_S3_BUCKET` | Variable | State “bucket” / container name |
| `TF_STATE_S3_ENDPOINT` | Variable | S3 API base URL |
| `TF_STATE_S3_ACCESS_KEY_ID` | Secret | S3 API access key |
| `TF_STATE_S3_SECRET_ACCESS_KEY` | Secret | S3 API secret key |
| `TF_STATE_S3_KEY` | Variable | Optional object key (default `k8s-demo/terraform.tfstate`) |

Copy **[`terraform/backend.swift-s3.hcl.example`](terraform/backend.swift-s3.hcl.example)** for local `terraform init` with the same backend.

### Required for Site - Deploy and Scaling - Burst Up

| Name | Type | Purpose |
|------|------|---------|
| `DEMO_DB_PASSWORD` | Secret | MariaDB application user password |
| `DEMO_DB_ROOT_PASSWORD` | Secret | MariaDB root password |

Do **not** leave these empty: blank secrets override chart defaults and break MariaDB.

### Common optional Variables

| Name | Default / notes |
|------|-----------------|
| `CLUSTER_NAME` | `vpc-demo-cluster` |
| `CLUSTER_TEMPLATE_NAME` | `kubernetes-v1.26.8-rancher1` (must exist in your cloud; image visible in Glance) |
| `CLUSTER_AUTOSCALING_ENABLED` | `true` |
| `DEMO_DOMAIN_BASE` | `k8sdemo.example.com` in chart defaults; set to **your** DNS apex |
| `TRAEFIK_SERVICE_TYPE` | `LoadBalancer`; use `NodePort` only if VIP never provisions |
| `LETSENCRYPT_USE_STAGING` | Set `true` to use staging CA (untrusted certs) while debugging |
| `EXISTING_ROUTER_ID` | Reuse router when external gateway IPs are exhausted |
| `EXISTING_NETWORK_ID` | Use existing Neutron network instead of creating `vpc-demo-net` |
| `NETWORK_NAME_SUFFIX` | Suffix for created network name |
| `SKIP_FLANNEL_QUAY_PATCH` | `true` if not using Flannel from Quay (e.g. Calico template) |

---

## Workflows

| Workflow | Purpose |
|----------|---------|
| **Validate configuration** | Check Variables/Secrets and OpenStack connectivity (also runs first in other workflows). |
| **Cluster - Provision** | Terraform apply, wait for Magnum, kubeconfig, Traefik + ACME. |
| **Cluster - Destroy** | Confirm with `destroy-infra-confirm`; tears down Terraform-managed resources. |
| **Site - Deploy** | Deploy WordPress or Drupal into `{site_id}-{app_type}`. |
| **Site - Destroy** | Remove one site namespace. |
| **Site - Destroy All** | Remove all `*-wordpress` / `*-drupal` namespaces from normal deploys. |
| **Scaling - Burst Up / Down** | Many Drupal installs for autoscaler demos. |
| **Scaling - Tune cluster autoscaler** | Patch scale-down timers in `kube-system`. |
| **Dashboards - Toggle Traefik** | Enable/disable Traefik dashboard (demo only; unauthenticated when on). |
| **Dashboards - Deploy Headlamp** | Headlamp UI at `headlamp.<DEMO_DOMAIN_BASE>`. |

For **Cluster - Destroy**, leave the confirmation input on **cancel** to abort without changes, or choose **destroy-infra-confirm** to delete infrastructure.

---

## DNS

After provision, point DNS at the Traefik Service address from:

`kubectl get svc -n traefik traefik`

Hostnames are **`{site_id}.{app_type}.{DEMO_DOMAIN_BASE}`** (example: `wp1.wordpress.k8sdemo.example.com`). You need wildcard coverage for **both** `*.wordpress.<apex>` and `*.drupal.<apex>` (or equivalent), not only `*.<apex>`.

---

## kubectl from your laptop

`kubectl` talks to the Kubernetes API over HTTPS with a **kubeconfig** file; you do **not** need SSH to nodes for normal use.

1. Install **`kubectl`** and the **OpenStack CLI** (with Magnum).
2. Authenticate the same way you use for OpenStack (e.g. `openrc` or application credential environment variables).
3. Fetch config (replace with your **`CLUSTER_NAME`** if different):

```bash
mkdir -p ~/.kube
openstack coe cluster config vpc-demo-cluster --dir ~/.kube
export KUBECONFIG="$HOME/.kube/config"
```

If the API URL is unreachable from the public internet, run the same commands from a bastion or VPN inside the cloud.

**Application admin passwords** (random each deploy) are stored in the cluster only:

```bash
# WordPress — namespace {site_id}-wordpress
NS=wp1-wordpress
kubectl get secret wordpress-admin -n "$NS" -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret wordpress-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret wordpress-admin -n "$NS" -o jsonpath='{.data.site-url}' | base64 -d; echo
```

```bash
# Drupal — namespace {site_id}-drupal
NS=site1-drupal
kubectl get secret drupal-admin -n "$NS" -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret drupal-admin -n "$NS" -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret drupal-admin -n "$NS" -o jsonpath='{.data.site-url}' | base64 -d; echo
```

---

## Local quick checks

```bash
cd terraform && terraform init && terraform plan
helm template test ./helm/site-template --set siteId=demo --set appType=wordpress | head
```

---

## Security

- Do not commit **`openrc`**, **`.env`**, **`terraform.tfstate`**, or kubeconfig dumps. This repo’s **`.gitignore`** lists common credential filenames.
- Rotate credentials if they appear in logs or artifacts.
- Treat **`TERRAFORM_OPENSTACK_PASSWORD`** like any CI secret (least-privilege user, rotate on schedule).

---

## License and support

This is a **demonstration** configuration. Adapt quotas, images, templates, and security controls to your organization’s policies. Magnum and OpenStack behavior varies by distribution. The public **[`docs/CLOUD_ADMIN_SETUP.md`](docs/CLOUD_ADMIN_SETUP.md)** covers only the **handoff** checklist; deeper troubleshooting and control-plane procedures belong in **internal documentation**.
