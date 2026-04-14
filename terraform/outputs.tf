output "demo_network_id" {
  value       = local.tenant_network_id
  description = "Tenant VPC network ID (created or pre-existing)."
}

output "demo_subnet_id" {
  value = openstack_networking_subnet_v2.demo_subnet.id
}

output "new_router_id" {
  description = "ID of the created router when attach_to_existing_router_id is unset; null otherwise."
  value       = try(openstack_networking_router_v2.demo_router[0].id, null)
}

output "control_plane_floating_ip" {
  description = "Floating IP of Kubernetes control-plane node."
  value       = try(openstack_networking_floatingip_v2.control_plane_fip[0].address, null)
}

output "control_plane_private_ip" {
  description = "Private IP of Kubernetes control-plane node."
  value       = local.control_plane_private_ip
}

output "control_plane_server_id" {
  description = "OpenStack server UUID for Kubernetes control-plane node."
  value       = try(openstack_compute_instance_v2.control_plane[0].id, null)
}

output "autoscaler_cluster_name" {
  description = "Derived cluster-autoscaler cluster name."
  value       = local.cluster_name_norm
}

output "autoscaler_group_name" {
  description = "Derived cluster-autoscaler worker group name."
  value       = "${local.cluster_name_norm}-worker"
}

output "autoscaler_nodes_min_size" {
  description = "Derived cluster-autoscaler minimum node count."
  value       = var.k8s_worker_count
}

output "autoscaler_nodes_max_size" {
  description = "Derived cluster-autoscaler maximum node count."
  value       = var.k8s_worker_max_count
}
