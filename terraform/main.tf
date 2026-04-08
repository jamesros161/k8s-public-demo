data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

data "openstack_containerinfra_clustertemplate_v1" "k8s" {
  name = var.cluster_template_name
}

locals {
  existing_network_id_trim          = trimspace(var.existing_network_id)
  attach_to_existing_router_id_trim   = trimspace(var.attach_to_existing_router_id)
  tenant_network_name                 = trimspace(var.network_name_suffix) != "" ? "${var.demo_network_name}-${trimspace(var.network_name_suffix)}" : var.demo_network_name
  # When existing_network_id is set, demo_net is not created; try() avoids indexing [0] when count is 0.
  tenant_network_id = try(openstack_networking_network_v2.demo_net[0].id, local.existing_network_id_trim)
}

resource "openstack_networking_network_v2" "demo_net" {
  count = local.existing_network_id_trim == "" ? 1 : 0

  name           = local.tenant_network_name
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "demo_subnet" {
  name            = var.demo_subnet_name
  network_id      = local.tenant_network_id
  cidr            = var.demo_subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "demo_router" {
  count = local.attach_to_existing_router_id_trim == "" ? 1 : 0

  name                = var.demo_router_name
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external.id
}

# New router: one interface resource. Existing router: separate resource so Terraform never indexes demo_router[0] when count is 0.
resource "openstack_networking_router_interface_v2" "demo_router_interface_new" {
  count = local.attach_to_existing_router_id_trim == "" ? 1 : 0

  router_id = openstack_networking_router_v2.demo_router[0].id
  subnet_id = openstack_networking_subnet_v2.demo_subnet.id
}

resource "openstack_networking_router_interface_v2" "demo_router_interface_existing" {
  count = local.attach_to_existing_router_id_trim != "" ? 1 : 0

  router_id = local.attach_to_existing_router_id_trim
  subnet_id = openstack_networking_subnet_v2.demo_subnet.id
}

resource "openstack_containerinfra_cluster_v1" "cluster" {
  name                = var.cluster_name
  cluster_template_id = data.openstack_containerinfra_clustertemplate_v1.k8s.id
  master_count        = var.master_count
  node_count          = var.node_count
  fixed_network       = local.tenant_network_id
  fixed_subnet        = openstack_networking_subnet_v2.demo_subnet.id
  merge_labels        = true

  labels = var.cluster_autoscaling_enabled ? {
    auto_scaling_enabled = "true"
    min_node_count       = tostring(var.autoscaler_min_nodes)
    max_node_count       = tostring(var.autoscaler_max_nodes)
    } : {
    auto_scaling_enabled = "false"
    min_node_count       = tostring(var.node_count)
    max_node_count       = tostring(var.node_count)
  }

  depends_on = [
    openstack_networking_router_interface_v2.demo_router_interface_new,
    openstack_networking_router_interface_v2.demo_router_interface_existing,
  ]
}
