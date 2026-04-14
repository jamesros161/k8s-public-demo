data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

locals {
  existing_network_id_trim          = trimspace(var.existing_network_id)
  attach_to_existing_router_id_trim = trimspace(var.attach_to_existing_router_id)
  cluster_name_norm                 = lower(trimspace(var.cluster_name))
  tenant_network_name               = trimspace(var.network_name_suffix) != "" ? "${var.demo_network_name}-${trimspace(var.network_name_suffix)}" : var.demo_network_name
  # When existing_network_id is set, demo_net is not created; try() avoids indexing [0] when count is 0.
  tenant_network_id        = try(openstack_networking_network_v2.demo_net[0].id, local.existing_network_id_trim)
  control_plane_private_ip = cidrhost(var.demo_subnet_cidr, 10)
  k8s_keypair_name_trim    = trimspace(var.k8s_keypair_name)
  k8s_ssh_allowed_cidrs    = distinct([for cidr in split(",", var.k8s_ssh_allowed_cidr) : trimspace(cidr) if trimspace(cidr) != ""])
  k8s_api_allowed_cidrs    = distinct([for cidr in split(",", var.k8s_api_allowed_cidr) : trimspace(cidr) if trimspace(cidr) != ""])
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

resource "openstack_networking_secgroup_v2" "k8s_nodes" {
  count = var.k8s_enabled ? 1 : 0
  name  = "${local.cluster_name_norm}-k8s-nodes"
}

resource "openstack_networking_secgroup_rule_v2" "k8s_ssh_ingress" {
  for_each          = var.k8s_enabled ? { for cidr in local.k8s_ssh_allowed_cidrs : cidr => cidr } : {}
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.k8s_nodes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "k8s_api_ingress" {
  for_each          = var.k8s_enabled ? { for cidr in local.k8s_api_allowed_cidrs : cidr => cidr } : {}
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.k8s_nodes[0].id
}

resource "openstack_networking_secgroup_rule_v2" "k8s_node_internal_ingress" {
  count             = var.k8s_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.k8s_nodes[0].id
  security_group_id = openstack_networking_secgroup_v2.k8s_nodes[0].id
}

resource "openstack_networking_port_v2" "control_plane_port" {
  count              = var.k8s_enabled ? 1 : 0
  name               = "${local.cluster_name_norm}-cp-1-port"
  network_id         = local.tenant_network_id
  security_group_ids = [openstack_networking_secgroup_v2.k8s_nodes[0].id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.demo_subnet.id
    ip_address = local.control_plane_private_ip
  }
  depends_on = [
    openstack_networking_router_interface_v2.demo_router_interface_new,
    openstack_networking_router_interface_v2.demo_router_interface_existing,
  ]
}

resource "openstack_networking_port_v2" "worker_ports" {
  count              = var.k8s_enabled ? var.k8s_worker_count : 0
  name               = "${local.cluster_name_norm}-worker-${count.index + 1}-port"
  network_id         = local.tenant_network_id
  security_group_ids = [openstack_networking_secgroup_v2.k8s_nodes[0].id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.demo_subnet.id
    ip_address = cidrhost(var.demo_subnet_cidr, 20 + count.index)
  }
  depends_on = [
    openstack_networking_router_interface_v2.demo_router_interface_new,
    openstack_networking_router_interface_v2.demo_router_interface_existing,
  ]
}

resource "openstack_networking_floatingip_v2" "control_plane_fip" {
  count = var.k8s_enabled ? 1 : 0
  pool  = var.external_network_name
}

resource "openstack_compute_instance_v2" "control_plane" {
  count       = var.k8s_enabled ? 1 : 0
  name        = "${local.cluster_name_norm}-cp-1"
  image_name  = var.k8s_image_name
  flavor_name = var.k8s_flavor_name
  key_pair    = local.k8s_keypair_name_trim != "" ? local.k8s_keypair_name_trim : null
  user_data = templatefile("${path.module}/cloud-init/control-plane.yaml.tmpl", {
    k8s_repo_channel         = var.k8s_repo_channel
    k8s_join_token           = var.k8s_join_token
    control_plane_private_ip = local.control_plane_private_ip
    control_plane_public_ip  = openstack_networking_floatingip_v2.control_plane_fip[0].address
    k8s_pod_cidr             = var.k8s_pod_cidr
    node_hostname            = "${local.cluster_name_norm}-cp-1"
  })

  network {
    port = openstack_networking_port_v2.control_plane_port[0].id
  }
}

resource "openstack_compute_instance_v2" "workers" {
  count       = var.k8s_enabled ? var.k8s_worker_count : 0
  name        = "${local.cluster_name_norm}-worker-${count.index + 1}"
  image_name  = var.k8s_image_name
  flavor_name = var.k8s_flavor_name
  key_pair    = local.k8s_keypair_name_trim != "" ? local.k8s_keypair_name_trim : null
  user_data = templatefile("${path.module}/cloud-init/worker.yaml.tmpl", {
    k8s_repo_channel         = var.k8s_repo_channel
    k8s_join_token           = var.k8s_join_token
    control_plane_private_ip = local.control_plane_private_ip
    node_hostname            = "${local.cluster_name_norm}-worker-${count.index + 1}"
  })

  network {
    port = openstack_networking_port_v2.worker_ports[count.index].id
  }

  depends_on = [openstack_compute_instance_v2.control_plane]
}

resource "openstack_networking_floatingip_associate_v2" "control_plane_fip_assoc" {
  count       = var.k8s_enabled ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.control_plane_fip[0].address
  port_id     = openstack_networking_port_v2.control_plane_port[0].id
}
