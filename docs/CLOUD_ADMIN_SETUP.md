# Cloud administrator setup (handoff to the customer)

This checklist is for **OpenStack / Magnum operators** preparing a tenant so a customer can fork this repository, enter GitHub **Variables** and **Secrets**, and run the demo workflows without further platform changes.

Deliver to the customer: a short written handoff (or ticket) listing each **name** below and the **value** you assigned. They map one-to-one to repository configuration in GitHub.

**Internal documentation:** This file is the only operator-facing doc published with the repo. For Magnum trust failures, **`magnum.conf`** / Kolla changes, Neutron edge cases, Traefik or LB diagnostics, and similar details, use **your organization’s internal runbooks**—they are intentionally not shipped here.

---

## 1. Project and quotas

1. Create or designate an **OpenStack project** (tenant) for the demo.
2. Ensure the project has adequate **quotas** for:
   - **Networks / subnets / routers / floating IPs** (VPC + external access).
   - **Magnum** clusters (masters + workers; autoscaler may add nodes).
   - **Cinder** volumes (MariaDB PVCs per site).
   - **Octavia / load balancers** (Traefik `LoadBalancer`, optional cluster API LBs are created by Magnum).
3. Confirm the project can use **Neutron**, **Magnum**, **Glance**, **Cinder**, and **Octavia** (or your cloud’s equivalent load-balancer integration for Kubernetes Services).

---

## 2. External (provider) network

1. Note the **Neutron name** of the external or provider network used for router gateways (this repo’s Terraform default is **`External`**).
2. If your cloud uses a **different name**, tell the customer they must set Terraform variable **`external_network_name`** locally, or you can pre-create networks/routers and document **`EXISTING_ROUTER_ID`** / **`EXISTING_NETWORK_ID`** instead.

---

## 3. Identity: application credential (recommended for most workflows)

1. Create an **application credential** in the **demo project** (the same project where the VPC and cluster will live)—either in Horizon (**Identity → Application Credentials**) or on the CLI with that project active (e.g. `source` the project’s `openrc`).

   ```bash
   openstack application credential create k8s-demo-ci \
     --description "GitHub Actions — Magnum/K8s demo"
   ```

   Use any name you prefer instead of `k8s-demo-ci`. The command prints **`id`** and **`secret`**; copy the **secret** immediately—it is **shown only once**. For role restrictions or extra options, see `openstack application credential create --help` on your cloud (flags vary slightly by release).

2. Record (map CLI output: **`id`** → **`OS_APPLICATION_CREDENTIAL_ID`**, **`secret`** → **`OS_APPLICATION_CREDENTIAL_SECRET`**):
   - **`OS_APPLICATION_CREDENTIAL_ID`**
   - **`OS_APPLICATION_CREDENTIAL_SECRET`** (the **`secret`** field from the command output)  
   Store these as GitHub **Secrets**, not Variables.
3. Provide standard auth **Variables** (non-secret), matching what works with your Keystone deployment:
   - **`OS_AUTH_URL`**
   - **`OS_REGION_NAME`**
   - **`OS_INTERFACE`** (often `public`)
   - **`OS_IDENTITY_API_VERSION`** (often `3`)
   - **`OS_AUTH_TYPE`**: **`v3applicationcredential`**
4. **Important:** Do **not** tell the customer to set **`OS_PROJECT_ID`** in GitHub when using application credentials; it commonly breaks scoped tokens.

---

## 4. Magnum trust and Terraform (Provision / Destroy)

Many Keystone deployments **reject application credentials** for **trust** APIs. Magnum needs trusts for typical Kubernetes + Cinder / cloud-provider clusters.

1. **Reproduce or confirm:** if cluster create fails with **`application_credential is not allowed for managing trusts`**, the customer **must** use password auth for **Cluster - Provision** and **Cluster - Destroy** only.
2. Create a **member** user in the **same project** (least privilege; password rotated like any service account).
3. Hand off (Secrets / Variables):
   - **`TERRAFORM_OPENSTACK_USERNAME`** (Secret)
   - **`TERRAFORM_OPENSTACK_PASSWORD`** (Secret)
   - **`TERRAFORM_OPENSTACK_PROJECT_ID`** (Variable — project UUID)
   - Optional: **`TERRAFORM_OPENSTACK_USER_DOMAIN_NAME`** (default `Default`), **`TERRAFORM_OPENSTACK_PROJECT_DOMAIN_ID`** (default `default`)

If you need to adjust **`magnum.conf`**, Kolla, or Keystone trust policy on the control plane, follow **internal documentation** (not included in this repository).

---

## 5. Magnum cluster template and Glance image

1. List public templates: `openstack coe cluster template list`.
2. For the template you recommend, run `openstack coe cluster template show <name> -c image_id -c name`.
3. Confirm the **`image_id`** appears in the tenant’s **`openstack image list --status active`**. If not, **publish** the COE image to Glance (correct name/visibility) or provide a **custom template** that references an image the tenant can see.
4. Tell the customer the exact template **name** for **`CLUSTER_TEMPLATE_NAME`** (or confirm the repo default is valid on your cloud).

Optional helper (customer can run locally with their auth): **`scripts/list-magnum-template-images.sh`**.

---

## 6. Terraform remote state (S3-compatible API)

GitHub Actions **re-initializes** Terraform on every run; **remote state** is required for **Cluster - Destroy** to work from CI.

1. Create an **object-store container** (bucket) for Terraform state.
2. Provide the customer **S3-compatible API** endpoint URL (not necessarily the raw Swift URL).
3. Create or delegate **S3 API credentials** (often via `openstack ec2 credentials create` or your object-store process). These are **not** always the same as application credentials.
4. Hand off:
   - **`TF_STATE_S3_BUCKET`** (Variable)
   - **`TF_STATE_S3_ENDPOINT`** (Variable)
   - **`TF_STATE_S3_KEY`** (Variable, optional — default in scripts is `k8s-demo/terraform.tfstate` if unset)
   - **`TF_STATE_S3_ACCESS_KEY_ID`** (Secret)
   - **`TF_STATE_S3_SECRET_ACCESS_KEY`** (Secret)

Point them to **`terraform/backend.swift-s3.hcl.example`** for local testing.

---

## 7. DNS (customer-controlled)

1. Agree on a DNS **apex** for the demo, e.g. **`k8sdemo.customer.example`**. The customer sets **`DEMO_DOMAIN_BASE`** to that apex (no leading `*.`).
2. Explain that site hostnames are **`{site_id}.{app_type}.{DEMO_DOMAIN_BASE}`** (e.g. **`wp1.wordpress.k8sdemo.customer.example`**). A single wildcard **`*.{apex}`** is **not** enough; they need at least:
   - **`*.{wordpress,drupal}.{apex}`** (or separate records per site).

After **Cluster - Provision**, the Traefik Service **EXTERNAL-IP** (or NodePort, if they use **`TRAEFIK_SERVICE_TYPE=NodePort`**) must match what DNS points to.

---

## 8. Let’s Encrypt

1. The customer must set **`LETSENCRYPT_EMAIL`** (repository **Variable**) for ACME registration and notices.
2. Ports **80** and **443** must reach Traefik from the internet (or from Let’s Encrypt’s perspective), unless they use DNS-01 outside this repo.

---

## 9. Site deploy database secrets

For **Site - Deploy** and **Scaling - Burst Up**, the customer must set (Secrets):

- **`DEMO_DB_PASSWORD`**
- **`DEMO_DB_ROOT_PASSWORD`**

These bootstrap MariaDB via Helm. They should be **strong, unique** values; rotation after first deploy requires aligning the database or recreating PVCs (see customer README).

---

## 10. Optional GitHub Variables (document if you set them)

| Variable | When to set |
|----------|-------------|
| **`CLUSTER_NAME`** | If Terraform cluster name is not the default `vpc-demo-cluster`. |
| **`EXISTING_ROUTER_ID`** | External network has no free gateway IPs; reuse a router that already has a gateway. |
| **`EXISTING_NETWORK_ID`** | Skip creating `vpc-demo-net`; use an existing Neutron network UUID. |
| **`NETWORK_NAME_SUFFIX`** | Avoid Neutron name collisions. |
| **`TRAEFIK_SERVICE_TYPE`** | `NodePort` if LoadBalancer VIP never provisions (debugging only). |
| **`LETSENCRYPT_USE_STAGING`** | `true` while testing ACME (untrusted certs). |

---

## 11. Final handoff

1. Run through **[`../README.md`](../README.md)** “Validate configuration” with the customer (or ask them to run workflow **Validate configuration** in their fork).
2. Confirm they can run **`openstack token issue`** and **`openstack coe cluster template list`** with the credentials you provided.
3. Confirm **S3 state** variables and secrets allow `terraform init` with the generated `backend.auto.hcl` (they can validate via the **Validate configuration** workflow, scenario **provision**).

When this checklist is complete, the customer can run **Cluster - Provision**, wait for completion, fix DNS to the Traefik endpoint, then run **Site - Deploy**.
